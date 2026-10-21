extends Node

# One gesture owner per scrolling surface. Descendant labels/links must not
# consume the beginning of a drag. Real mouse input keeps the existing route.
var scroll: ScrollContainer
var slop := 12.0
var held: Callable
var item_tooltip: Callable
var control_tooltip: Callable
var completed_tap: Callable
var window_events := false
# Settings sliders keep their own horizontal drag, while labels and empty
# parts of the same form still use this vertical scrolling gesture.
var passthrough_controls: Array[Control] = []
var _passthrough_finger := -1
var _finger := -1
var _start := Vector2.ZERO
var _last := Vector2.ZERO
var _dragged := false
var _opened := false
var _tooltip_shown := false
var _target: Control
var _closing_option := false
var _serial := 0
var _held_window: Window
var _popup_guard := false
var _popup_hide_item := true
var _popup_hide_check := true
var _popup_signals_blocked := false


func _ready() -> void:
	set_process(false)
	scroll.visibility_changed.connect(cancel)
	scroll.tree_exiting.connect(cancel)


func _exit_tree() -> void:
	if window_events:
		# The child leaves before its ScrollContainer. Restore while the popup
		# and tree are still available, then retire the later parent callbacks.
		scroll.visibility_changed.disconnect(cancel)
		scroll.tree_exiting.disconnect(cancel)
		cancel()


func _process(_delta: float) -> void:
	# PopupMenu's selection guard also blocks its hide signals. Watch only an
	# active popup touch, including the press before a drag or hold starts.
	if not (get_viewport() as PopupMenu).visible:
		cancel()
	elif _finger < 0 and not _popup_guard:
		set_process(false)


func cancel() -> void:
	_serial += 1
	_passthrough_finger = -1
	_finger = -1
	_target = null
	_closing_option = false
	if is_instance_valid(_held_window):
		_held_window.mouse_passthrough = false
	_held_window = null
	_restore_popup()
	if window_events:
		set_process(false)
		var tooltip := get_tree().get_first_node_in_group("webpage_theme_tooltip_runtime")
		if tooltip != null and tooltip.get("_target") == scroll:
			tooltip.call("_cancel_tooltip")


func hold_window(window: Window) -> void:
	_held_window = window
	window.mouse_passthrough = true
	var callback := _held_window_input.bind(window)
	if not window.window_input.is_connected(callback):
		window.window_input.connect(callback)


func _held_window_input(event: InputEvent, window: Window) -> void:
	if window != _held_window or _finger < 0:
		return
	if (event is InputEventScreenTouch or event is InputEventScreenDrag) and event.index == _finger:
		window.set_input_as_handled()
		_input(event.xformed_by(get_viewport().get_screen_transform().affine_inverse() * window.get_screen_transform()))


func _input(event: InputEvent) -> void:
	if not scroll.is_visible_in_tree():
		return
	if event is InputEventScreenTouch:
		if event.pressed and _passthrough_hit(event.position):
			_passthrough_finger = event.index
			return
		if event.index == _passthrough_finger:
			# The emulated mouse release follows this touch in the same dispatch.
			_clear_passthrough.call_deferred(event.index)
			return
	elif event is InputEventScreenDrag and event.index == _passthrough_finger:
		return
	elif event is InputEventMouse and event.device == -1 \
			and (_passthrough_finger >= 0 or _passthrough_hit(event.position)):
		return
	if event is InputEventMouse and event.device == -1:
		var bar := scroll.get_v_scroll_bar()
		if scroll.get_global_rect().has_point(event.position) and not (bar.mouse_filter != Control.MOUSE_FILTER_IGNORE and bar.is_visible_in_tree() and bar.get_global_rect().has_point(event.position)):
			get_viewport().set_input_as_handled()
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			if _finger >= 0 or not scroll.get_global_rect().has_point(event.position):
				return
			var bar := scroll.get_v_scroll_bar()
			if bar.mouse_filter != Control.MOUSE_FILTER_IGNORE and bar.is_visible_in_tree() and bar.get_global_rect().has_point(event.position):
				return
			_finger = event.index
			if window_events:
				set_process(true)
			_start = event.position
			_last = _start
			_dragged = false
			_opened = false
			_tooltip_shown = false
			_target = _hit(scroll, _start)
			_closing_option = _target is OptionButton and _target.get_popup().visible
			_serial += 1
			_hold(_serial)
		elif event.index == _finger:
			var tap: bool = not event.canceled and not _dragged and not _opened and not _tooltip_shown and not _closing_option
			var target := _target
			if window_events:
				_finger = -1
				_serial += 1
				_restore_popup.call_deferred()
			else:
				cancel()
			if tap and is_instance_valid(target) and not window_events:
				# Replay only a completed tap, never a press preceding a drag.
				# Keep Input's button mask in sync as well: native PopupMenu uses
				# it to ignore the opening release, including menus above the key.
				var point: Vector2 = get_tree().root.get_screen_transform().affine_inverse() * get_viewport().get_screen_transform() * event.position
				for down in [true, false]:
					var mouse := InputEventMouseButton.new()
					mouse.device = -2
					mouse.button_index = MOUSE_BUTTON_LEFT
					mouse.pressed = down
					mouse.position = point
					mouse.global_position = point
					Input.parse_input_event(mouse)
				# Internal replay skips script gui_input. Consumers that need a
				# script-only tap action opt in after the mouse press/release pair.
				if completed_tap.is_valid():
					completed_tap.call(target, event.position)
		else:
			return
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag and event.index == _finger:
		if not _opened and (_dragged or event.position.distance_to(_start) > slop):
			_dragged = true
			_guard_popup()
			_serial += 1
			scroll.get_v_scroll_bar().value -= event.position.y - _last.y
		_last = event.position
		get_viewport().set_input_as_handled()


func _passthrough_hit(point: Vector2) -> bool:
	if not scroll.get_global_rect().has_point(point):
		return false
	for control: Control in passthrough_controls:
		if is_instance_valid(control) and control.is_visible_in_tree() and control.get_global_rect().has_point(point):
			return true
	return false


func _clear_passthrough(finger: int) -> void:
	if _passthrough_finger == finger:
		_passthrough_finger = -1


func _hold(serial: int) -> void:
	await get_tree().create_timer(0.5).timeout
	if serial != _serial or not is_instance_valid(_target) or not _target.is_visible_in_tree():
		return
	if not bool(_target.get_meta("android_context_hold", false)):
		if control_tooltip.is_valid():
			_tooltip_shown = bool(control_tooltip.call(_target, _start, _finger))
		elif item_tooltip.is_valid():
			_tooltip_shown = bool(item_tooltip.call(_start, _finger))
		if _tooltip_shown:
			# A tooltip suppresses the release tap, but unlike a context menu
			# it must still let a subsequent movement start scrolling.
			_guard_popup()
		return
	_opened = true
	# Shared context menus open on release. Keep this replay local, at the
	# long-press threshold; the real finger release must not activate an item.
	for down in [true, false]:
		if not is_instance_valid(_target):
			break
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_RIGHT
		click.pressed = down
		click.position = _target.get_global_transform_with_canvas().affine_inverse() * _start
		click.global_position = _start
		_target.gui_input.emit(click)
	if held.is_valid():
		held.call(self)


func _guard_popup() -> void:
	if not window_events or _popup_guard:
		return
	var popup := get_viewport() as PopupMenu
	_popup_guard = true
	_popup_hide_item = popup.hide_on_item_selection
	_popup_hide_check = popup.hide_on_checkable_item_selection
	_popup_signals_blocked = popup.is_blocking_signals()
	# PopupMenu handles emulated mouse release before scene _input. Keep its
	# native short-click/keyboard path, but suppress activation during a drag.
	popup.hide_on_item_selection = false
	popup.hide_on_checkable_item_selection = false
	popup.set_block_signals(true)


func _restore_popup() -> void:
	if not _popup_guard:
		return
	_popup_guard = false
	var popup := get_viewport() as PopupMenu
	popup.hide_on_item_selection = _popup_hide_item
	popup.hide_on_checkable_item_selection = _popup_hide_check
	popup.set_block_signals(_popup_signals_blocked)


func _hit(node: Control, point: Vector2) -> Control:
	var children := node.get_children()
	children.reverse()
	for child in children:
		if child is Control and child.is_visible_in_tree() and child.get_global_rect().has_point(point):
			var target := _hit(child, point)
			if target != null:
				return target
	return node if node.mouse_filter != Control.MOUSE_FILTER_IGNORE else null


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		cancel()
