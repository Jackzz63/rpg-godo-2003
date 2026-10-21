extends Node

var control: Control
var slop := 12.0
var _finger := -1
var _start := Vector2.ZERO
var _serial := 0
var _ready_to_open := false


func _ready() -> void:
	control.gui_input.connect(_input_at_control)
	control.visibility_changed.connect(cancel)
	control.tree_exiting.connect(cancel)


func cancel() -> void:
	_serial += 1
	_finger = -1
	_ready_to_open = false


func _input_at_control(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed and _finger < 0:
			_finger = event.index
			_start = event.position
			_serial += 1
			_arm(_serial)
		elif event.index == _finger:
			var open: bool = _ready_to_open and not event.canceled
			var point: Vector2 = control.get_global_transform_with_canvas() * event.position
			cancel()
			if open:
				var click := InputEventMouseButton.new()
				click.button_index = MOUSE_BUTTON_RIGHT
				click.pressed = true
				click.position = event.position
				click.global_position = point
				# Reuse the current live data/permission handler, not a copied player record.
				control.gui_input.emit(click)
				control.accept_event()
	elif event is InputEventScreenDrag and event.index == _finger:
		if event.position.distance_to(_start) > slop:
			cancel()


func _arm(serial: int) -> void:
	await get_tree().create_timer(0.5).timeout
	if serial == _serial and control.is_visible_in_tree():
		_ready_to_open = true


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		cancel()
