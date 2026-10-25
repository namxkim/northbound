extends Area3D

## A moving hazard. Any player that touches it dies.
##
## The enemy works out its position from GameClock.time instead of moving a
## little each frame. That keeps it on the same schedule for every player.

enum Pattern { LINE, CIRCLE, WAYPOINTS, STOP_AND_GO, WANDER }

@export var pattern := Pattern.LINE
## Seconds added to the clock, so enemies with the same pattern can be out of step.
@export var time_offset := 0.0
## On for boulders: the model spins as it rolls. Off for walkers and cars:
## the enemy turns to face where it's going.
@export var rolls := false
## Radius used to work out how fast a boulder spins.
@export var roll_radius := 0.6
## Optional: a model to use instead of the one in the scene (for example a
## different car). It should face +Z, like the Kenney models.
@export var model_scene: PackedScene
@export var model_scale := 1.0
## Optional: a different hitbox radius for round enemies (0 keeps the scene's).
## The red ring on the ground grows to match.
@export var hit_radius := 0.0

@export_group("Line")
## Where the enemy travels to, relative to where it was placed.
@export var line_offset := Vector3(8, 0, 0)
## Seconds for one full trip (there and back, or one way).
@export var line_period := 4.0
## Off: goes there and back. On: goes one way, then reappears at the start,
## like traffic. Hide both ends behind something.
@export var one_way := false

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

@export_group("Stop and go")
## Uses Line Offset and One Way from the Line group.
## Seconds spent moving between stops.
@export var move_time := 1.5
## Seconds spent waiting at each stop. That's when players get through.
@export var pause_time := 1.5

@export_group("Wander")
## Moves to a random spot in this area (width, depth) around where it was
## placed, then another. The spots come from Wander Seed and the round clock,
## so every player's game picks the same "random" spots.
@export var wander_area := Vector2(8, 6)
## Seconds to get from one spot to the next.
@export var wander_step := 1.2
## Chance (0 to 1) of staying put for a step instead of moving.
@export_range(0.0, 0.9) var wander_pause_chance := 0.2
## Different numbers give different paths.
@export var wander_seed := 1

var _origin: Vector3
var _animations: AnimationPlayer
var _facing_set := false

@onready var _model: Node3D = $Model


func _ready() -> void:
	_origin = position
	if hit_radius > 0.0:
		HitSize.apply(self, $Shape, get_node_or_null("DangerRing"), hit_radius)
	if model_scene:
		for child in _model.get_children():
			child.queue_free()
		var look: Node3D = model_scene.instantiate()
		ModelAnimations.center(look, not rolls)
		look.scale = Vector3.ONE * model_scale
		look.rotation.y = PI  # Face -Z, the way the enemy turns to move.
		_model.add_child(look)
	_animations = ModelAnimations.setup(_model, ["sprint", "idle"])
	if _animations:
		_animations.play("sprint")
	position = _origin + offset_at(GameClock.time + time_offset)
	reset_physics_interpolation()


func _physics_process(delta: float) -> void:
	var previous := position
	position = _origin + offset_at(GameClock.time + time_offset)
	var moved := position - previous
	if moved.length() > 3.0:
		# Jumped back to the start of a one-way trip: don't slide across the map.
		reset_physics_interpolation()
		return
	_animate(moved, delta)


func _animate(moved: Vector3, delta: float) -> void:
	var distance := moved.length()
	if _animations and not rolls:
		var animation := "sprint" if distance / delta > 0.3 else "idle"
		if _animations.current_animation != animation and _animations.has_animation(animation):
			_animations.play(animation, 0.2)
	if distance < 0.0001:
		return
	var direction := moved / distance
	if rolls:
		var axis := Vector3.UP.cross(direction).normalized()
		_model.basis = (Basis(axis, distance / roll_radius) * _model.basis).orthonormalized()
	else:
		var facing := atan2(-direction.x, -direction.z)
		rotation.y = facing if not _facing_set else lerp_angle(rotation.y, facing, 12.0 * delta)
		_facing_set = true
		if _animations:
			# Run the animation faster when the enemy moves faster.
			_animations.speed_scale = clampf(distance / delta / 5.0, 0.4, 2.0)


## Where the enemy is at time t, relative to where it was placed.
func offset_at(t: float) -> Vector3:
	match pattern:
		Pattern.LINE:
			var phase := t / maxf(line_period, 0.01)
			if one_way:
				return line_offset * fposmod(phase, 1.0)
			return line_offset * (0.5 - 0.5 * cos(TAU * phase))
		Pattern.CIRCLE:
			var direction := 1.0 if clockwise else -1.0
			var angle := direction * TAU * t / maxf(circle_period, 0.01)
			return Vector3(cos(angle), 0.0, sin(angle)) * circle_radius
		Pattern.WAYPOINTS:
			return _waypoint_offset(t)
		Pattern.STOP_AND_GO:
			return line_offset * _stop_and_go_progress(t)
		Pattern.WANDER:
			var step := maxf(wander_step, 0.05)
			var index := floori(t / step)
			var progress := smoothstep(0.0, 1.0, t / step - index)
			return _wander_spot(index).lerp(_wander_spot(index + 1), progress)
	return Vector3.ZERO


## The wander spot for step number `index`. Same answer on every computer.
func _wander_spot(index: int) -> Vector3:
	# Sometimes stay put: reuse the previous step's spot.
	while index > 0 and _random(index, 2) < wander_pause_chance:
		index -= 1
	return Vector3((_random(index, 0) - 0.5) * wander_area.x, 0.0, (_random(index, 1) - 0.5) * wander_area.y)


## A number from 0 to 1 that looks random but is always the same for the same inputs.
func _random(index: int, channel: int) -> float:
	var h := hash(Vector3i(wander_seed, index, channel))
	return float(posmod(h, 100003)) / 100003.0


## 0 to 1 along the line. There and back: move, wait, move back, wait.
## One way: move halfway, wait, move the rest, then start again.
func _stop_and_go_progress(t: float) -> float:
	var move := maxf(move_time, 0.01)
	var pause := maxf(pause_time, 0.0)
	if one_way:
		var cycle := 2.0 * move + pause
		var time := fposmod(t, cycle)
		if time < move:
			return 0.5 * smoothstep(0.0, 1.0, time / move)
		if time < move + pause:
			return 0.5
		return 0.5 + 0.5 * smoothstep(0.0, 1.0, (time - move - pause) / move)
	var cycle := 2.0 * (move + pause)
	var time := fposmod(t, cycle)
	if time < move:
		return smoothstep(0.0, 1.0, time / move)
	if time < move + pause:
		return 1.0
	if time < 2.0 * move + pause:
		return 1.0 - smoothstep(0.0, 1.0, (time - move - pause) / move)
	return 0.0


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
