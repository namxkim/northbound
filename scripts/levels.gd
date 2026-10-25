extends Node

## The list of levels, and which ones this player has unlocked.
##
## The game has worlds of five levels each, named like "1-1" to "7-5". Levels
## unlock in order: winning a level unlocks the next one, and the last level
## of a world unlocks the first level of the next world. Progress is saved on
## this computer. In co-op the host picks the level, so the host's progress
## decides what the team can play; everyone who wins also unlocks the next
## level for themselves.

const WORLDS: Array[String] = ["Forest", "City", "Dungeon", "Graveyard", "Space Station", "Pirate Beach", "Snow"]
const LEVELS_PER_WORLD := 5
const SAVE_PATH := "user://progress.cfg"

## Every level in order: {"name": "1-1", "world": "Forest", "path": ...}.
var LIST: Array[Dictionary] = []
## How many levels are open, counting from the first.
var unlocked := 1
## Automated tests turn this off so they don't change real progress.
var saving := true


func _init() -> void:
	for w in WORLDS.size():
		for l in LEVELS_PER_WORLD:
			LIST.append({
				"name": "%d-%d" % [w + 1, l + 1],
				"world": WORLDS[w],
				"path": "res://levels/w%d_l%d.tscn" % [w + 1, l + 1],
			})


func _ready() -> void:
	var file := ConfigFile.new()
	if file.load(SAVE_PATH) == OK:
		unlocked = clampi(file.get_value("progress", "unlocked", 1), 1, LIST.size())


func is_unlocked(index: int) -> bool:
	return index < unlocked


## "1-1  Forest", for menus.
func label(index: int) -> String:
	return "%s  %s" % [LIST[index]["name"], LIST[index]["world"]]


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
