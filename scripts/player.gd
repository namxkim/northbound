extends CharacterBody3D

## Sent when an enemy touches this player.
signal died

## Which character model this player uses. In co-op each player can get a different one.
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

var alive := true
## When true the player ignores input, for example after reaching the finish.
var frozen := false

var _protection_left := 0.0
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var _animations: AnimationPlayer

@onready var _model: Node3D = $Model
@onready var _hurtbox: Area3D = $Hurtbox


func _ready() -> void:
	var look: Node3D = character.instantiate()
	look.scale = Vector3.ONE * character_scale
	# The models face +Z. Turning them around makes -Z (north) the player's forward.
	look.rotation.y = PI
	_model.add_child(look)
	_animations = ModelAnimations.setup(look, ["idle", "walk", "sprint"])
	_play("idle")


func _physics_process(delta: float) -> void:
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


func die() -> void:
	if not alive:
		return
	alive = false
	velocity = Vector3.ZERO
	_model.visible = true
	_play("die")
	died.emit()


func respawn(at: Vector3) -> void:
	global_position = at
	velocity = Vector3.ZERO
	alive = true
	frozen = false
	_model.visible = true
	_protection_left = respawn_protection
	_play("idle")
	reset_physics_interpolation()


func _play(animation: String) -> void:
	if _animations and _animations.current_animation != animation and _animations.has_animation(animation):
		_animations.play(animation, 0.15)
