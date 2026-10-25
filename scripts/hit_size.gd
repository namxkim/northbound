class_name HitSize

## Resizes a round enemy's hitbox and the ring that shows it on the ground.


static func apply(_owner: Node, shape_node: CollisionShape3D, ring: MeshInstance3D, radius: float) -> void:
	var shape: Shape3D = shape_node.shape.duplicate()
	if shape is CapsuleShape3D or shape is SphereShape3D:
		shape.radius = radius
		if shape is CapsuleShape3D:
			shape.height = maxf(shape.height, radius * 2.0)
	shape_node.shape = shape
	if ring and ring.mesh is CylinderMesh:
		var mesh: CylinderMesh = ring.mesh.duplicate()
		mesh.top_radius = radius + 0.18
		mesh.bottom_radius = radius + 0.18
		ring.mesh = mesh
