class_name ModelAnimations

## Helpers for the models that come with the Kenney packs.


## Finds the model's AnimationPlayer and makes the listed animations loop.
## Returns null if the model has no animations.
static func setup(model: Node, looping: Array[String]) -> AnimationPlayer:
	var players := model.find_children("*", "AnimationPlayer", true, false)
	if players.is_empty():
		return null
	var player: AnimationPlayer = players[0]
	for animation_name in looping:
		if player.has_animation(animation_name):
			player.get_animation(animation_name).loop_mode = Animation.LOOP_LINEAR
	return player


## Moves a model's meshes so they're centered on its origin (left-right and
## front-back), with the bottom at height 0, or centered in height too when
## on_ground is false (for things that roll). Some packs (like the Space Kit)
## place their models off to one side.
static func center(model: Node3D, on_ground := true) -> void:
	var box := AABB()
	var first := true
	for mesh: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		var to_model := Transform3D.IDENTITY
		var node: Node = mesh
		while node != model and node != null:
			to_model = (node as Node3D).transform * to_model
			node = node.get_parent()
		var part := to_model * mesh.get_aabb()
		box = part if first else box.merge(part)
		first = false
	if first:
		return
	var height := -box.position.y if on_ground else -box.get_center().y
	var shift := Vector3(-box.get_center().x, height, -box.get_center().z)
	if shift.length() < 0.01:
		return
	for child in model.get_children():
		if child is Node3D:
			child.position += shift
