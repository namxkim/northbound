extends Node3D

## Runs one round of a level, solo or co-op: placing players, checkpoints,
## death, watching teammates, winning, losing and restarting.
##
## Solo (one player in the round): dying sends you back to the last
## checkpoint you reached.
##
## Co-op (two or more players):
## - A player who is hit stays down and watches a teammate who's still alive.
## - When a living player reaches a checkpoint the team hasn't reached yet,
##   every dead player comes back there.
## - If everyone is down, the round is lost. The host can restart it.
## - The first player across the finish wins the round for the whole team.
##
## Each computer decides when its own player is hit (enemies are in the same
## place for everyone thanks to the shared clock). The host decides everything
## that affects the whole team (checkpoints, winning, losing) and tells
## everyone, so all the games agree even when two things happen at once.

@export var player_scene: PackedScene = preload("res://scenes/player.tscn")
## Seconds between dying and coming back, in solo.
@export var respawn_delay := 1.0
## Meters between players standing side by side at the start or a checkpoint.
@export var spawn_spacing := 1.3

## The player controlled on this computer.
var player: CharacterBody3D

var _players := {}  # peer id -> player node
var _checkpoint: Vector3  # where the team respawns
var _round_over := false
var _watched_id := -1  # teammate the camera follows while dead (co-op)
var _message_id := 0
# Only used by the computer that decides for the team (host or solo):
var _reached := {}  # checkpoint paths the team has reached
var _dead := {}  # peer ids that are down

@onready var _start: Marker3D = $Start
@onready var _camera: Camera3D = $Camera
@onready var _status: Label = $UI/Status
@onready var _help: Label = $UI/Help
var _watching_label: Label


func _ready() -> void:
	GameClock.reset()
	GameClock.running = false
	if Network.players.is_empty():
		# The level was run straight from the editor: play solo.
		Network.players = {1: {"name": "Player", "character": 0}}

	_spawn_players()
	_camera.target = player
	_camera.snap_to_target()
	_add_watching_label()

	for node in find_children("*", "Area3D"):
		if node is Zone:
			node.player_entered.connect(_on_zone_entered.bind(node))

	Network.round_begun.connect(_on_round_begun)
	Network.players_changed.connect(_on_players_changed)
	Network.player_state_received.connect(_on_player_state)
	Network.player_event_received.connect(_on_player_event)
	Network.team_request_received.connect(_handle_team_request)
	Network.team_event_received.connect(_on_team_event)

	if not Network.online:
		_help.text = "WASD / arrow keys: move     R: restart     Esc: menu"
	elif Network.is_host():
		_help.text = "WASD / arrow keys: move     R: restart round     Esc: leave"
	else:
		_help.text = "WASD / arrow keys: move     Esc: leave"

	if Network.online:
		_show("Waiting for everyone to load...")
	Network.level_loaded()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("restart"):
		if Network.online and not Network.is_host():
			_show("Only the host can restart the round.", 1.5)
		else:
			restart_round()
	elif event.is_action_pressed("ui_cancel"):
		Network.leave()
	elif _is_watching() and event.is_action_pressed("move_right"):
		_watch_next(1)
	elif _is_watching() and event.is_action_pressed("move_left"):
		_watch_next(-1)


func restart_round() -> void:
	Network.restart_round()


## Co-op rules apply when more than one player is in the round.
func is_coop() -> bool:
	return _players.size() > 1


func _my_id() -> int:
	return multiplayer.get_unique_id()


func _spawn_players() -> void:
	var ids: Array = Network.players.keys()
	ids.sort()
	_checkpoint = _start.global_position
	for i in ids.size():
		var id: int = ids[i]
		var info: Dictionary = Network.players[id]

		var new_player: CharacterBody3D = player_scene.instantiate()
		new_player.name = "Player%d" % id
		new_player.set_multiplayer_authority(id)
		new_player.character = load(Network.character_path(info["character"]))
		new_player.display_name = info["name"] if Network.online else ""
		new_player.frozen = true
		add_child(new_player)
		new_player.global_position = _spot(_checkpoint, i, ids.size())
		new_player.reset_physics_interpolation()
		_players[id] = new_player

		if id == _my_id():
			player = new_player
			player.died.connect(_on_player_died)


## Spot number `index` of `count` players standing side by side at `center`.
func _spot(center: Vector3, index: int, count: int) -> Vector3:
	return center + Vector3((index - (count - 1) / 2.0) * spawn_spacing, 0, 0)


func _on_round_begun() -> void:
	for each in _players.values():
		each.frozen = false
	_show("Head north!", 2.0)


func _on_players_changed() -> void:
	for id in _players.keys():
		if not Network.players.has(id):
			var gone: Node = _players[id]
			_show("%s left the game." % gone.display_name, 2.0)
			_players.erase(id)
			_dead.erase(id)
			gone.queue_free()
			if id == _watched_id:
				_watch_next(1)
	if not is_coop() and player and not player.alive and not _round_over:
		# Everyone else left while we were down: carry on solo.
		_respawn_alone()
	if Network.decides_for_team():
		_check_everyone_down()


# --- This computer's player -----------------------------------------------


func _on_player_died() -> void:
	Network.send_player_event("died")
	if is_coop():
		_show("You were hit! Hang on until a teammate reaches a new checkpoint.", 3.0)
		_watch_next(1)
	else:
		_show("Ouch! Back to the checkpoint...", respawn_delay)
		get_tree().create_timer(respawn_delay).timeout.connect(_respawn_alone)
	if Network.decides_for_team():
		_note_down(_my_id())


func _respawn_alone() -> void:
	if _round_over:
		return
	_respawn_local(_checkpoint)


func _respawn_local(at: Vector3) -> void:
	player.respawn(at)
	Network.send_player_event("respawned", at)
	_stop_watching()
	if Network.decides_for_team():
		_dead.erase(_my_id())


func _on_zone_entered(body: Node3D, zone: Zone) -> void:
	if body != player or not player.alive or _round_over:
		return
	match zone.kind:
		Zone.Kind.CHECKPOINT:
			_ask_team("checkpoint", str(get_path_to(zone)))
		Zone.Kind.FINISH:
			player.frozen = true
			_ask_team("finish")


# --- Team decisions (made by the host, or the only player in solo) ---------


## Asks whoever decides for the team. That's this computer when hosting or solo.
func _ask_team(kind: String, data: Variant = null) -> void:
	if Network.decides_for_team():
		_handle_team_request(_my_id(), kind, data)
	else:
		Network.send_team_request(kind, data)


func _handle_team_request(from: int, kind: String, data: Variant) -> void:
	if _round_over or not _players.has(from):
		return
	match kind:
		"checkpoint":
			if typeof(data) != TYPE_STRING or _reached.has(data):
				return  # Only checkpoints the team hasn't reached yet count.
			var zone := get_node_or_null(NodePath(data)) as Zone
			if zone == null or zone.kind != Zone.Kind.CHECKPOINT:
				return
			_reached[data] = true
			var revived: Array = _dead.keys()
			revived.sort()
			_dead.clear()
			_tell_team("checkpoint", {"zone": data, "by": from, "revived": revived})
		"finish":
			_tell_team("won", {"by": from})


func _note_down(id: int) -> void:
	if not is_coop() or _round_over:
		return
	_dead[id] = true
	_check_everyone_down()


func _check_everyone_down() -> void:
	if not is_coop() or _round_over or _players.is_empty():
		return
	for id in _players:
		if not _dead.has(id):
			return
	_tell_team("lost")


func _tell_team(kind: String, data: Variant = null) -> void:
	if Network.online:
		Network.send_team_event(kind, data)  # Comes back to us through _on_team_event.
	else:
		_on_team_event(kind, data)


## Everyone: the host decided something for the team.
func _on_team_event(kind: String, data: Variant) -> void:
	match kind:
		"checkpoint":
			_on_team_checkpoint(data)
		"won":
			var by: int = data["by"]
			_end_round()
			var who: String = _players[by].display_name if _players.has(by) else "Someone"
			if not Network.online:
				_show("You made it! Press Enter to play again.")
			elif Network.is_host():
				_show("%s made it across! The team wins! Press Enter to play again." % who)
			else:
				_show("%s made it across! The team wins! Waiting for the host to restart." % who)
		"lost":
			_end_round()
			if Network.is_host():
				_show("Everyone was hit. Round lost! Press Enter to try again.")
			else:
				_show("Everyone was hit. Round lost! Waiting for the host to restart.")


func _on_team_checkpoint(data: Dictionary) -> void:
	var zone := get_node_or_null(NodePath(data["zone"])) as Zone
	if zone == null:
		return
	_checkpoint = zone.global_position
	var by: int = data["by"]
	var revived: Array = data["revived"]
	var index := revived.find(_my_id())
	if index != -1:
		_respawn_local(_spot(_checkpoint, index, revived.size()))

	var who: String = _players[by].display_name if _players.has(by) else "Someone"
	if by == _my_id():
		_show("Checkpoint! Your team is back!" if not revived.is_empty() else "Checkpoint!", 2.0)
	elif index != -1:
		_show("%s reached a checkpoint. You're back!" % who, 2.0)
	else:
		_show("%s reached a new checkpoint!" % who, 2.0)


func _end_round() -> void:
	_round_over = true
	GameClock.running = false
	for each in _players.values():
		each.frozen = true


# --- Other players --------------------------------------------------------


func _on_player_state(id: int, state: Array) -> void:
	if _players.has(id) and id != _my_id():
		_players[id].apply_remote_state(state)


func _on_player_event(id: int, kind: String, data: Variant) -> void:
	if not _players.has(id) or id == _my_id():
		return
	var other: CharacterBody3D = _players[id]
	match kind:
		"died":
			other.die()
			_show("%s was hit!" % other.display_name, 1.5)
			if id == _watched_id:
				_watch_next(1)
			if Network.decides_for_team():
				_note_down(id)
		"respawned":
			if typeof(data) == TYPE_VECTOR3:
				other.respawn(data)
			if Network.decides_for_team():
				_dead.erase(id)


# --- Watching teammates while down (co-op) ---------------------------------


func _is_watching() -> bool:
	return is_coop() and player != null and not player.alive


## Points the camera at the next living teammate (step 1) or the previous one (-1).
func _watch_next(step: int) -> void:
	if not _is_watching():
		return
	var living: Array = []
	for id in _players:
		if id != _my_id() and _players[id].alive:
			living.append(id)
	if living.is_empty():
		_watching_label.visible = false
		return
	living.sort()
	var index := living.find(_watched_id)
	index = 0 if index == -1 else posmod(index + step, living.size())
	_watched_id = living[index]
	_camera.target = _players[_watched_id]
	_watching_label.text = "Watching %s     A / D: switch" % _players[_watched_id].display_name
	_watching_label.visible = true


func _stop_watching() -> void:
	_watched_id = -1
	_camera.target = player
	_watching_label.visible = false


func _add_watching_label() -> void:
	_watching_label = Label.new()
	_watching_label.name = "Watching"
	_watching_label.visible = false
	_watching_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_watching_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_watching_label.offset_top = -90
	_watching_label.offset_bottom = -54
	_watching_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_watching_label.add_theme_font_size_override("font_size", 26)
	_watching_label.add_theme_constant_override("outline_size", 8)
	_watching_label.add_theme_color_override("font_outline_color", Color.BLACK)
	$UI.add_child(_watching_label)


# --- Messages -------------------------------------------------------------


## Shows a message at the top of the screen. With a duration, it clears itself.
func _show(text: String, duration := 0.0) -> void:
	if _round_over and duration > 0.0:
		return  # Keep the end-of-round message on screen.
	_message_id += 1
	_status.text = text
	if duration > 0.0:
		get_tree().create_timer(duration).timeout.connect(_clear_message.bind(_message_id))


func _clear_message(id: int) -> void:
	if id == _message_id:
		_status.text = ""
