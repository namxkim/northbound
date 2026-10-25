extends Control

## The title screen: play solo, host a game, or join one. After hosting or
## joining it shows the lobby until the host starts the round.

@onready var _name_edit: LineEdit = %NameEdit
@onready var _address_edit: LineEdit = %AddressEdit
@onready var _choices: Control = %Choices
@onready var _lobby: Control = %Lobby
@onready var _player_list: Label = %PlayerList
@onready var _start_button: Button = %StartButton
@onready var _status: Label = %Status


func _ready() -> void:
	%SoloButton.pressed.connect(_on_solo_pressed)
	%HostButton.pressed.connect(_on_host_pressed)
	%JoinButton.pressed.connect(_on_join_pressed)
	%StartButton.pressed.connect(_on_start_pressed)
	%LeaveButton.pressed.connect(_on_leave_pressed)
	%QuitButton.pressed.connect(get_tree().quit)
	Network.players_changed.connect(_refresh_lobby)
	Network.connection_failed.connect(_on_connection_failed)

	_status.text = Network.last_message
	Network.last_message = ""
	_show_lobby(false)


func _on_solo_pressed() -> void:
	Network.start_solo(_name_edit.text)


func _on_host_pressed() -> void:
	var error := Network.host_game(_name_edit.text)
	if error != OK:
		_status.text = "Couldn't start hosting (error %d). Is another copy of the game already hosting?" % error
		return
	var addresses := _local_addresses()
	if addresses.is_empty():
		_status.text = "Hosting. Other copies of the game on this computer can join at 127.0.0.1."
	else:
		_status.text = "Hosting. Friends on your network can join at: %s" % ", ".join(addresses)


func _on_join_pressed() -> void:
	var address := _address_edit.text.strip_edges()
	var error := Network.join_game(address, _name_edit.text)
	if error != OK:
		_status.text = "Couldn't start connecting (error %d)." % error
		return
	_status.text = "Connecting to %s..." % (address if address else "127.0.0.1")
	_choices.visible = false


func _on_start_pressed() -> void:
	Network.start_game()


func _on_leave_pressed() -> void:
	Network.leave()


func _on_connection_failed(reason: String) -> void:
	_status.text = reason
	_show_lobby(false)


func _refresh_lobby() -> void:
	if not Network.online:
		return
	_show_lobby(true)
	var lines := PackedStringArray()
	var ids := Network.players.keys()
	ids.sort()
	for id in ids:
		var line: String = "• " + Network.players[id]["name"]
		if id == 1:
			line += "  (host)"
		if id == multiplayer.get_unique_id():
			line += "  (you)"
		lines.append(line)
	_player_list.text = "\n".join(lines)
	_start_button.visible = Network.is_host()
	if Network.is_host():
		_start_button.text = "Start Game (%d/%d players)" % [ids.size(), Network.MAX_PLAYERS]
	else:
		_status.text = "Waiting for the host to start..."


func _show_lobby(in_lobby: bool) -> void:
	_lobby.visible = in_lobby
	_choices.visible = not in_lobby
	_name_edit.editable = not in_lobby


## This computer's addresses on the local network, for friends to type in.
func _local_addresses() -> PackedStringArray:
	var found := PackedStringArray()
	for address in IP.get_local_addresses():
		if address.count(".") == 3 and not address.begins_with("127.") and not address.begins_with("169.254."):
			found.append(address)
	return found
