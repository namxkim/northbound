extends Camera3D

## The node to follow. The level sets this to the player.
var target: Node3D:
	set(value):
		target = value
		snap_to_target()

## Where the camera sits relative to the spot it looks at: above it and to the south.
@export var offset := Vector3(0, 10, 9)
## How many meters north of the target to aim, so players see more of what's ahead.
@export var look_ahead := 2.5
## Higher numbers follow more tightly.
@export var smoothing := 6.0


func _physics_process(delta: float) -> void:
	if target == null:
		return
	var goal := _focus() + offset
	global_position = global_position.lerp(goal, 1.0 - exp(-smoothing * delta))


func snap_to_target() -> void:
	if target == null or not is_inside_tree():
		return
	global_position = _focus() + offset
	look_at(_focus())
	reset_physics_interpolation()


func _focus() -> Vector3:
	return target.global_position + Vector3(0, 0, -look_ahead)
