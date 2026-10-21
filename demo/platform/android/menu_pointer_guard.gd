extends Node

# This node is installed after the drawer's scrolling children, so it observes
# touches before they are consumed there. It only owns the outside gesture.
var drawer: Control
var scroll_gesture: Node
var dismiss: Callable
var slop := 12.0
var _fingers: Dictionary = {}
var _pending := false
var _serial := 0
var _mouse_down := false
var _mouse_start := Vector2.ZERO
var _mouse_dragged := false


func cancel() -> void:
	_serial += 1
	_fingers.clear()
	_pending = false
	_mouse_down = false
	_mouse_dragged = false
	if is_instance_valid(scroll_gesture):
		scroll_gesture.cancel()


func _input(event: InputEvent) -> void:
	if not is_instance_valid(drawer) or not drawer.is_visible_in_tree():
		return
	var outside := false
	if event is InputEventScreenTouch or event is InputEventScreenDrag or event is InputEventMouse:
		outside = not drawer.get_global_rect().has_point(event.position)
	if event is InputEventScreenTouch:
		if event.pressed and not event.canceled:
			_fingers[event.index] = {"outside": outside, "start": event.position, "dragged": false}
			if outside or _pending:
				get_viewport().set_input_as_handled()
		else:
			var finger: Dictionary = _fingers.get(event.index, {})
			_fingers.erase(event.index)
			if finger.is_empty() or bool(finger.get("outside", false)) or _pending:
				get_viewport().set_input_as_handled()
			if not event.canceled and bool(finger.get("outside", false)) and not bool(finger.get("dragged", true)) and outside:
				_request_close()
			elif _pending:
				_finish_close.call_deferred(_serial)
	elif event is InputEventScreenDrag:
		if _fingers.has(event.index):
			var finger: Dictionary = _fingers[event.index]
			if event.position.distance_to(finger.start) > slop:
				finger.dragged = true
			if bool(finger.outside) or _pending:
				get_viewport().set_input_as_handled()
		else:
			get_viewport().set_input_as_handled()
	elif event is InputEventMouse:
		# Godot may dispatch this before the original ScreenTouch. Never close
		# from the duplicated mouse event, and keep both event orders blocked.
		if event.device == -1:
			if outside or _pending or _outside_finger_active():
				get_viewport().set_input_as_handled()
			return
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and outside:
				_mouse_down = true
				_mouse_start = event.position
				_mouse_dragged = false
			elif not event.pressed and _mouse_down:
				_mouse_down = false
				if outside and not _mouse_dragged and not event.canceled:
					_request_close()
				get_viewport().set_input_as_handled()
		elif event is InputEventMouseMotion and _mouse_down:
			_mouse_dragged = _mouse_dragged or event.position.distance_to(_mouse_start) > slop
		if outside or _mouse_down or _pending:
			get_viewport().set_input_as_handled()


func _unhandled_input(_event: InputEvent) -> void:
	if is_instance_valid(drawer) and drawer.is_visible_in_tree():
		get_viewport().set_input_as_handled()


func _outside_finger_active() -> bool:
	for finger: Dictionary in _fingers.values():
		if bool(finger.outside):
			return true
	return false


func _request_close() -> void:
	_pending = true
	if is_instance_valid(scroll_gesture):
		scroll_gesture.cancel()
	_finish_close.call_deferred(_serial)


func _finish_close(serial: int) -> void:
	if serial == _serial and _pending and _fingers.is_empty() and not _mouse_down and drawer.is_visible_in_tree():
		cancel()
		dismiss.call()
