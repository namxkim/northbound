extends Node

## Online play: hosting, joining, the player list, starting rounds and keeping
## every player's round clock in step with the host's.
##
## One player hosts and the others join them (peer-to-peer, no separate server).
## Every network message goes through this node, because it exists in every
## scene. That way a message never arrives for a level that isn't loaded yet.

## The player list changed (someone joined or left).
signal players_changed
## Joining didn't work. The reason is ready to show to the player.
signal connection_failed(reason: String)
## Everyone has loaded the level and the round clock has started.
signal round_begun
## Another player sent where they are. See Player.get_state().
signal player_state_received(peer_id: int, state: Array)
## Another player sent something that happened to them, like "died".
signal player_event_received(peer_id: int, kind: String, data: Variant)
## Host only: a player asks the host to decide something for the team,
## like "I reached this checkpoint".
signal team_request_received(peer_id: int, kind: String, data: Variant)
## The host decided something for the whole team, like "round lost".
signal team_event_received(kind: String, data: Variant)

const PORT := 24680
const MAX_PLAYERS := 8
const MAIN_MENU := "res://scenes/main_menu.tscn"
const FIRST_LEVEL := "res://levels/level_01.tscn"
## One look per player slot, so up to 8 players all look different.
const CHARACTERS := [
	"res://assets/characters/character-male-a.glb",
	"res://assets/characters/character-female-a.glb",
	"res://assets/characters/character-male-b.glb",
	"res://assets/characters/character-female-b.glb",
	"res://assets/characters/character-male-c.glb",
	"res://assets/characters/character-female-c.glb",
	"res://assets/characters/character-male-d.glb",
	"res://assets/characters/character-female-d.glb",
]

## Everyone in the game: peer id -> {"name": String, "character": int}.
## The host is always id 1. In solo play the only entry is 1.
var players := {}
## True while hosting or connected to a host.
var online := false
## True once everyone has loaded the level and the round has started.
var round_active := false
## A message for the main menu to show after leaving a game.
var last_message := ""

var _local_name := "Player"
var _level_path := FIRST_LEVEL
var _ready_peers := {}
var _clock_ping_timer := 0.0


func _ready() -> void:
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func is_host() -> bool:
	return online and multiplayer.is_server()


## True if this computer makes the team's decisions: the host, or anyone
## playing solo.
func decides_for_team() -> bool:
	return not online or multiplayer.is_server()


func character_path(index: int) -> String:
	return CHARACTERS[clampi(index, 0, CHARACTERS.size() - 1)]


# --- Starting and leaving -------------------------------------------------


func start_solo(player_name: String, level_path := FIRST_LEVEL) -> void:
	_go_offline()
	players = {1: {"name": _clean_name(player_name), "character": 0}}
	_level_path = level_path
	get_tree().change_scene_to_file(_level_path)


## Solo, or the host in an online game: moves everyone to another level.
func change_level(level_path: String) -> void:
	if not online:
		_level_path = level_path
		round_active = false
		get_tree().change_scene_to_file(level_path)
	elif is_host():
		_start_game.rpc(level_path)


## Starts hosting. bind_ip "*" accepts players from other computers;
## "127.0.0.1" only accepts copies of the game on this computer.
func host_game(player_name: String, bind_ip := "*") -> Error:
	_go_offline()
	var peer := ENetMultiplayerPeer.new()
	peer.set_bind_ip(bind_ip)
	var error := peer.create_server(PORT, MAX_PLAYERS - 1)
	if error != OK:
		return error
	multiplayer.multiplayer_peer = peer
	online = true
	_local_name = _clean_name(player_name)
	players = {1: {"name": _local_name, "character": 0}}
	players_changed.emit()
	return OK


## Connects to a host. The address can include a port, like "192.168.1.20:24680".
func join_game(address: String, player_name: String) -> Error:
	_go_offline()
	var host := address.strip_edges()
	var port := PORT
	if host.contains(":"):
		port = host.get_slice(":", 1).to_int()
		host = host.get_slice(":", 0)
	if host.is_empty():
		host = "127.0.0.1"
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_client(host, port)
	if error != OK:
		return error
	multiplayer.multiplayer_peer = peer
	online = true
	_local_name = _clean_name(player_name)
	return OK


## Host only: sends everyone into the level.
func start_game(level_path := FIRST_LEVEL) -> void:
	if not is_host():
		return
	# Nobody can join in the middle of a round.
	multiplayer.multiplayer_peer.refuse_new_connections = true
	_start_game.rpc(level_path)


## Solo, or the host in an online game: restarts the round for everyone.
func restart_round() -> void:
	if not online:
		round_active = false
		get_tree().reload_current_scene()
	elif is_host():
		_start_game.rpc(_level_path)


## Leaves the game (or stops hosting) and goes back to the main menu.
func leave(message := "") -> void:
	_go_offline()
	last_message = message
	get_tree().change_scene_to_file(MAIN_MENU)


## The level calls this once it has loaded and placed every player.
func level_loaded() -> void:
	if not online:
		_begin_round()
	elif is_host():
		_mark_ready(1)
	else:
		_peer_ready.rpc_id(1)


# --- Sending during a round -----------------------------------------------


## Sends this computer's player position to everyone else. Sent many times a
## second, so a lost message doesn't matter.
func send_player_state(state: Array) -> void:
	if online and round_active:
		_player_state.rpc(state)


## Tells everyone else about something that happened to this computer's player.
func send_player_event(kind: String, data: Variant = null) -> void:
	if online:
		_player_event.rpc(kind, data)


## Asks the host to decide something for the team. Only used when online and
## not hosting; the level handles its own requests otherwise.
func send_team_request(kind: String, data: Variant = null) -> void:
	if online and not multiplayer.is_server():
		_team_request.rpc_id(1, kind, data)


## Host only: tells everyone (including this computer) what was decided.
func send_team_event(kind: String, data: Variant = null) -> void:
	if is_host():
		_team_event.rpc(kind, data)


func _physics_process(delta: float) -> void:
	# Players who joined ask the host for its clock once a second.
	if online and round_active and not multiplayer.is_server():
		_clock_ping_timer -= delta
		if _clock_ping_timer <= 0.0:
			_clock_ping_timer = 1.0
			_clock_ping.rpc_id(1, Time.get_ticks_usec())


# --- Messages -------------------------------------------------------------
# Functions marked @rpc run on other computers when called with .rpc().


@rpc("any_peer", "reliable")
func _register(player_name: String) -> void:
	if not multiplayer.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	players[id] = {"name": _clean_name(player_name), "character": _free_character()}
	_set_players.rpc(players)


@rpc("authority", "call_local", "reliable")
func _set_players(new_players: Dictionary) -> void:
	players = new_players
	players_changed.emit()


@rpc("authority", "call_local", "reliable")
func _start_game(level_path: String) -> void:
	_level_path = level_path
	round_active = false
	_ready_peers.clear()
	get_tree().change_scene_to_file(level_path)


@rpc("any_peer", "reliable")
func _peer_ready() -> void:
	if multiplayer.is_server():
		_mark_ready(multiplayer.get_remote_sender_id())


@rpc("authority", "call_local", "reliable")
func _begin_round() -> void:
	GameClock.reset()
	round_active = true
	_clock_ping_timer = 0.0
	round_begun.emit()


@rpc("any_peer", "unreliable_ordered")
func _player_state(state: Array) -> void:
	player_state_received.emit(multiplayer.get_remote_sender_id(), state)


@rpc("any_peer", "reliable")
func _player_event(kind: String, data: Variant) -> void:
	player_event_received.emit(multiplayer.get_remote_sender_id(), kind, data)


@rpc("any_peer", "reliable")
func _team_request(kind: String, data: Variant) -> void:
	if multiplayer.is_server():
		team_request_received.emit(multiplayer.get_remote_sender_id(), kind, data)


@rpc("authority", "call_local", "reliable")
func _team_event(kind: String, data: Variant) -> void:
	team_event_received.emit(kind, data)


@rpc("any_peer", "unreliable")
func _clock_ping(sent_usec: int) -> void:
	if multiplayer.is_server():
		_clock_pong.rpc_id(multiplayer.get_remote_sender_id(), sent_usec, GameClock.time)


@rpc("authority", "unreliable")
func _clock_pong(sent_usec: int, host_time: float) -> void:
	# The host's reply took half the round trip to arrive, so its clock has
	# moved on by about that much.
	var round_trip := (Time.get_ticks_usec() - sent_usec) / 1_000_000.0
	var estimate := host_time + round_trip / 2.0
	var difference := estimate - GameClock.time
	if absf(difference) > 0.25:
		GameClock.time = estimate
	else:
		# Small differences are eased out so enemies don't visibly jump.
		GameClock.time += difference * 0.25


# --- Connection events ----------------------------------------------------


func _on_connected_to_server() -> void:
	_register.rpc_id(1, _local_name)


func _on_connection_failed() -> void:
	_go_offline.call_deferred()
	connection_failed.emit("Couldn't connect. Check the address and that the host is waiting in the lobby.")


func _on_server_disconnected() -> void:
	leave.call_deferred("The host left the game.")


func _on_peer_disconnected(id: int) -> void:
	if not multiplayer.is_server():
		return
	_ready_peers.erase(id)
	if players.erase(id):
		_set_players.rpc(players)
	_check_all_ready()


# --- Helpers --------------------------------------------------------------


func _mark_ready(id: int) -> void:
	_ready_peers[id] = true
	_check_all_ready()


func _check_all_ready() -> void:
	if not is_host() or round_active or _ready_peers.is_empty():
		return
	for id in players:
		if not _ready_peers.has(id):
			return
	_begin_round.rpc()


func _free_character() -> int:
	var used := {}
	for info in players.values():
		used[info["character"]] = true
	for index in CHARACTERS.size():
		if not used.has(index):
			return index
	return 0


func _clean_name(player_name: String) -> String:
	var cleaned := player_name.strip_edges().left(16)
	return cleaned if not cleaned.is_empty() else "Player"


func _go_offline() -> void:
	if multiplayer.multiplayer_peer and not multiplayer.multiplayer_peer is OfflineMultiplayerPeer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	online = false
	round_active = false
	players = {}
	_ready_peers.clear()
