extends Area3D

## A moving hazard. Any player that touches it dies.
##
## The enemy works out its position from GameClock.time instead of moving a
## little each frame. That keeps it on the same schedule for every player.

enum Pattern { LINE, CIRCLE, WAYPOINTS }

@export var pattern := Pattern.LINE
## Seconds added to the clock, so enemies with the same pattern can be out of step.
@export var time_offset := 0.0
## On for boulders: the model spins as it rolls. Off for walkers: the model
## turns to face where it's going.
@export var rolls := false
## Radius used to work out how fast a boulder spins.
@export var roll_radius := 0.6

@export_group("Line")
## Where the enemy travels to and back from, relative to where it was placed.
@export var line_offset := Vector3(8, 0, 0)
## Seconds for one full trip there and back.
@export var line_period := 4.0

@export_group("Circle")
## The enemy circles around the spot where it was placed.
@export var circle_radius := 3.0
## Seconds for one full lap.
@export var circle_period := 5.0
@export var clockwise := true

@export_group("Waypoints")
## Points to visit, relative to where it was placed. It loops back to the start.
@export var waypoints := PackedVector3Array()
## Meters per second.
@export var waypoint_speed := 4.0

var _origin: Vector3
var _animations: AnimationPlayer

@onready var _model: Node3D = $Model


func _ready() -> void:
	_origin = position
	_animations = ModelAnimations.setup(_model, ["sprint"])
	if _animations:
		_animations.play("sprint")
	position = _origin + offset_at(GameClock.time + time_offset)
	reset_physics_interpolation()


func _physics_process(delta: float) -> void:
	var previous := position
	position = _origin + offset_at(GameClock.time + time_offset)
	_animate(position - previous, delta)


func _animate(moved: Vector3, delta: float) -> void:
	var distance := moved.length()
	if distance < 0.0001:
		return
	var direction := moved / distance
	if rolls:
		var axis := Vector3.UP.cross(direction).normalized()
		_model.basis = (Basis(axis, distance / roll_radius) * _model.basis).orthonormalized()
	else:
		var facing := atan2(-direction.x, -direction.z)
		_model.rotation.y = lerp_angle(_model.rotation.y, facing, 12.0 * delta)
		if _animations:
			# Run the animation faster when the enemy moves faster.
			_animations.speed_scale = clampf(distance / delta / 5.0, 0.4, 2.0)


## Where the enemy is at time t, relative to where it was placed.
func offset_at(t: float) -> Vector3:
	match pattern:
		Pattern.LINE:
			var phase := t / maxf(line_period, 0.01)
			return line_offset * (0.5 - 0.5 * cos(TAU * phase))
		Pattern.CIRCLE:
			var direction := 1.0 if clockwise else -1.0
			var angle := direction * TAU * t / maxf(circle_period, 0.01)
			return Vector3(cos(angle), 0.0, sin(angle)) * circle_radius
		Pattern.WAYPOINTS:
			return _waypoint_offset(t)
	return Vector3.ZERO


func _waypoint_offset(t: float) -> Vector3:
	if waypoints.is_empty() or waypoint_speed <= 0.0:
		return Vector3.ZERO

	var points := PackedVector3Array([Vector3.ZERO])
	points.append_array(waypoints)

	var total := 0.0
	for i in points.size():
		total += points[i].distance_to(points[(i + 1) % points.size()])
	if total <= 0.0:
		return Vector3.ZERO

	var distance := fposmod(t * waypoint_speed, total)
	for i in points.size():
		var from := points[i]
		var to := points[(i + 1) % points.size()]
		var length := from.distance_to(to)
		if length > 0.0 and distance <= length:
			return from.lerp(to, distance / length)
		distance -= length
	return Vector3.ZERO
