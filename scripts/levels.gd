extends Node

## The list of levels, and which ones this player has unlocked.
##
## Winning a level unlocks the next one. Progress is saved on this computer.
## In co-op the host picks the level, so the host's progress decides what the
## team can play; everyone who wins also unlocks the next level for themselves.

const LIST: Array[Dictionary] = [
	{"name": "Forest Path", "path": "res://levels/level_01.tscn"},
	{"name": "City Crossing", "path": "res://levels/level_02.tscn"},
	{"name": "Dungeon Halls", "path": "res://levels/level_03.tscn"},
	{"name": "Rush Hour", "path": "res://levels/level_04.tscn"},
]
const SAVE_PATH := "user://progress.cfg"

## How many levels are open, counting from the first.
var unlocked := 1
## Automated tests turn this off so they don't change real progress.
var saving := true


func _ready() -> void:
	var file := ConfigFile.new()
	if file.load(SAVE_PATH) == OK:
		unlocked = clampi(file.get_value("progress", "unlocked", 1), 1, LIST.size())


func is_unlocked(index: int) -> bool:
	return index < unlocked


func index_of(path: String) -> int:
	for i in LIST.size():
		if LIST[i]["path"] == path:
			return i
	return -1


## The level after this one, or "" if this is the last.
func next_path(path: String) -> String:
	var index := index_of(path)
	if index == -1 or index + 1 >= LIST.size():
		return ""
	return LIST[index + 1]["path"]


## Unlocks the level after this one and saves.
func mark_won(path: String) -> void:
	var index := index_of(path)
	if index == -1 or index + 2 <= unlocked:
		return
	unlocked = mini(index + 2, LIST.size())
	if not saving:
		return
	var file := ConfigFile.new()
	file.set_value("progress", "unlocked", unlocked)
	file.save(SAVE_PATH)
