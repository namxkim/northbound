extends Node3D

## Runs one round of a level: spawning, checkpoints, death, the finish and
## restarting.
##
## This is the solo version. In solo, dying sends you back to the last
## checkpoint you reached. Co-op rules come with the networking step.

@export var player_scene: PackedScene = preload("res://scenes/player.tscn")
## Seconds between dying and coming back.
@export var respawn_delay := 1.0

var player: CharacterBody3D

var _checkpoint: Vector3
var _finished := false
var _message_id := 0

@onready var _start: Marker3D = $Start
@onready var _camera: Camera3D = $Camera
@onready var _status: Label = $UI/Status


func _ready() -> void:
	GameClock.reset()
	_checkpoint = _start.global_position

	player = player_scene.instantiate()
	add_child(player)
	player.global_position = _checkpoint
	player.reset_physics_interpolation()
	player.died.connect(_on_player_died)
	_camera.target = player

	for node in find_children("*", "Area3D"):
		if node is Zone:
			node.player_entered.connect(_on_zone_entered.bind(node))

	_show("Head north!", 2.0)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("restart"):
		restart_round()


func restart_round() -> void:
	get_tree().reload_current_scene()


func _on_player_died() -> void:
	_show("Ouch! Back to the checkpoint...", respawn_delay)
	get_tree().create_timer(respawn_delay).timeout.connect(_respawn_player)


func _respawn_player() -> void:
	player.respawn(_checkpoint)


func _on_zone_entered(body: Node3D, zone: Zone) -> void:
	if body != player or not player.alive or _finished:
		return

	match zone.kind:
		Zone.Kind.CHECKPOINT:
			if zone.global_position.is_equal_approx(_checkpoint):
				return
			_checkpoint = zone.global_position
			_show("Checkpoint!", 1.5)
		Zone.Kind.FINISH:
			_finished = true
			player.frozen = true
			GameClock.running = false
			_show("You made it! Press Enter to play again.")


## Shows a message at the top of the screen. With a duration, it clears itself.
func _show(text: String, duration := 0.0) -> void:
	_message_id += 1
	_status.text = text
	if duration > 0.0:
		get_tree().create_timer(duration).timeout.connect(_clear_message.bind(_message_id))


func _clear_message(id: int) -> void:
	if id == _message_id:
		_status.text = ""
