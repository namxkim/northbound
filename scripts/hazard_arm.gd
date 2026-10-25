@tool
class_name HazardArm
extends Node3D

## A post with one or more arms of spiked balls that spin around it, or one
## arm that swings back and forth like a pendulum.
##
## Add one with Add Node > HazardArm. Turn the node to choose which way the
## arm points at the start (and, for a pendulum, the middle of its swing).
## Like enemies, it moves by GameClock.time, so it's in sync online.

enum Mode { SPIN, SWING }

@export var mode := Mode.SPIN:
	set(value):
		mode = value
		_rebuild()
## Seconds for one full turn (spin) or one swing there and back (swing).
@export var period := 4.0
## Seconds added to the clock, so arms can be out of step with each other.
@export var time_offset := 0.0
@export var clockwise := true
## Swing only: how far the arm swings to each side, in degrees.
@export_range(5.0, 175.0) var swing_angle := 60.0

@export_group("Shape")
## Spin only: arms evenly spaced around the post, like a fan.
@export_range(1, 4) var arms := 1:
	set(value):
		arms = value
		_rebuild()
## Spiked balls on each arm.
@export_range(1, 12) var balls := 4:
	set(value):
		balls = value
		_rebuild()
## Meters between balls.
@export var spacing := 1.2:
	set(value):
		spacing = value
		_rebuild()
## Meters from the post to the first ball.
@export var first_ball := 1.2:
	set(value):
		first_ball = value
		_rebuild()
@export var ball_radius := 0.45:
	set(value):
		ball_radius = value
		_rebuild()
@export var ball_color := Color(0.35, 0.3, 0.33):
	set(value):
		ball_color = value
		_rebuild()

const _ROCK_SCRIPT := preload("res://scripts/low_poly_rock.gd")

var _base_yaw := 0.0
var _parts := Node3D.new()


func _init() -> void:
	add_child(_parts, false, INTERNAL_MODE_FRONT)
	_rebuild()


func _ready() -> void:
	_base_yaw = rotation.y
	if not Engine.is_editor_hint():
		rotation.y = _base_yaw + angle_at(GameClock.time + time_offset)
		reset_physics_interpolation()


func _physics_process(_delta: float) -> void:
	if not Engine.is_editor_hint():
		rotation.y = _base_yaw + angle_at(GameClock.time + time_offset)


## How far the arm has turned from where it was placed, at time t.
func angle_at(t: float) -> float:
	var direction := -1.0 if clockwise else 1.0
	var phase := t / maxf(period, 0.01)
	if mode == Mode.SPIN:
		return direction * TAU * phase
	return direction * deg_to_rad(swing_angle) * sin(TAU * phase)


func _rebuild() -> void:
	for child in _parts.get_children():
		_parts.remove_child(child)
		child.queue_free()

	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.25, 0.22, 0.22)

	var post := MeshInstance3D.new()
	var post_mesh := CylinderMesh.new()
	post_mesh.top_radius = 0.3
	post_mesh.bottom_radius = 0.4
	post_mesh.height = 1.4
	post_mesh.material = dark
	post.mesh = post_mesh
	post.position.y = 0.7
	_parts.add_child(post)

	var arm_count := arms if mode == Mode.SPIN else 1
	var length := first_ball + (balls - 1) * spacing
	for a in arm_count:
		var arm := Node3D.new()
		arm.rotation.y = TAU * a / arm_count
		_parts.add_child(arm)

		# A thin bar from the post to the last ball, so players can read the arm.
		var bar := MeshInstance3D.new()
		var bar_mesh := BoxMesh.new()
		bar_mesh.size = Vector3(0.12, 0.12, length)
		bar_mesh.material = dark
		bar.mesh = bar_mesh
		bar.position = Vector3(0, ball_radius + 0.05, length / 2.0)
		arm.add_child(bar)

		for b in balls:
			arm.add_child(_make_ball(Vector3(0, ball_radius + 0.05, first_ball + b * spacing)))


func _make_ball(at: Vector3) -> Area3D:
	var ball := Area3D.new()
	ball.collision_layer = 4  # Enemies.
	ball.collision_mask = 0
	ball.monitoring = false
	ball.position = at

	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = ball_radius
	shape.shape = sphere
	ball.add_child(shape)

	var rock := MeshInstance3D.new()
	rock.set_script(_ROCK_SCRIPT)
	rock.set("radius", ball_radius)
	rock.set("color", ball_color)
	rock.set("lumpiness", 0.3)
	ball.add_child(rock)

	var ring := MeshInstance3D.new()
	var ring_mesh := CylinderMesh.new()
	ring_mesh.top_radius = ball_radius + 0.2
	ring_mesh.bottom_radius = ball_radius + 0.2
	ring_mesh.height = 0.02
	var ring_material := StandardMaterial3D.new()
	ring_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_material.albedo_color = Color(1, 0.15, 0.1, 0.45)
	ring_mesh.material = ring_material
	ring.mesh = ring_mesh
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.position.y = -at.y + 0.02
	ball.add_child(ring)
	return ball
