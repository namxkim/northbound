extends SceneTree

## Checks that every section of a level can be beaten.
##
## For each section (start to first checkpoint, checkpoint to checkpoint, last
## checkpoint to finish) it searches every position and moment for a way
## through, using the hazards' real movement. Hazards are made a bit bigger by
## a safety margin, so a path only counts if it leaves room for human error.
##
## It also tries simple runs (straight north at full speed from a few spots and
## start times) to show how hard each section is: if those mostly survive, the
## section is easy.
##
## Run from the project folder:
##   Godot_console.exe --headless --path . -s tools/solver.gd -- level=res://levels/level_02.tscn
## Options: margin=0.12 (meters added to every hazard), starts=6 (start times tried)

const PLAYER_RADIUS := 0.21  # The player's hurtbox.
const CELL := 0.5
const STEP := 0.14  # Seconds per search step. At 5 m/s that's 0.7 m, one diagonal cell.
const SUBSTEPS := 8  # Hazard samples per step, so fast hazards can't skip over a cell.
const HORIZON := 70.0  # Give up on a section after this many seconds.
const WALL_MASK := 1

var level_path := ""
var margin := 0.12
var start_times := 6
var level: Node3D
var frame := 0

# Current section's grid.
var x_min := -11.0
var z_top := 0.0  # Southmost z (largest).
var columns := 0
var rows := 0
var walkable := PackedByteArray()
var hazards: Array[Dictionary] = []
var danger_cache := {}


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var parts := arg.split("=")
		match parts[0]:
			"level": level_path = parts[1]
			"margin": margin = parts[1].to_float()
			"starts": start_times = parts[1].to_int()
	root.get_node("Levels").saving = false
	level = load(level_path).instantiate()
	root.add_child(level)
	current_scene = level


func _physics_process(_delta: float) -> bool:
	frame += 1
	if frame == 3:
		_run()
		quit()
	return false


func _run() -> void:
	var clock := root.get_node("GameClock")
	clock.running = false
	var player_speed: float = level.player.speed

	var spots: Array[Dictionary] = [{"z": level.get_node("Start").global_position.z, "x": 0.0}]
	var goals: Array = []
	for node in level.find_children("*", "Area3D"):
		if node.has_signal("player_entered"):  # A Zone
			goals.append(node)
	goals.sort_custom(func(a, b): return a.global_position.z > b.global_position.z)

	print("Level %s  (margin %.2f m, %d start times, player speed %.1f m/s)" % [level_path.get_file(), margin, start_times, player_speed])
	var all_ok := true
	var from_z: float = spots[0]["z"]
	for i in goals.size():
		var goal: Area3D = goals[i]
		var label := "%s -> %s" % ["start" if i == 0 else "checkpoint %d" % i, "finish" if goal.kind == 1 else "checkpoint %d" % (i + 1)]
		var result := _solve_section(from_z, goal, player_speed)
		all_ok = all_ok and result["solved"] == start_times
		print("  %-28s beatable from %d/%d start times | fastest %4.1fs, slowest %4.1fs | straight runs survive %3d%%" % [
			label, result["solved"], start_times, result["fastest"], result["slowest"], roundi(result["naive"] * 100)])
		from_z = goal.global_position.z

	# Players respawn side by side at checkpoints. Make sure no hazard ever touches those spots.
	_collect_hazards(1000.0, -1000.0)
	var unsafe := PackedStringArray()
	var places: Array = [level.get_node("Start")]
	for goal in goals:
		if goal.kind == 0:
			places.append(goal)
	for place in places:
		for i in 8:
			var spot: Vector3 = place.global_position + Vector3((i - 3.5) * 0.8, 0, 0)
			for step in 600:
				if _hit(spot, step * 0.05, PLAYER_RADIUS + 0.1):
					unsafe.append("%s spot %d (x=%.1f) at %.2fs" % [place.name, i + 1, spot.x, step * 0.05])
					break
	if unsafe.is_empty():
		print("  spawn spots: all safe")
	else:
		all_ok = false
		print("  spawn spots NOT SAFE: " + ", ".join(unsafe))
	print("RESULT %s: %s" % [level_path.get_file(), "every section beatable" if all_ok else "SOME SECTIONS NOT BEATABLE"])


## True if any hazard touches a circle of radius `pad` at `p` at time `t`.
func _hit(p: Vector3, t: float, pad: float) -> bool:
	for h in hazards:
		match h["type"]:
			"enemy":
				var node = h["node"]
				var q: Vector3 = h["parent"] * (node.get("_origin") + node.offset_at(t + node.time_offset))
				var d := Vector2(p.x - q.x, p.z - q.z)
				if h.has("box"):
					var a := Vector2(node.line_offset.x, node.line_offset.z).normalized()
					var across := Vector2(-a.y, a.x)
					if absf(d.dot(across)) <= h["box"].x + pad and absf(d.dot(a)) <= h["box"].y + pad:
						return true
				elif d.length() <= h["radius"] + pad:
					return true
			"arm":
				var arm = h["node"]
				var yaw: float = arm.get("_base_yaw") + arm.angle_at(t + arm.time_offset)
				var count: int = arm.arms if arm.mode == 0 else 1
				for a in count:
					var direction := Basis(Vector3.UP, yaw + TAU * a / count) * Vector3(0, 0, 1)
					for b in arm.balls:
						var q: Vector3 = arm.global_position + direction * (arm.first_ball + b * arm.spacing)
						if Vector2(p.x - q.x, p.z - q.z).length() <= arm.ball_radius + pad:
							return true
			"spikes":
				var field = h["node"]
				for trap in field.get("_traps"):
					var phase: float = fposmod(t + field.time_offset + trap["column"] * field.wave_delay, field.period)
					var q: Vector3 = trap["area"].global_position
					if phase < field.up_time and absf(p.x - q.x) <= 0.425 + pad and absf(p.z - q.z) <= 0.425 + pad:
						return true
	return false


func _solve_section(from_z: float, goal: Area3D, speed: float) -> Dictionary:
	var goal_z := goal.global_position.z
	z_top = from_z + 1.0
	var z_bottom: float = goal_z - goal.size.z / 2.0 - 0.5
	columns = int((2 * 11.0) / CELL) + 1
	rows = int((z_top - z_bottom) / CELL) + 1
	danger_cache.clear()
	_build_walkable()
	_collect_hazards(z_top + 2.0, z_bottom - 2.0)

	var start_cell := _cell(0.0, from_z)
	var goal_cells := PackedByteArray()
	goal_cells.resize(columns * rows)
	for r in rows:
		for c in columns:
			var p := _point(c, r)
			if absf(p.z - goal_z) <= goal.size.z / 2.0 - 0.3 and absf(p.x - goal.global_position.x) <= goal.size.x / 2.0 - 0.3:
				goal_cells[r * columns + c] = 1

	var solved := 0
	var fastest := INF
	var slowest := 0.0
	for s in start_times:
		var first_step := s * roundi(1.5 / STEP)  # Start times 1.5 s apart.
		var time := _search(start_cell, goal_cells, first_step)
		if time >= 0.0:
			solved += 1
			fastest = minf(fastest, time)
			slowest = maxf(slowest, time)
	return {"solved": solved, "fastest": fastest if solved else -1.0, "slowest": slowest if solved else -1.0,
			"naive": _straight_runs(from_z, goal_z, speed)}


## Seconds to reach the goal starting at step first_step, or -1 if impossible.
func _search(start_cell: int, goal_cells: PackedByteArray, first_step: int) -> float:
	var size := columns * rows
	var reach := PackedByteArray()
	reach.resize(size)
	reach[start_cell] = 1
	var steps := int(HORIZON / STEP)
	for k in steps:
		var danger := _danger(first_step + k)
		var next := PackedByteArray()
		next.resize(size)
		var any := false
		for r in rows:
			var row_start := r * columns
			for c in columns:
				var i := row_start + c
				if walkable[i] == 0 or danger[i] == 1:
					continue
				var ok := reach[i] == 1
				if not ok:
					for dr in [-1, 0, 1]:
						var rr: int = r + dr
						if rr < 0 or rr >= rows:
							continue
						for dc in [-1, 0, 1]:
							var cc: int = c + dc
							if cc >= 0 and cc < columns and reach[rr * columns + cc] == 1:
								ok = true
								break
						if ok:
							break
				if ok:
					next[i] = 1
					any = true
					if goal_cells[i] == 1:
						return (k + 1) * STEP
		if not any:
			return -1.0
		reach = next
	return -1.0


## Straight north at full speed from five spots and every start time.
## Returns the share of runs that make it.
func _straight_runs(from_z: float, goal_z: float, speed: float) -> float:
	var survived := 0
	var total := 0
	for x in [-8.0, -4.0, 0.0, 4.0, 8.0]:
		for s in start_times:
			total += 1
			var first_step := s * roundi(1.5 / STEP)
			var z := from_z
			var alive := true
			var k := 0
			while z > goal_z:
				z -= speed * STEP
				var i := _cell(x, z)
				if i < 0 or walkable[i] == 0 or _danger(first_step + k)[i] == 1:
					alive = false
					break
				k += 1
			if alive:
				survived += 1
	return float(survived) / total


func _cell(x: float, z: float) -> int:
	var c := roundi((x - x_min) / CELL)
	var r := roundi((z_top - z) / CELL)
	if c < 0 or c >= columns or r < 0 or r >= rows:
		return -1
	return r * columns + c


func _point(c: int, r: int) -> Vector3:
	return Vector3(x_min + c * CELL, 0, z_top - r * CELL)


func _build_walkable() -> void:
	var space := level.get_world_3d().direct_space_state
	var shape := CylinderShape3D.new()
	shape.radius = 0.24
	shape.height = 0.8
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.collision_mask = WALL_MASK
	walkable.resize(columns * rows)
	for r in rows:
		for c in columns:
			var p := _point(c, r)
			query.transform = Transform3D(Basis(), p + Vector3(0, 0.55, 0))
			walkable[r * columns + c] = 0 if space.intersect_shape(query, 1).size() > 0 else 1


func _collect_hazards(z_south: float, z_north: float) -> void:
	hazards.clear()
	for node in level.find_children("*", "", true, false):
		if node.has_method("offset_at"):
			var shape: Shape3D = node.get_node("Shape").shape
			var entry := {"type": "enemy", "node": node, "parent": node.get_parent().global_transform}
			if shape is BoxShape3D:
				entry["box"] = Vector2(shape.size.x / 2.0, shape.size.z / 2.0)
			else:
				entry["radius"] = shape.radius
			if _near(node, z_south, z_north, 25.0):
				hazards.append(entry)
		elif node.has_method("angle_at"):  # A HazardArm
			var reach: float = node.first_ball + (node.balls - 1) * node.spacing + node.ball_radius
			if node.global_position.z + reach > z_north and node.global_position.z - reach < z_south:
				hazards.append({"type": "arm", "node": node})
		elif node.get("_traps") != null:  # A SpikeField
			if absf(node.global_position.z - (z_south + z_north) / 2.0) < (z_south - z_north) / 2.0 + node.rows * node.spacing:
				hazards.append({"type": "spikes", "node": node})


func _near(node: Node3D, z_south: float, z_north: float, slack: float) -> bool:
	var z := node.global_position.z
	return z < z_south + slack and z > z_north - slack


## Cells dangerous at any moment during search step `step`.
func _danger(step: int) -> PackedByteArray:
	if danger_cache.has(step):
		return danger_cache[step]
	var grid := PackedByteArray()
	grid.resize(columns * rows)
	var pad := PLAYER_RADIUS + margin
	for sub in SUBSTEPS + 1:
		var t := (step + float(sub) / SUBSTEPS) * STEP
		for h in hazards:
			match h["type"]:
				"enemy":
					var node = h["node"]
					var local: Vector3 = node.get("_origin") + node.offset_at(t + node.time_offset)
					var p: Vector3 = h["parent"] * local
					if h.has("box"):
						var along: Vector3 = node.line_offset.normalized()
						_mark_box(grid, p, along, h["box"], pad)
					else:
						_mark_circle(grid, p, h["radius"] + pad)
				"arm":
					var arm = h["node"]
					var yaw: float = arm.get("_base_yaw") + arm.angle_at(t + arm.time_offset)
					var count: int = arm.arms if arm.mode == 0 else 1  # 0 = spin
					for a in count:
						var direction := Basis(Vector3.UP, yaw + TAU * a / count) * Vector3(0, 0, 1)
						for b in arm.balls:
							_mark_circle(grid, arm.global_position + direction * (arm.first_ball + b * arm.spacing), arm.ball_radius + pad)
				"spikes":
					var field = h["node"]
					for trap in field.get("_traps"):
						var phase: float = fposmod(t + field.time_offset + trap["column"] * field.wave_delay, field.period)
						if phase < field.up_time and phase >= 0.12 - STEP:
							_mark_box(grid, trap["area"].global_position, Vector3(0, 0, 1), Vector2(0.425, 0.425), pad)
	danger_cache[step] = grid
	return grid


func _mark_circle(grid: PackedByteArray, p: Vector3, radius: float) -> void:
	var c0 := maxi(0, floori((p.x - radius - x_min) / CELL))
	var c1 := mini(columns - 1, ceili((p.x + radius - x_min) / CELL))
	var r0 := maxi(0, floori((z_top - p.z - radius) / CELL))
	var r1 := mini(rows - 1, ceili((z_top - p.z + radius) / CELL))
	var r2 := radius * radius
	for r in range(r0, r1 + 1):
		for c in range(c0, c1 + 1):
			var q := _point(c, r)
			if (q.x - p.x) * (q.x - p.x) + (q.z - p.z) * (q.z - p.z) <= r2:
				grid[r * columns + c] = 1


## A box with half-sizes `half` (across, along) facing `along`, grown by `pad`.
func _mark_box(grid: PackedByteArray, p: Vector3, along: Vector3, half: Vector2, pad: float) -> void:
	var a := Vector2(along.x, along.z).normalized()
	var across := Vector2(-a.y, a.x)
	var extent := half.length() + pad
	var c0 := maxi(0, floori((p.x - extent - x_min) / CELL))
	var c1 := mini(columns - 1, ceili((p.x + extent - x_min) / CELL))
	var r0 := maxi(0, floori((z_top - p.z - extent) / CELL))
	var r1 := mini(rows - 1, ceili((z_top - p.z + extent) / CELL))
	for r in range(r0, r1 + 1):
		for c in range(c0, c1 + 1):
			var q := _point(c, r)
			var d := Vector2(q.x - p.x, q.z - p.z)
			if absf(d.dot(across)) <= half.x + pad and absf(d.dot(a)) <= half.y + pad:
				grid[r * columns + c] = 1
