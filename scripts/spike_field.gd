@tool
class_name SpikeField
extends Node3D

## A grid of spike traps that pop up and go back down on a timer.
##
## Add one with Add Node > SpikeField. Spikes only hurt while they're up. The
## red square under each trap glows brighter just before it rises, so players
## get a warning. Wave Delay makes neighbouring columns rise one after another.
## Like enemies, the timing comes from GameClock.time, so it's in sync online.

@export_range(1, 20) var columns := 3:
	set(value):
		columns = value
		_rebuild()
@export_range(1, 20) var rows := 1:
	set(value):
		rows = value
		_rebuild()
## Meters between traps.
@export var spacing := 2.0:
	set(value):
		spacing = value
		_rebuild()
## Seconds for one full down-and-up cycle.
@export var period := 3.0
## Seconds the spikes stay up in each cycle.
@export var up_time := 1.2
## Extra delay for each column, in seconds. Makes a wave across the field.
@export var wave_delay := 0.0
## Seconds added to the clock, so fields can be out of step with each other.
@export var time_offset := 0.0
## Seconds of warning glow before the spikes rise.
@export var warning_time := 0.5

const _TRAP_MODEL := preload("res://assets/dungeon/trap.glb")
## Spikes start hurting a moment after they start rising, so the warning is fair.
const _RISE_DELAY := 0.12

var _traps: Array[Dictionary] = []
var _grid := Node3D.new()
var _calm := StandardMaterial3D.new()
var _warning := StandardMaterial3D.new()
var _danger := StandardMaterial3D.new()


func _init() -> void:
	for material in [_calm, _warning, _danger]:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_calm.albedo_color = Color(1, 0.15, 0.1, 0.12)
	_warning.albedo_color = Color(1, 0.55, 0.1, 0.55)
	_danger.albedo_color = Color(1, 0.15, 0.1, 0.5)
	add_child(_grid, false, INTERNAL_MODE_FRONT)
	_rebuild()


func _ready() -> void:
	if not Engine.is_editor_hint():
		_update(true)


func _physics_process(_delta: float) -> void:
	if not Engine.is_editor_hint():
		_update(false)


func _rebuild() -> void:
	for child in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()
	_traps.clear()

	for column in columns:
		for row in rows:
			var spot := Vector3(
				(column - (columns - 1) / 2.0) * spacing, 0.0,
				(row - (rows - 1) / 2.0) * spacing)
			_traps.append(_make_trap(spot, column))


func _make_trap(at: Vector3, column: int) -> Dictionary:
	var area := Area3D.new()
	area.collision_layer = 4  # Enemies.
	area.collision_mask = 0
	area.monitoring = false
	area.monitorable = false
	area.position = at
	_grid.add_child(area)

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.4, 0.8, 1.4)
	shape.shape = box
	shape.position.y = 0.4
	area.add_child(shape)

	var model: Node3D = _TRAP_MODEL.instantiate()
	model.scale = Vector3.ONE * 2.0
	area.add_child(model)

	var plate := MeshInstance3D.new()
	var plate_mesh := BoxMesh.new()
	plate_mesh.size = Vector3(1.8, 0.02, 1.8)
	plate.mesh = plate_mesh
	plate.material_override = _calm
	plate.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	plate.position.y = 0.01
	area.add_child(plate)

	var players := model.find_children("*", "AnimationPlayer", true, false)
	return {
		"area": area,
		"plate": plate,
		"animations": players[0] if not players.is_empty() else null,
		"column": column,
		"up": null,
	}


func _update(instant: bool) -> void:
	for trap in _traps:
		var phase := fposmod(GameClock.time + time_offset + trap["column"] * wave_delay, maxf(period, 0.01))
		var up := phase < up_time
		var hurts := up and phase >= _RISE_DELAY
		var warning := not up and phase >= period - warning_time

		var area: Area3D = trap["area"]
		if area.monitorable != hurts:
			area.set_deferred("monitorable", hurts)
		trap["plate"].material_override = _danger if up else (_warning if warning else _calm)

		if trap["up"] != up:
			trap["up"] = up
			var animations: AnimationPlayer = trap["animations"]
			if animations:
				animations.play("show" if up else "hide")
				if instant:
					animations.seek(animations.current_animation_length, true)
