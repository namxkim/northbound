@tool
extends MeshInstance3D

## A chunky low-poly boulder, built in code to match the Kenney art style.

@export var radius := 0.6:
	set(value):
		radius = value
		_build()

@export var color := Color(0.58, 0.54, 0.52):
	set(value):
		color = value
		_build()

## How uneven the surface is. 0 is a perfect ball.
@export_range(0.0, 0.4) var lumpiness := 0.15:
	set(value):
		lumpiness = value
		_build()

## Change this to get a differently shaped rock.
@export var shape_seed := 1:
	set(value):
		shape_seed = value
		_build()


func _ready() -> void:
	_build()


func _build() -> void:
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = 8
	sphere.rings = 5

	var arrays := sphere.get_mesh_arrays()
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	# Push each corner in or out a little. Corners that share a spot move
	# together so the surface has no gaps.
	var stretch := {}
	var rng := RandomNumberGenerator.new()
	for i in vertices.size():
		var key := vertices[i].snapped(Vector3.ONE * 0.001)
		if not stretch.has(key):
			rng.seed = hash(key) + shape_seed
			stretch[key] = 1.0 + rng.randf_range(-lumpiness, lumpiness)
		vertices[i] *= stretch[key]
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = null
	arrays[Mesh.ARRAY_TANGENT] = null

	var smooth := ArrayMesh.new()
	smooth.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	# Splitting the corners apart gives every face its own flat shading.
	var surface := SurfaceTool.new()
	surface.create_from(smooth, 0)
	surface.deindex()
	surface.generate_normals()
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 1.0
	surface.set_material(material)
	mesh = surface.commit()
