class_name ModelAnimations

## Helpers for the animated models that come with the Kenney packs.


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
