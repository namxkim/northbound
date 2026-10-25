extends Node

## Time since the round started, in seconds.
##
## Enemies work out where they are from this number alone. In online play the
## host will share its clock, so every player's game shows enemies in the same
## place without sending enemy positions over the network.
var time := 0.0
var running := true


func reset() -> void:
	time = 0.0
	running = true


func _physics_process(delta: float) -> void:
	if running:
		time += delta
