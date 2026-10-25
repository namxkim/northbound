@tool
class_name Block
extends StaticBody3D

## A solid box of terrain that players can't walk through.
##
## Add one with Add Node > Block, then set its size and color in the Inspector.
## Its origin is at the bottom center, so a block at height 0 sits on the ground.
##
## To make it look like part of the world, pick a Decoration model (a tree, a
## fence, a rock) and turn off Show Box. The model is repeated across the block.

@export var size := Vector3(2, 1.5, 2):
	set(value):
		size = value
		_rebuild()

@export var color := Color(0.5, 0.5, 0.55):
	set(value):
		color = value
		_rebuild()

## Turn off to hide the plain box and show only the decoration.
@export var show_box := true:
	set(value):
		show_box = value
		_rebuild()

@export_group("Decoration")
## A model repeated across the block, like a row of trees.
@export var decoration: PackedScene:
	set(value):
		decoration = value
		_rebuild()

@export var decoration_scale := 2.0:
	set(value):
		decoration_scale = value
		_rebuild()

## Meters between copies.
@export var decoration_spacing := 2.0:
	set(value):
		decoration_spacing = value
		_rebuild()

## Turn each copy a random amount, which looks natural for trees and rocks.
## When off, copies line up with the block's long side, which suits fences.
@export var random_turn := true:
	set(value):
		random_turn = value
		_rebuild()

# Built in code and never saved, so the level file only stores the settings.
var _mesh := MeshInstance3D.new()
var _shape := CollisionShape3D.new()
var _decor := Node3D.new()


func _init() -> void:
	add_child(_mesh, false, INTERNAL_MODE_FRONT)
	add_child(_shape, false, INTERNAL_MODE_FRONT)
	add_child(_decor, false, INTERNAL_MODE_FRONT)
	_rebuild()


func _rebuild() -> void:
	var material := StandardMaterial3D.new()
	material.albedo_color = color

	var box := BoxMesh.new()
	box.size = size
	box.material = material
	_mesh.mesh = box
	_mesh.position = Vector3(0, size.y / 2.0, 0)
	_mesh.visible = show_box

	var box_shape := BoxShape3D.new()
	box_shape.size = size
	_shape.shape = box_shape
	_shape.position = Vector3(0, size.y / 2.0, 0)

	_rebuild_decoration()


func _rebuild_decoration() -> void:
	for child in _decor.get_children():
		_decor.remove_child(child)
		child.queue_free()
	if decoration == null or decoration_spacing <= 0.0:
		return

	var count_x := maxi(1, roundi(size.x / decoration_spacing))
	var count_z := maxi(1, roundi(size.z / decoration_spacing))
	var along_z := size.z > size.x
	for ix in count_x:
		for iz in count_z:
			var copy: Node3D = decoration.instantiate()
			copy.scale = Vector3.ONE * decoration_scale
			copy.position = Vector3(
				-size.x / 2.0 + (ix + 0.5) * size.x / count_x,
				0.0,
				-size.z / 2.0 + (iz + 0.5) * size.z / count_z)
			if random_turn:
				# Same "random" turn every time, so the level looks the same on every load.
				var rng := RandomNumberGenerator.new()
				rng.seed = hash(Vector3i(ix, iz, roundi(position.x * 7.0 + position.z * 13.0)))
				copy.rotation.y = rng.randf() * TAU
			elif along_z:
				copy.rotation.y = PI / 2.0
			_decor.add_child(copy)
