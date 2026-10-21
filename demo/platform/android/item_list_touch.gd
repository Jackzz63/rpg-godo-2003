extends Node

# ItemList owns its own scrollbar; a drag must never select the row at release.
var list: ItemList
var slop := 12.0
var activate_on_tap := false
var _finger := -1
var _start := Vector2.ZERO
var _last := Vector2.ZERO
var _dragged := false


func _ready() -> void:
	list.visibility_changed.connect(cancel)
	list.tree_exiting.connect(cancel)


func cancel() -> void:
	_finger = -1


func _visible_rect() -> Rect2:
	var rect := list.get_global_rect()
	var parent := list.get_parent()
	while parent is Control:
		if parent.clip_contents: rect = rect.intersection(parent.get_global_rect())
		parent = parent.get_parent()
	return rect


func _input(event: InputEvent) -> void:
	if not list.is_visible_in_tree(): return
	var rect := _visible_rect()
	var bar := list.get_v_scroll_bar()
	if event is InputEventMouse and event.device == -1:
		if rect.has_point(event.position) and not (bar.visible and bar.get_global_rect().has_point(event.position)):
			get_viewport().set_input_as_handled()
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			if _finger >= 0 or not rect.has_point(event.position): return
			if bar.visible and bar.get_global_rect().has_point(event.position): return
			_finger = event.index
			_start = event.position
			_last = _start
			_dragged = false
		elif event.index == _finger:
			if not event.canceled and not _dragged and rect.has_point(event.position):
				var row := list.get_item_at_position(event.position - list.global_position, true)
				if row >= 0:
					list.select(row)
					list.item_selected.emit(row)
					if activate_on_tap: list.item_activated.emit(row)
			cancel()
		else: return
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag and event.index == _finger:
		if _dragged or event.position.distance_to(_start) > slop:
			_dragged = true
			bar.value -= event.position.y - _last.y
		_last = event.position
		get_viewport().set_input_as_handled()
