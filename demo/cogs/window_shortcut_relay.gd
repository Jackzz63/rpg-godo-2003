extends Node

var controller: Node


func _input(event: InputEvent) -> void:
	if is_instance_valid(controller):
		controller.handle_shortcut(event, get_viewport())
