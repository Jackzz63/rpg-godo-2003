class_name ChatSelectionOverlay
extends Control
signal touch_context_requested(position: Vector2)
signal touch_context_dragged
var _touch_menu: Window
var touch_enabled := false
var touch_slop := 12.0
var _touch_finger := -1
var _touch_start := Vector2.ZERO
var _touch_last := Vector2.ZERO
var _touch_serial := 0
var _touch_scroll := false
var _touch_select := false

signal link_clicked(url: String)
signal spoiler_reveal_requested(message_id: int, segment: int)

const _SELECTION_COLOR := Color(0.08, 0.22, 0.95, 0.68)
const _SELECT_TEXT_META := &"chat_select_text"
const _HARD_BREAK_META := &"chat_select_hard_break_before"
const _LINK_META := &"chat_link_url"
const Mentions := preload("res://cogs/chat_mentions.gd")

const _AUTO_SCROLL_SPEED_MULTIPLIER := 2.5

var _source_root: Control = null
var _runs: Array[Dictionary] = []
var _logical_text := ""
var _anchor := -1
var _caret := -1
var _dragging := false
var _pressed_index := -1
var _pressed_url := ""
var _pressed_action: Dictionary = {}
var _press_position := Vector2.ZERO
var _drag_moved := false
var _history_records: Array[Dictionary] = []
var _scroll_container: Control = null
var _scroll_bar: VScrollBar = null
var _record_ranges: Dictionary = {}
var _record_positions: Dictionary = {}
var _auto_scroll_line_height := 16.0
var _layout_pending := false


func setup(
		source_root: Control, scroll_container: Control = null,
		scroll_bar: VScrollBar = null) -> void:
	_source_root = source_root
	_scroll_container = scroll_container
	_scroll_bar = scroll_bar
	focus_mode = Control.FOCUS_CLICK
	clip_contents = false
	content_changed()


func set_history(records: Array[Dictionary]) -> void:
	_history_records = records.duplicate()
	var previous_text := _logical_text
	var previous_anchor := _anchor
	var previous_caret := _caret
	var previous_ranges := _record_ranges.duplicate()
	var previous_positions := _record_positions.duplicate(true)
	var pressed_endpoint := _selection_endpoint(_pressed_index, previous_ranges)
	_record_ranges.clear()
	_record_positions.clear()
	_logical_text = ""
	for record in records:
		if not _logical_text.is_empty():
			_logical_text += "\n"
		var message_id := int(record.get("message_id", 0))
		var text := str(record.get("selection_text", ""))
		var start := _logical_text.length()
		_record_ranges[message_id] = Vector2i(start, start + text.length())
		_record_positions[message_id] = {
			"name": int(record.get("selection_name_length", 0)),
			"source_name": int(record.get("selection_source_name_length", 0)),
			"body": int(record.get("body_selection_offset", 0)),
			"to_source": record.get("body_display_to_source", PackedInt32Array()),
			"to_display": record.get("body_source_to_display", PackedInt32Array()),
		}
		_logical_text += text
	_restore_selection_after_text_change(
		previous_text, previous_anchor, previous_caret, previous_ranges, previous_positions)
	if _dragging and not pressed_endpoint.is_empty():
		_pressed_index = _restore_selection_endpoint(pressed_endpoint)
		if not _record_ranges.has(int(pressed_endpoint.get("message_id", 0))):
			_pressed_url = ""
	if _layout_pending:
		_runs.clear()
	else:
		_rebuild_runs()
	queue_redraw()


func begin_layout_update() -> void:
	_layout_pending = true
	_runs.clear()


func commit_layout_update() -> void:
	_layout_pending = false
	_rebuild_runs()
	queue_redraw()


func is_layout_pending() -> bool:
	return _layout_pending


func set_auto_scroll_line_height(value: float) -> void:
	_auto_scroll_line_height = maxf(1.0, value)


func capture_text_anchor(global_position: Vector2) -> Dictionary:
	var hit := _character_at(global_position)
	var logical_index := int(hit.get("index", -1))
	if logical_index < 0:
		return {}
	for message_id_variant in _record_ranges:
		var record_range: Vector2i = _record_ranges[message_id_variant]
		if logical_index < record_range.x or logical_index > record_range.y:
			continue
		return {
			"message_id": int(message_id_variant),
			"record_offset": logical_index - record_range.x,
			"source_position": _source_position(int(message_id_variant), logical_index - record_range.x, _record_positions),
			"affinity": str(hit.get("affinity", "forward")),
			"line_y_ratio": float(hit.get("line_y_ratio", 0.5)),
		}
	return {}


func resolve_text_anchor(anchor: Dictionary) -> Dictionary:
	var message_id := int(anchor.get("message_id", 0))
	if message_id <= 0 or not _record_ranges.has(message_id):
		return {"state": "missing"}
	if _layout_pending:
		return {"state": "pending"}
	if _runs.is_empty():
		_rebuild_runs()
	var record_range: Vector2i = _record_ranges[message_id]
	var logical_index := clampi(
		record_range.x + _display_position(message_id, anchor.get("source_position", {}), int(anchor.get("record_offset", 0))),
		record_range.x,
		record_range.y)
	var resolved: Variant = _global_position_for_logical_index(
		logical_index,
		str(anchor.get("affinity", "forward")),
		float(anchor.get("line_y_ratio", 0.5)))
	if resolved == null:
		return {"state": "offscreen"}
	return {"state": "resolved", "position": resolved as Vector2}


func content_changed() -> void:
	if _layout_pending:
		_runs.clear()
	else:
		_rebuild_runs()
	queue_redraw()


func _source_position(message_id: int, offset: int, positions: Dictionary) -> Dictionary:
	var info: Dictionary = positions.get(message_id, {})
	if info.is_empty() or int(info.body) <= 0:
		return {}
	if offset >= int(info.body):
		return {"part": "body", "offset": Mentions.mapped_offset(info.to_source, offset - int(info.body))}
	if offset <= int(info.name) and int(info.name) > 0:
		return {"part": "name", "offset": int(float(offset * int(info.source_name)) / int(info.name))}
	return {"part": "header", "offset": offset - int(info.name)}


func _display_position(message_id: int, position: Dictionary, fallback: int) -> int:
	var info: Dictionary = _record_positions.get(message_id, {})
	if position.is_empty() or info.is_empty():
		return fallback
	var offset := int(position.offset)
	match str(position.part):
		"body": return int(info.body) + Mentions.mapped_offset(info.to_display, offset)
		"name": return int(float(offset * int(info.name)) / maxi(1, int(info.source_name)))
		"header": return mini(int(info.body) - 1, int(info.name) + offset)
	return fallback


func _restore_selection_after_text_change(
		previous_text: String, previous_anchor: int, previous_caret: int,
		previous_ranges: Dictionary, previous_positions: Dictionary) -> void:
	if previous_text == _logical_text:
		_anchor = clampi(previous_anchor, -1, _logical_text.length())
		_caret = clampi(previous_caret, -1, _logical_text.length())
		return
	var anchor_endpoint := _selection_endpoint(previous_anchor, previous_ranges, previous_positions)
	var caret_endpoint := _selection_endpoint(previous_caret, previous_ranges, previous_positions)
	if (anchor_endpoint.is_empty() or caret_endpoint.is_empty()
			or _record_ranges.is_empty()):
		deselect()
		cancel_drag()
		return
	var first_id := mini(
		int(anchor_endpoint["message_id"]), int(caret_endpoint["message_id"]))
	var last_id := maxi(
		int(anchor_endpoint["message_id"]), int(caret_endpoint["message_id"]))
	var has_surviving_record := false
	for message_id in _record_ranges:
		if int(message_id) >= first_id and int(message_id) <= last_id:
			has_surviving_record = true
			break
	if not has_surviving_record:
		_anchor = -1
		_caret = -1
		cancel_drag()
		return
	_anchor = _restore_selection_endpoint(anchor_endpoint)
	_caret = _restore_selection_endpoint(caret_endpoint)


func _selection_endpoint(index: int, ranges: Dictionary, positions: Dictionary = _record_positions) -> Dictionary:
	if index < 0:
		return {}
	for message_id in ranges:
		var span: Vector2i = ranges[message_id]
		if index >= span.x and index <= span.y:
			return {"message_id": int(message_id), "offset": index - span.x,
				"source_position": _source_position(int(message_id), index - span.x, positions)}
	return {}


func _restore_selection_endpoint(endpoint: Dictionary) -> int:
	var message_id := int(endpoint.get("message_id", 0))
	if _record_ranges.has(message_id):
		var span: Vector2i = _record_ranges[message_id]
		return span.x + clampi(_display_position(message_id, endpoint.get("source_position", {}), int(endpoint.get("offset", 0))), 0, span.y - span.x)
	for retained_id in _record_ranges:
		if int(retained_id) > message_id:
			return int((_record_ranges[retained_id] as Vector2i).x)
	return _logical_text.length()


func reset_selection() -> void:
	_history_records.clear()
	_pressed_action.clear()
	_layout_pending = false
	_runs.clear()
	_logical_text = ""
	_anchor = -1
	_caret = -1
	_dragging = false
	_pressed_index = -1
	_pressed_url = ""
	set_process(false)
	queue_redraw()


func deselect() -> void:
	_anchor = -1
	_caret = -1
	_dragging = false
	set_process(false)
	queue_redraw()


func cancel_drag() -> void:
	_pressed_action.clear()
	_dragging = false
	_pressed_index = -1
	_pressed_url = ""
	set_process(false)


func has_selection() -> bool:
	var selected := _selection_range()
	return selected.x >= 0 and selected.y > selected.x


func select_all() -> void:
	_anchor = 0
	_caret = _logical_text.length()
	queue_redraw()


func select_word_at(global_position: Vector2) -> void:
	var hit := _character_at(global_position)
	var index := int(hit.get("index", -1))
	if index < 0 or _logical_text.is_empty():
		return
	index = mini(index, _logical_text.length() - 1)
	var character := _logical_text.substr(index, 1)
	if _is_cjk_character(character):
		_anchor = index
		_caret = index + 1
	else:
		var start := index
		var end := index
		while start > 0 and _is_word_character(_logical_text.substr(start - 1, 1)):
			start -= 1
		while end < _logical_text.length() and _is_word_character(
				_logical_text.substr(end, 1)):
			end += 1
		if start == end:
			end = mini(_logical_text.length(), index + 1)
		_anchor = start
		_caret = end
	queue_redraw()


func _is_word_character(character: String) -> bool:
	if character.is_empty():
		return false
	var code := character.unicode_at(0)
	return (character == "_"
		or (code >= 48 and code <= 57)
		or character.to_lower() != character.to_upper())


func _is_cjk_character(character: String) -> bool:
	if character.is_empty():
		return false
	var code := character.unicode_at(0)
	return ((code >= 0x3400 and code <= 0x9fff)
		or (code >= 0xf900 and code <= 0xfaff))


func get_selected_text() -> String:
	var selected := _selection_range()
	if selected.x < 0 or selected.y <= selected.x:
		return ""
	var result := ""
	var cursor := selected.x
	for record in _history_records:
		var message_id := int(record.get("message_id", 0))
		if not _record_ranges.has(message_id):
			continue
		var record_start := (_record_ranges[message_id] as Vector2i).x
		var body_start := record_start + int(record.get("body_selection_offset", 0))
		var revealed: Dictionary = record.get("spoiler_revealed", {})
		for span: Dictionary in record.get("spoilers", []):
			if revealed.has(int(span.id)):
				continue
			var start := maxi(selected.x, body_start + int(span.start))
			var end := mini(selected.y, body_start + int(span.end))
			if end <= start:
				continue
			result += _logical_text.substr(cursor, start - cursor) + "[剧透]"
			cursor = end
	return result + _logical_text.substr(cursor, selected.y - cursor)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED or what == NOTIFICATION_VISIBILITY_CHANGED:
		queue_redraw()
	if what == NOTIFICATION_VISIBILITY_CHANGED or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_cancel_touch()


func _gui_input(event: InputEvent) -> void:
	if touch_enabled and (event is InputEventScreenTouch or event is InputEventScreenDrag):
		_touch_input(event)
		accept_event()
		return
	if touch_enabled and event.device == -1 and (event is InputEventMouseButton or event is InputEventMouseMotion):
		accept_event()
		return
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.pressed and is_instance_valid(_scroll_bar):
			if button.button_index == MOUSE_BUTTON_WHEEL_UP:
				_scroll_bar.value -= _auto_scroll_line_height * 3.0
				accept_event()
				return
			if button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_scroll_bar.value += _auto_scroll_line_height * 3.0
				accept_event()
				return
		if button.button_index != MOUSE_BUTTON_LEFT:
			return
		if _layout_pending:
			if not button.pressed:
				cancel_drag()
			accept_event()
			return
		var global_position := get_global_mouse_position()
		if button.pressed:
			grab_focus()
			var hit := _character_at(global_position)
			_pressed_index = int(hit.get("index", -1))
			_pressed_action = {} if button.shift_pressed else _action_at(global_position)
			_pressed_url = str(_pressed_action.get("url", ""))
			_press_position = global_position
			_drag_moved = false
			if not button.shift_pressed or _anchor < 0:
				_anchor = _pressed_index
			_caret = _pressed_index
			_dragging = _pressed_index >= 0
			set_process(_dragging)
			queue_redraw()
			accept_event()
		else:
			_finish_drag(global_position, true)
			accept_event()
		return
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		var action := _action_at(get_global_mouse_position())
		mouse_default_cursor_shape = (
			Control.CURSOR_POINTING_HAND
			if not action.is_empty()
			else Control.CURSOR_IBEAM)
		if _dragging:
			_update_drag(get_global_mouse_position())
			accept_event()
		return
	if event is InputEventKey:
		var key := event as InputEventKey
		if not key.pressed or key.echo or not key.ctrl_pressed:
			return
		if key.keycode == KEY_A:
			select_all()
			accept_event()
		elif key.keycode == KEY_C:
			var selected_text := get_selected_text()
			if not selected_text.is_empty():
				DisplayServer.clipboard_set(selected_text)
			accept_event()


func _input(event: InputEvent) -> void:
	# Opening a child Window clears Control-level pointer capture. Keep owning
	# this finger until release so a held menu can hand back to text selection.
	if touch_enabled and _touch_finger >= 0 and (event is InputEventScreenDrag or (event is InputEventScreenTouch and not event.pressed)) and event.index == _touch_finger:
		_touch_input(event.xformed_by(get_global_transform_with_canvas().affine_inverse()))
		get_viewport().set_input_as_handled()
		return
	if touch_enabled and event.device == -1:
		return
	if not _dragging:
		return
	if event is InputEventMouseMotion:
		_update_drag(get_global_mouse_position())
	elif event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if not button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
			_finish_drag(get_global_mouse_position(), true)
			get_viewport().set_input_as_handled()


func _cancel_touch() -> void:
	if is_instance_valid(_touch_menu):
		_touch_menu.mouse_passthrough = false
	_touch_menu = null
	_touch_serial += 1
	_touch_finger = -1
	_touch_scroll = false
	_touch_select = false
	cancel_drag()


func hold_window(window: Window) -> void:
	if _touch_finger < 0:
		return
	_touch_menu = window
	window.mouse_passthrough = true
	var callback := _held_window_input.bind(window)
	if not window.window_input.is_connected(callback):
		window.window_input.connect(callback)


func _held_window_input(event: InputEvent, window: Window) -> void:
	if window != _touch_menu or _touch_finger < 0:
		return
	if (event is InputEventScreenTouch or event is InputEventScreenDrag) and event.index == _touch_finger:
		var transform := get_global_transform_with_canvas().affine_inverse() * get_viewport().get_screen_transform().affine_inverse() * window.get_screen_transform()
		window.set_input_as_handled()
		_touch_input(event.xformed_by(transform))


func _touch_input(event: InputEvent) -> void:
	var point: Vector2 = get_global_transform_with_canvas() * event.position
	if event is InputEventScreenTouch:
		if event.pressed:
			if _touch_finger >= 0 or _layout_pending:
				return
			_touch_finger = event.index
			_touch_start = point
			_touch_last = point
			_touch_scroll = false
			_touch_select = false
			_touch_serial += 1
			_pressed_action = _action_at(point)
			_touch_hold(_touch_serial)
		elif event.index == _touch_finger:
			var selected := _touch_select
			var reopen := selected and not is_instance_valid(_touch_menu)
			var action := _action_at(point)
			var activate: bool = not event.canceled and not selected and not _touch_scroll \
				and action == _pressed_action and not action.is_empty()
			if selected and point.distance_to(_touch_start) > touch_slop:
				_update_drag(point)
			_cancel_touch()
			if reopen and not event.canceled:
				touch_context_requested.emit(point)
			elif activate:
				if str(action.kind) == "spoiler":
					spoiler_reveal_requested.emit(int(action.message_id), int(action.segment))
				else:
					link_clicked.emit(str(action.url))
	elif event is InputEventScreenDrag and event.index == _touch_finger:
		if _touch_select:
			if is_instance_valid(_touch_menu) and point.distance_to(_touch_start) > touch_slop:
				touch_context_dragged.emit()
				_touch_menu.mouse_passthrough = false
				_touch_menu = null
			_update_drag(point)
		elif _touch_scroll or point.distance_to(_touch_start) > touch_slop:
			_touch_scroll = true
			_touch_serial += 1
			if is_instance_valid(_scroll_bar):
				_scroll_bar.value -= point.y - _touch_last.y
		_touch_last = point


func _touch_hold(serial: int) -> void:
	var anchor := capture_text_anchor(_touch_start)
	await get_tree().create_timer(0.5).timeout
	if serial != _touch_serial or _touch_finger < 0 or _layout_pending or not is_visible_in_tree():
		return
	var resolved := resolve_text_anchor(anchor)
	if str(resolved.get("state", "")) != "resolved":
		_cancel_touch()
		return
	select_word_at(resolved.position)
	_touch_select = true
	touch_context_requested.emit(_touch_start)
	_dragging = true
	_drag_moved = true
	set_process(true)


func _process(delta: float) -> void:
	if (not _dragging or not is_instance_valid(_scroll_container)
			or not is_instance_valid(_scroll_bar)):
		set_process(false)
		return
	if _layout_pending:
		return
	var viewport_rect := _scroll_container.get_global_rect()
	var pointer := _touch_last if _touch_select else get_global_mouse_position()
	var overflow := 0.0
	var direction := 0.0
	if pointer.y < viewport_rect.position.y:
		overflow = viewport_rect.position.y - pointer.y
		direction = -1.0
	elif pointer.y > viewport_rect.end.y:
		overflow = pointer.y - viewport_rect.end.y
		direction = 1.0
	if direction == 0.0:
		return
	var speed := _auto_scroll_speed_for_overflow(overflow)
	_scroll_bar.value += direction * speed * delta
	_update_drag(pointer)


func _auto_scroll_speed_for_overflow(overflow: float) -> float:
	return minf(
		_auto_scroll_line_height * 15.0,
		_auto_scroll_line_height * (
			2.0 + maxf(0.0, overflow) / _auto_scroll_line_height)
	) * _AUTO_SCROLL_SPEED_MULTIPLIER


func _update_drag(global_position: Vector2) -> void:
	if global_position.distance_to(_press_position) > UiScale.physical_value(4.0):
		_drag_moved = true
	var hit := _character_at(global_position)
	var index := int(hit.get("index", -1))
	if index >= 0 and index != _caret:
		_caret = index
		queue_redraw()


func _finish_drag(global_position: Vector2, allow_link: bool) -> void:
	if not _dragging:
		return
	var hit := _character_at(global_position)
	var release_index := int(hit.get("index", _caret))
	if release_index >= 0:
		_caret = release_index
	var action := _action_at(global_position)
	var activate := (allow_link and not _drag_moved and not action.is_empty()
		and action == _pressed_action and _anchor == _caret)
	_dragging = false
	_pressed_index = -1
	_pressed_url = ""
	_pressed_action = {}
	set_process(false)
	queue_redraw()
	if activate:
		if str(action.kind) == "spoiler":
			spoiler_reveal_requested.emit(int(action.message_id), int(action.segment))
		else:
			link_clicked.emit(str(action.url))


func _action_at(global_position: Vector2) -> Dictionary:
	if _layout_pending or not get_global_rect().has_point(global_position):
		return {}
	if is_instance_valid(_scroll_container) and not _scroll_container.get_global_rect().has_point(global_position):
		return {}
	for run in _runs:
		var control := run.get("control") as Control
		if not is_instance_valid(control) or not control.is_visible_in_tree():
			continue
		var local := control.get_global_transform_with_canvas().affine_inverse() * global_position
		if not Rect2(Vector2.ZERO, control.size).has_point(local):
			continue
		if control.has_method("spoiler_at"):
			var segment := int(control.call("spoiler_at", local))
			if segment >= 0:
				var regions: Array = control.call("spoiler_regions")
				for index in regions.size():
					if (regions[index].rect as Rect2).has_point(local):
						return {"kind": "spoiler", "message_id": int(run.message_id),
							"segment": segment, "control": control.get_instance_id(), "fragment": index}
		var url := str(run.get("url", ""))
		var body := str(run.text)
		var width := _text_width(_control_font(control), _control_font_size(control), body)
		var origin := _run_text_origin_x(control, body)
		if not url.is_empty() and local.x >= origin and local.x < origin + width:
			return {"kind": "link", "url": url, "control": control.get_instance_id()}
	return {}


func _draw() -> void:
	if _layout_pending:
		return
	var selected := _selection_range()
	if selected.x < 0 or selected.y <= selected.x:
		return
	var inverse := get_global_transform_with_canvas().affine_inverse()
	for run in _runs:
		var control := run.get("control") as Control
		if not is_instance_valid(control) or not control.is_visible_in_tree():
			continue
		var run_start := int(run.get("start", 0))
		var text := str(run.get("text", ""))
		var overlap_start := maxi(selected.x, run_start)
		var overlap_end := mini(selected.y, run_start + text.length())
		if overlap_end <= overlap_start:
			continue
		var font := _control_font(control)
		var font_size := _control_font_size(control)
		if font == null or font_size <= 0:
			continue
		var local_start := overlap_start - run_start
		var local_end := overlap_end - run_start
		var origin_x := _run_text_origin_x(control, text)
		var x1 := origin_x + _text_width(font, font_size, text.substr(0, local_start))
		var x2 := origin_x + _text_width(font, font_size, text.substr(0, local_end))
		var control_transform := control.get_global_transform_with_canvas()
		var top_left := inverse * (control_transform * Vector2(x1, 0.0))
		var bottom_right := inverse * (
			control_transform * Vector2(x2, control.size.y))
		var line := _baseline_line(control)
		if line != null:
			var line_transform := line.get_global_transform_with_canvas()
			top_left.y = (inverse * (line_transform * Vector2.ZERO)).y
			bottom_right.y = (inverse * (line_transform * Vector2(0.0, line.size.y))).y
		draw_rect(Rect2(top_left, bottom_right - top_left), _SELECTION_COLOR)


func _selection_range() -> Vector2i:
	if _anchor < 0 or _caret < 0:
		return Vector2i(-1, -1)
	return Vector2i(mini(_anchor, _caret), maxi(_anchor, _caret))


func _rebuild_runs() -> void:
	_runs.clear()
	if not is_instance_valid(_source_root):
		return
	for message in _source_root.get_children():
		var message_id := int(message.get_meta("chat_message_id", 0))
		if not _record_ranges.has(message_id):
			continue
		var record_range: Vector2i = _record_ranges[message_id]
		var message_offset := 0
		var controls: Array[Control] = []
		_collect_selectable_controls(message, controls)
		if controls.is_empty():
			continue
		for control in controls:
			if control.has_meta("chat_select_record_offset"):
				message_offset = int(control.get_meta("chat_select_record_offset"))
			elif bool(control.get_meta(_HARD_BREAK_META, false)):
				message_offset += 1
			var text := str(control.get_meta(_SELECT_TEXT_META, ""))
			if text.is_empty():
				continue
			_runs.append({
				"control": control,
				"message_id": message_id,
				"text": text,
				"start": record_range.x + message_offset,
				"url": str(control.get_meta(_LINK_META, "")),
			})
			message_offset += text.length()


func _collect_selectable_controls(node: Node, result: Array[Control]) -> void:
	if node is Control and node.has_meta(_SELECT_TEXT_META):
		result.append(node as Control)
		return
	for child in node.get_children():
		_collect_selectable_controls(child, result)


func _character_at(global_position: Vector2) -> Dictionary:
	if _layout_pending:
		return {"index": -1, "url": ""}
	if _runs.is_empty() and not _logical_text.is_empty():
		_rebuild_runs()
	var best_run: Dictionary = {}
	var best_distance := INF
	for run in _runs:
		var control := run.get("control") as Control
		if not is_instance_valid(control) or not control.is_visible_in_tree():
			continue
		var rect := control.get_global_rect()
		var origin_x := _run_text_origin_x(control, str(run.get("text", "")))
		if origin_x > 0.0:
			var transform := control.get_global_transform_with_canvas()
			var start := transform * Vector2(origin_x, 0.0)
			rect = Rect2(start, transform * control.size - start).abs()
		var line := _baseline_line(control)
		if line != null:
			var line_rect := line.get_global_rect()
			rect.position.y = line_rect.position.y
			rect.size.y = line_rect.size.y
		if rect.has_point(global_position):
			return _hit_run(run, global_position)
		var nearest := Vector2(
			clampf(global_position.x, rect.position.x, rect.end.x),
			clampf(global_position.y, rect.position.y, rect.end.y))
		var distance := nearest.distance_squared_to(global_position)
		if distance < best_distance:
			best_distance = distance
			best_run = run
	if best_run.is_empty():
		return {"index": -1, "url": ""}
	return _hit_run(best_run, global_position)


func _baseline_line(control: Control) -> Control:
	var parent := control.get_parent() as Control
	return parent if parent != null and parent.has_meta("chat_baseline_row") else null


func _hit_run(run: Dictionary, global_position: Vector2) -> Dictionary:
	var control := run.get("control") as Control
	var text := str(run.get("text", ""))
	if not is_instance_valid(control):
		return {"index": -1, "url": ""}
	var local_position := (
		control.get_global_transform_with_canvas().affine_inverse() * global_position)
	var character := _character_index_for_x(
		text, _control_font(control), _control_font_size(control),
		local_position.x - _run_text_origin_x(control, text))
	return {
		"index": int(run.get("start", 0)) + character,
		"url": str(run.get("url", "")),
		"affinity": "backward" if character >= text.length() else "forward",
		"line_y_ratio": clampf(
			local_position.y / maxf(1.0, control.size.y), 0.0, 1.0),
	}


func _global_position_for_logical_index(
		logical_index: int, affinity: String, line_y_ratio: float) -> Variant:
	var fallback: Dictionary = {}
	for run in _runs:
		var text := str(run.get("text", ""))
		var run_start := int(run.get("start", 0))
		var run_end := run_start + text.length()
		if logical_index < run_start or logical_index > run_end:
			continue
		if fallback.is_empty():
			fallback = run
		if logical_index > run_start and logical_index < run_end:
			return _global_position_in_run(
				run, logical_index, line_y_ratio)
		if affinity == "backward" and logical_index == run_end:
			return _global_position_in_run(
				run, logical_index, line_y_ratio)
		if affinity != "backward" and logical_index == run_start:
			return _global_position_in_run(
				run, logical_index, line_y_ratio)
	if fallback.is_empty():
		return null
	return _global_position_in_run(fallback, logical_index, line_y_ratio)


func _global_position_in_run(
		run: Dictionary, logical_index: int, line_y_ratio: float) -> Variant:
	var control := run.get("control") as Control
	if not is_instance_valid(control) or not control.is_visible_in_tree():
		return null
	var text := str(run.get("text", ""))
	var run_start := int(run.get("start", 0))
	var local_index := clampi(logical_index - run_start, 0, text.length())
	var x := _run_text_origin_x(control, text) + _text_width(
		_control_font(control),
		_control_font_size(control),
		text.substr(0, local_index))
	var local_position := Vector2(
		x, control.size.y * clampf(line_y_ratio, 0.0, 1.0))
	return control.get_global_transform_with_canvas() * local_position


func _run_text_origin_x(control: Control, text: String) -> float:
	if not control is Label:
		return 0.0
	var free_width := maxf(0.0, control.size.x - _text_width(
		_control_font(control), _control_font_size(control), text))
	match (control as Label).horizontal_alignment:
		HORIZONTAL_ALIGNMENT_RIGHT:
			return free_width
		HORIZONTAL_ALIGNMENT_CENTER:
			return free_width * 0.5
	return 0.0


func _character_index_for_x(text: String, font: Font, font_size: int, x: float) -> int:
	if font == null or text.is_empty() or x <= 0.0:
		return 0
	var previous_width := 0.0
	for index in text.length():
		var next_width := _text_width(font, font_size, text.substr(0, index + 1))
		if x < (previous_width + next_width) * 0.5:
			return index
		previous_width = next_width
	return text.length()


func _control_font(control: Control) -> Font:
	if control is RichTextLabel:
		return control.get_theme_font("normal_font")
	return control.get_theme_font("font")


func _control_font_size(control: Control) -> int:
	if control is RichTextLabel:
		return control.get_theme_font_size("normal_font_size")
	return control.get_theme_font_size("font_size")


func _text_width(font: Font, font_size: int, text: String) -> float:
	if text.is_empty():
		return 0.0
	return font.get_string_size(
		text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x
