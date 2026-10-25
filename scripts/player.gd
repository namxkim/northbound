extends CharacterBody3D

## One player's character.
##
## The player on this computer (the "local" player) reads the keyboard, moves,
## checks for enemy hits and sends its position to everyone else. Other
## players' characters (the "remote" ones) just glide to the positions they
## receive.

## Sent when an enemy touches this player. Only the local player sends it.
signal died

## Which character model this player uses. The level sets one per player.
@export var character: PackedScene = preload("res://assets/characters/character-male-a.glb")
## The Kenney characters are small, so they're scaled up to fit the world.
@export var character_scale := 2.2

## Top speed, in meters per second.
@export var speed := 6.0
## How quickly the player speeds up and slows down.
@export var acceleration := 40.0
@export var deceleration := 50.0
## Seconds the player can't be hurt after respawning.
@export var respawn_protection := 1.0

## Name shown above the player's head. Empty hides it (solo play).
var display_name := ""
## True for the player controlled on this computer.
var is_local := true
var alive := true
## When true the player ignores input, for example before the round starts.
var frozen := false

const _ANIMATIONS: Array[String] = ["idle", "walk", "sprint", "die"]

var _protection_left := 0.0
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var _animations: AnimationPlayer
var _current_animation := ""
var _send_counter := 0
# Remote players: the latest position and facing received.
var _remote_target := Vector3.ZERO
var _remote_facing := 0.0
var _has_remote_target := false

@onready var _model: Node3D = $Model
@onready var _hurtbox: Area3D = $Hurtbox
@onready var _name_label: Label3D = $NameLabel


func _ready() -> void:
	is_local = is_multiplayer_authority()
	var look: Node3D = character.instantiate()
	look.scale = Vector3.ONE * character_scale
	# The models face +Z. Turning them around makes -Z (north) the player's forward.
	look.rotation.y = PI
	_model.add_child(look)
	_animations = ModelAnimations.setup(look, ["idle", "walk", "sprint"])
	_play("idle")

	_name_label.text = display_name
	_name_label.visible = not display_name.is_empty()
	if not is_local:
		# Each computer only checks hits for its own player.
		_hurtbox.monitoring = false


func _physics_process(delta: float) -> void:
	if not is_local:
		_follow_remote(delta)
		return
	if not alive:
		return

	if not is_on_floor():
		velocity.y -= _gravity * delta

	var input := Vector2.ZERO
	if not frozen:
		input = Input.get_vector("move_left", "move_right", "move_up", "move_down")

	# North is -Z, so "up" on the keyboard moves the player toward the finish.
	var target := input * speed
	var rate := acceleration if input != Vector2.ZERO else deceleration
	var flat := Vector2(velocity.x, velocity.z).move_toward(target, rate * delta)
	velocity.x = flat.x
	velocity.z = flat.y
	move_and_slide()

	if input.length() > 0.1:
		var facing := atan2(-input.x, -input.y)
		_model.rotation.y = lerp_angle(_model.rotation.y, facing, 15.0 * delta)

	var moving_speed := Vector2(velocity.x, velocity.z).length()
	if moving_speed > speed * 0.6:
		_play("sprint")
	elif moving_speed > 0.3:
		_play("walk")
	else:
		_play("idle")

	if _protection_left > 0.0:
		_protection_left -= delta
		# Blink while protected.
		_model.visible = _protection_left <= 0.0 or fmod(_protection_left, 0.2) > 0.1
	elif _hurtbox.has_overlapping_areas():
		die()

	# Every other physics step is about 30 times a second.
	_send_counter += 1
	if _send_counter % 2 == 0:
		Network.send_player_state(get_state())


func die() -> void:
	if not alive:
		return
	alive = false
	velocity = Vector3.ZERO
	_model.visible = true
	_play("die")
	if is_local:
		died.emit()


func respawn(at: Vector3) -> void:
	global_position = at
	velocity = Vector3.ZERO
	alive = true
	frozen = false
	_model.visible = true
	_protection_left = respawn_protection
	_remote_target = at
	_has_remote_target = true
	_play("idle")
	reset_physics_interpolation()


## What other players need to draw this player: position, facing, animation.
func get_state() -> Array:
	return [global_position, _model.rotation.y, _ANIMATIONS.find(_current_animation)]


## Remote players only: use a state sent by that player's computer.
func apply_remote_state(state: Array) -> void:
	# Messages come from other computers, so check they look right first.
	if state.size() != 3 or typeof(state[0]) != TYPE_VECTOR3 \
			or typeof(state[1]) != TYPE_FLOAT or typeof(state[2]) != TYPE_INT:
		return
	_remote_target = state[0]
	_remote_facing = state[1]
	if not _has_remote_target:
		_has_remote_target = true
		global_position = _remote_target
		reset_physics_interpolation()
	var animation_index: int = state[2]
	if alive and animation_index >= 0 and animation_index < _ANIMATIONS.size():
		_play(_ANIMATIONS[animation_index])


func _follow_remote(delta: float) -> void:
	if not _has_remote_target:
		return
	global_position = global_position.lerp(_remote_target, 1.0 - exp(-15.0 * delta))
	_model.rotation.y = lerp_angle(_model.rotation.y, _remote_facing, 15.0 * delta)


func _play(animation: String) -> void:
	if animation == _current_animation:
		return
	_current_animation = animation
	if _animations and _animations.has_animation(animation):
		_animations.play(animation, 0.15)
