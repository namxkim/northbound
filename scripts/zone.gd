@tool
class_name Zone
extends Area3D

## A flat area on the ground that reacts when a player walks onto it.
##
## Add one with Add Node > Zone, then pick its kind and size in the Inspector.
## Its origin is at the bottom center, like Block.

signal player_entered(player: Node3D)

enum Kind { CHECKPOINT, FINISH }

@export var kind := Kind.CHECKPOINT:
	set(value):
		kind = value
		_rebuild()

@export var size := Vector3(20, 2, 3):
	set(value):
		size = value
		_rebuild()

var _mesh := MeshInstance3D.new()
var _shape := CollisionShape3D.new()


func _init() -> void:
	collision_layer = 0
	collision_mask = 2  # Players only.
	monitorable = false
	add_child(_mesh, false, INTERNAL_MODE_FRONT)
	add_child(_shape, false, INTERNAL_MODE_FRONT)
	_rebuild()


func _ready() -> void:
	if not Engine.is_editor_hint():
		body_entered.connect(player_entered.emit)


func _rebuild() -> void:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if kind == Kind.FINISH:
		material.albedo_color = Color(1, 0.8, 0.1, 0.75)
	else:
		material.albedo_color = Color(0.2, 0.85, 0.4, 0.6)

	# A thin plate on the ground shows where the zone is.
	var plate := BoxMesh.new()
	plate.size = Vector3(size.x, 0.05, size.z)
	plate.material = material
	_mesh.mesh = plate
	_mesh.position = Vector3(0, 0.03, 0)

	var box_shape := BoxShape3D.new()
	box_shape.size = size
	_shape.shape = box_shape
	_shape.position = Vector3(0, size.y / 2.0, 0)
