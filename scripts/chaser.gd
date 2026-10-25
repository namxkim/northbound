extends CharacterBody3D

## An enemy that runs at the nearest living player it can see, and walks back
## to its post when nobody is near. Walls block it. Always slower than players,
## so you can outrun it.
##
## Unlike other enemies it reacts to players, so it can't be worked out from the
## round clock. The host's game (or the solo player's) moves every chaser and
## sends their positions to everyone else 20 times a second.

## Meters per second. Players run at 5.
@export var speed := 3.4
## How close a player has to be before it gives chase.
@export var sight_radius := 6.0
## It gives up on players who lead it farther than this from its post.
@export var leash_radius := 9.0
## The model to show. It should face +Z, like the Kenney models.
@export var model_scene: PackedScene
@export var model_scale := 1.3
## Optional: a bigger hitbox for wide chasers like vehicles (0 keeps the scene's).
@export var hit_radius := 0.0

## True on the computer that moves chasers (the host, or solo).
var in_charge := true

var _home: Vector3
var _target_position: Vector3
var _animations: AnimationPlayer
var _current_animation := ""
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

@onready var _model: Node3D = $Model


func _ready() -> void:
	_home = global_position
	_target_position = global_position
	if hit_radius > 0.0:
		HitSize.apply(self, $Hitbox/Shape, $ChaseRing, hit_radius)
	if model_scene:
		var look: Node3D = model_scene.instantiate()
		ModelAnimations.center(look)
		look.scale = Vector3.ONE * model_scale
		look.rotation.y = PI  # Face -Z, the way the chaser turns to move.
		_model.add_child(look)
	_animations = ModelAnimations.setup(_model, ["sprint", "idle", "walk"])
	_play("idle")


func _physics_process(delta: float) -> void:
	if not in_charge:
		# Glide to the position the host sent.
		var before := global_position
		global_position = global_position.lerp(_target_position, 1.0 - exp(-12.0 * delta))
		_face_and_animate(global_position - before, delta)
		return
	if not GameClock.running:
		velocity = Vector3.ZERO
		_play("idle")
		return

	var goal := _home
	var chasing := false
	var nearest := sight_radius
	for player in get_tree().get_nodes_in_group("players"):
		if not player.alive:
			continue
		var distance: float = global_position.distance_to(player.global_position)
		if distance < nearest and player.global_position.distance_to(_home) < leash_radius:
			nearest = distance
			goal = player.global_position
			chasing = true

	var to_goal := goal - global_position
	to_goal.y = 0.0
	var flat := Vector2.ZERO
	if to_goal.length() > 0.15:
		var top := speed if chasing else speed * 0.6
		flat = Vector2(to_goal.x, to_goal.z).normalized() * top
	velocity.x = flat.x
	velocity.z = flat.y
	velocity.y = 0.0 if is_on_floor() else velocity.y - _gravity * delta
	var before := global_position
	move_and_slide()
	_face_and_animate(global_position - before, delta)


## Host only: this chaser's state, to send to everyone else.
func get_state() -> Vector3:
	return global_position


## Everyone else: a state sent by the host.
func apply_state(state: Vector3) -> void:
	_target_position = state


func _face_and_animate(moved: Vector3, delta: float) -> void:
	moved.y = 0.0
	var step_speed := moved.length() / maxf(delta, 0.001)
	if step_speed > 0.2:
		var facing := atan2(-moved.x, -moved.z)
		_model.rotation.y = lerp_angle(_model.rotation.y, facing, 10.0 * delta)
		_play("sprint" if step_speed > speed * 0.8 else "walk")
	else:
		_play("idle")


func _play(animation: String) -> void:
	if animation == _current_animation:
		return
	_current_animation = animation
	if _animations and _animations.has_animation(animation):
		_animations.play(animation, 0.15)
