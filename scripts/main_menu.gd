extends Control

## The title screen: play solo, host a game, or join one. Play Solo opens the
## level list. After hosting or joining it shows the lobby, where the host
## picks the level and starts the round.

@onready var _name_edit: LineEdit = %NameEdit
@onready var _address_edit: LineEdit = %AddressEdit
@onready var _choices: Control = %Choices
@onready var _level_picker: Control = %LevelPicker
@onready var _level_buttons: Control = %LevelButtons
@onready var _lobby: Control = %Lobby
@onready var _player_list: Label = %PlayerList
@onready var _level_row: Control = %LevelRow
@onready var _lobby_level: OptionButton = %LobbyLevel
@onready var _start_button: Button = %StartButton
@onready var _status: Label = %Status


func _ready() -> void:
	%SoloButton.pressed.connect(_on_solo_pressed)
	%HostButton.pressed.connect(_on_host_pressed)
	%JoinButton.pressed.connect(_on_join_pressed)
	%StartButton.pressed.connect(_on_start_pressed)
	%LeaveButton.pressed.connect(_on_leave_pressed)
	%BackButton.pressed.connect(_on_back_pressed)
	%QuitButton.pressed.connect(get_tree().quit)
	Network.players_changed.connect(_refresh_lobby)
	Network.connection_failed.connect(_on_connection_failed)

	_status.text = Network.last_message
	Network.last_message = ""
	_show_screen(_choices)


func _on_solo_pressed() -> void:
	for child in _level_buttons.get_children():
		child.queue_free()
	# One row per world: its name, then a button for each of its levels.
	for w in Levels.WORLDS.size():
		var row := HBoxContainer.new()
		var world_label := Label.new()
		world_label.text = Levels.WORLDS[w]
		world_label.custom_minimum_size.x = 130
		row.add_child(world_label)
		for l in Levels.LEVELS_PER_WORLD:
			var i := w * Levels.LEVELS_PER_WORLD + l
			var button := Button.new()
			button.custom_minimum_size = Vector2(56, 36)
			button.text = Levels.LIST[i]["name"]
			if Levels.is_unlocked(i):
				button.pressed.connect(Network.start_solo.bind(_name_edit.text, Levels.LIST[i]["path"]))
			else:
				button.disabled = true
				button.tooltip_text = "Locked"
			row.add_child(button)
		_level_buttons.add_child(row)
	_status.text = "Win a level to unlock the next one. Greyed-out levels are locked."
	_show_screen(_level_picker)


func _on_back_pressed() -> void:
	_status.text = ""
	_show_screen(_choices)


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
	var index := _lobby_level.get_selected_id()
	Network.start_game(Levels.LIST[maxi(index, 0)]["path"])


func _on_leave_pressed() -> void:
	Network.leave()


func _on_connection_failed(reason: String) -> void:
	_status.text = reason
	_show_screen(_choices)


func _refresh_lobby() -> void:
	if not Network.online:
		return
	var first_time := not _lobby.visible
	_show_screen(_lobby)
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
	_level_row.visible = Network.is_host()
	if Network.is_host():
		_start_button.text = "Start Game (%d/%d players)" % [ids.size(), Network.MAX_PLAYERS]
		if first_time:
			_fill_level_choices()
	else:
		_status.text = "Waiting for the host to pick a level and start..."


## The host can pick any level they have unlocked. The newest is picked first.
func _fill_level_choices() -> void:
	_lobby_level.clear()
	for i in Levels.LIST.size():
		if Levels.is_unlocked(i):
			_lobby_level.add_item(Levels.label(i), i)
	_lobby_level.select(_lobby_level.item_count - 1)


func _show_screen(screen: Control) -> void:
	for each in [_choices, _level_picker, _lobby]:
		each.visible = each == screen
	_name_edit.editable = screen != _lobby


## This computer's addresses on the local network, for friends to type in.
func _local_addresses() -> PackedStringArray:
	var found := PackedStringArray()
	for address in IP.get_local_addresses():
		if address.count(".") == 3 and not address.begins_with("127.") and not address.begins_with("169.254."):
			found.append(address)
	return found
