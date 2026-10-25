extends Node3D

## Runs one round of a level, solo or online: placing players, checkpoints,
## death, the finish and restarting.
##
## Each computer decides when its own player is hit (enemies are in the same
## place for everyone thanks to the shared clock), then tells the others.
##
## For now every player respawns at the last checkpoint they reached, in solo
## and online. The co-op rules (watching teammates while dead, shared
## respawns, losing the round) come in step 3.

@export var player_scene: PackedScene = preload("res://scenes/player.tscn")
## Seconds between dying and coming back.
@export var respawn_delay := 1.0
## Meters between players standing at the start.
@export var spawn_spacing := 1.3

## The player controlled on this computer.
var player: CharacterBody3D

var _players := {}  # peer id -> player node
var _finished := {}  # peer ids that reached the finish
var _checkpoint: Vector3
var _message_id := 0

@onready var _start: Marker3D = $Start
@onready var _camera: Camera3D = $Camera
@onready var _status: Label = $UI/Status
@onready var _help: Label = $UI/Help


func _ready() -> void:
	GameClock.reset()
	GameClock.running = false
	if Network.players.is_empty():
		# The level was run straight from the editor: play solo.
		Network.players = {1: {"name": "Player", "character": 0}}

	_spawn_players()
	_camera.target = player

	for node in find_children("*", "Area3D"):
		if node is Zone:
			node.player_entered.connect(_on_zone_entered.bind(node))

	Network.round_begun.connect(_on_round_begun)
	Network.players_changed.connect(_on_players_changed)
	Network.player_state_received.connect(_on_player_state)
	Network.player_event_received.connect(_on_player_event)

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


func restart_round() -> void:
	Network.restart_round()


func _spawn_players() -> void:
	var ids: Array = Network.players.keys()
	ids.sort()
	for i in ids.size():
		var id: int = ids[i]
		var info: Dictionary = Network.players[id]
		var spot := _start.global_position + Vector3((i - (ids.size() - 1) / 2.0) * spawn_spacing, 0, 0)

		var new_player: CharacterBody3D = player_scene.instantiate()
		new_player.name = "Player%d" % id
		new_player.set_multiplayer_authority(id)
		new_player.character = load(Network.character_path(info["character"]))
		new_player.display_name = info["name"] if Network.online else ""
		new_player.frozen = true
		add_child(new_player)
		new_player.global_position = spot
		new_player.reset_physics_interpolation()
		_players[id] = new_player

		if id == multiplayer.get_unique_id():
			player = new_player
			player.died.connect(_on_player_died)
			_checkpoint = spot


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
			_finished.erase(id)
			gone.queue_free()
	_check_everyone_finished()


# --- This computer's player -----------------------------------------------


func _on_player_died() -> void:
	_show("Ouch! Back to the checkpoint...", respawn_delay)
	Network.send_player_event("died")
	get_tree().create_timer(respawn_delay).timeout.connect(_respawn_player)


func _respawn_player() -> void:
	player.respawn(_checkpoint)
	Network.send_player_event("respawned", _checkpoint)


func _on_zone_entered(body: Node3D, zone: Zone) -> void:
	if body != player or not player.alive or _finished.has(multiplayer.get_unique_id()):
		return

	match zone.kind:
		Zone.Kind.CHECKPOINT:
			if zone.global_position.is_equal_approx(_checkpoint):
				return
			_checkpoint = zone.global_position
			_show("Checkpoint!", 1.5)
		Zone.Kind.FINISH:
			_finished[multiplayer.get_unique_id()] = true
			player.frozen = true
			Network.send_player_event("finished")
			_show("You made it! Waiting for the others...")
			_check_everyone_finished()


# --- Other players --------------------------------------------------------


func _on_player_state(id: int, state: Array) -> void:
	if _players.has(id) and id != multiplayer.get_unique_id():
		_players[id].apply_remote_state(state)


func _on_player_event(id: int, kind: String, data: Variant) -> void:
	if not _players.has(id) or id == multiplayer.get_unique_id():
		return
	var other: CharacterBody3D = _players[id]
	match kind:
		"died":
			other.die()
			_show("%s was hit!" % other.display_name, 1.5)
		"respawned":
			if typeof(data) == TYPE_VECTOR3:
				other.respawn(data)
		"finished":
			_finished[id] = true
			_show("%s made it!" % other.display_name, 2.0)
			_check_everyone_finished()


func _check_everyone_finished() -> void:
	if _players.is_empty() or _finished.size() < _players.size():
		return
	GameClock.running = false
	if not Network.online:
		_show("You made it! Press Enter to play again.")
	elif Network.is_host():
		_show("Everyone made it! Press Enter to play again.")
	else:
		_show("Everyone made it! Waiting for the host to restart.")


## Shows a message at the top of the screen. With a duration, it clears itself.
func _show(text: String, duration := 0.0) -> void:
	_message_id += 1
	_status.text = text
	if duration > 0.0:
		get_tree().create_timer(duration).timeout.connect(_clear_message.bind(_message_id))


func _clear_message(id: int) -> void:
	if id == _message_id:
		_status.text = ""
