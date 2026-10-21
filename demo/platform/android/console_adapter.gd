extends Node

signal modal_changed()

const Metrics := preload("res://platform/android/launcher_presentation.gd")
const TextSession := preload("res://platform/android/native_text_session.gd")
var fields: Node
var engine: Node
var can_open: Callable
var before_open: Callable
var shown := false
var _entry: TextEdit
var _panel: Control
var _blocker: Control
var _bounds := Rect2()
var _old_offset := Vector2.ZERO
var _old_anchors := Vector4.ZERO
var _old_offsets := Vector4.ZERO
var _layout_queued := false
var _previous_toggle_input := true
var _output_finger := -1
var _output_last := Vector2.ZERO
var _output_start := Vector2.ZERO
var _output_dragged := false
var _history_view: Control
var _old_theme: Theme
var _old_entry_minimum := Vector2.ZERO
var _old_history_bar_width := 12


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Keep the plugin's private node boundary in this one Android adapter.
	_entry = LimboConsole.get("_entry")
	_panel = LimboConsole.get("_control")
	_blocker = LimboConsole.get("_control_block")
	_history_view = LimboConsole.get("_history_gui")
	_old_theme = _panel.theme
	_old_entry_minimum = _entry.custom_minimum_size
	_old_history_bar_width = int(_history_view.get("_scroll_bar_width"))
	var mobile_theme := _old_theme.duplicate() as Theme
	mobile_theme.default_font_size = Metrics.sp(16)
	_panel.theme = mobile_theme
	_entry.custom_minimum_size.y = Metrics.dp(48)
	_entry.set("_font_size", _entry.get_theme_font_size("font_size"))
	_history_view.visibility_changed.connect(queue_layout)
	_old_offset = LimboConsole.offset
	_old_anchors = Vector4(_panel.anchor_left, _panel.anchor_top, _panel.anchor_right, _panel.anchor_bottom)
	_old_offsets = Vector4(_panel.offset_left, _panel.offset_top, _panel.offset_right, _panel.offset_bottom)
	_previous_toggle_input = LimboConsole.is_processing_input()
	# One route for the hardware toggle as well as the menu and virtual button.
	LimboConsole.set_process_input(false)
	fields.register_field(_entry, TextSession.Mode.CONSOLE, "", _field_available, Callable(), _submit)
	LimboConsole.toggled.connect(_toggled)
	UiScale.safe_area_changed.connect(queue_layout)
	get_tree().root.size_changed.connect(queue_layout)
	if engine.has_signal("resolution_changed"):
		engine.connect("resolution_changed", _resolution_changed)
	shown = LimboConsole.is_open()
	if shown: _toggled(true)


func _exit_tree() -> void:
	fields.cancel_field(_entry)
	if LimboConsole.toggled.is_connected(_toggled): LimboConsole.toggled.disconnect(_toggled)
	LimboConsole.close_console()
	# A scene may be freed during a close animation. Settle the plugin's own
	# pause/focus contract before handing it back to the next scene.
	LimboConsole.call("_hide_console")
	LimboConsole.set_process(false)
	LimboConsole.set("_open_t", 0.0)
	LimboConsole.offset = _old_offset
	_panel.anchor_left = _old_anchors.x
	_panel.anchor_top = _old_anchors.y
	_panel.anchor_right = _old_anchors.z
	_panel.anchor_bottom = _old_anchors.w
	_panel.offset_left = _old_offsets.x
	_panel.offset_top = _old_offsets.y
	_panel.offset_right = _old_offsets.z
	_panel.offset_bottom = _old_offsets.w
	_panel.theme = _old_theme
	_entry.custom_minimum_size = _old_entry_minimum
	_entry.set("_font_size", _entry.get_theme_font_size("font_size"))
	_history_view.set("_scroll_bar_width", _old_history_bar_width)
	for label: Label in _history_view.get("_history_labels"):
		label.show()
		label.size.y = label.get_minimum_size().y
	_history_view.set("_display_count", 0)
	_blocker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	LimboConsole.set_process_input(_previous_toggle_input)


func _process(_delta: float) -> void:
	if not shown: return
	if not engine.is_running():
		close()
	elif not _bounds.is_equal_approx(_display_bounds()):
		queue_layout()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("limbo_console_toggle"):
		if event is InputEventKey and event.echo: return
		if fields.is_modal_open(): return
		if shown or (can_open.is_valid() and can_open.call()):
			toggle()
			get_viewport().set_input_as_handled()
		return
	if not shown or fields.is_modal_open(): return
	if event is InputEventKey:
		# Preserve the plugin's keyboard history, completion and close shortcuts.
		LimboConsole.call("_input", event)
	elif event is InputEventScreenTouch:
		var output: Control = LimboConsole.get("_output")
		if event.pressed and output.get_global_rect().has_point(event.position - LimboConsole.offset):
			if _output_finger >= 0: return
			_output_finger = event.index
			_output_last = event.position
			_output_start = event.position
			_output_dragged = false
		elif event.index == _output_finger:
			if _history_view.visible and not event.canceled and not _output_dragged:
				_select_history(event.position - LimboConsole.offset)
			_output_finger = -1
		else: return
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag and event.index == _output_finger:
		_output_dragged = _output_dragged or event.position.distance_to(_output_start) > Metrics.dp(12)
		if _output_dragged:
			if _history_view.visible:
				var bar: VScrollBar = _history_view.get("_scroll_bar")
				bar.value -= (event.position.y - _output_last.y) / Metrics.dp(48)
				bar.scrolling.emit()
			else:
				var output: RichTextLabel = LimboConsole.get("_output")
				output.get_v_scroll_bar().value -= event.position.y - _output_last.y
		_output_last = event.position
		get_viewport().set_input_as_handled()


func toggle() -> void:
	if shown:
		close()
	elif can_open.is_valid() and can_open.call():
		before_open.call()
		_layout()
		LimboConsole.open_console()


func close() -> void:
	fields.cancel_field(_entry)
	_output_finger = -1
	if LimboConsole.is_open(): LimboConsole.close_console()


func handle_back() -> bool:
	if not shown: return false
	var history_gui: Control = LimboConsole.get("_history_gui")
	if history_gui.visible:
		history_gui.hide()
	else:
		close()
	return true


func _toggled(value: bool) -> void:
	shown = value
	_output_finger = -1
	if value:
		engine.set_game_input_blocked(true)
		queue_layout()
	else:
		fields.cancel_field(_entry)
	modal_changed.emit()


func _field_available() -> bool:
	return shown and LimboConsole.is_open() and engine.is_running()


func _submit() -> void:
	if _field_available() and not fields.is_modal_open():
		_entry.call("submit_text")


func _select_history(point: Vector2) -> void:
	if not _history_view.get_global_rect().has_point(point): return
	var labels: Array = _history_view.get("_history_labels")
	for index in range(int(_history_view.get("_display_count"))):
		if labels[index].get_global_rect().has_point(point) and not labels[index].text.is_empty():
			# A history tap only fills the draft; native Done submits the edited command.
			_entry.text = labels[index].text
			_entry.set_caret_column(_entry.text.length())
			_history_view.hide()
			_entry.text_changed.emit()
			return


func _layout_history() -> void:
	if not _history_view.visible: return
	var labels: Array = _history_view.get("_history_labels")
	labels[0].size.y = Metrics.dp(48)
	_history_view.set("_display_count", 0)
	_history_view.set("_scroll_bar_width", Metrics.dp(24))
	_history_view.call("_calculate_display_count")
	var count := int(_history_view.get("_display_count"))
	for index in range(labels.size()):
		labels[index].visible = index < count
		labels[index].position = Vector2(0, _history_view.size.y - (index + 1) * Metrics.dp(48))
		labels[index].size = Vector2(maxf(1, _history_view.size.x - Metrics.dp(24)), Metrics.dp(48))


func _display_bounds() -> Rect2:
	var safe := UiScale.safe_rect_for(get_viewport())
	var output := engine.get("game_output") as Control
	if is_instance_valid(output):
		var canvas := output.get_global_rect().intersection(safe)
		if canvas.has_area(): return canvas
	return safe


func _resolution_changed(_width: int, _height: int) -> void:
	queue_layout()


func queue_layout() -> void:
	if _layout_queued: return
	_layout_queued = true
	_layout.call_deferred()


func _layout() -> void:
	_layout_queued = false
	if not is_instance_valid(_panel): return
	_bounds = _display_bounds()
	var safe := UiScale.safe_rect_for(get_viewport())
	var minimum := _panel.get_combined_minimum_size()
	var height := minf(maxf(_bounds.size.y * 0.5, minimum.y), safe.end.y - _bounds.position.y)
	LimboConsole.offset = Vector2(0, _bounds.position.y)
	_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_panel.position.x = _bounds.position.x
	_panel.size = Vector2(_bounds.size.x, height)
	# The existing animation still moves from -height to zero in this layer.
	var progress := float(LimboConsole.get("_open_t"))
	_panel.position.y = lerpf(-height, 0.0, ease(progress, -1.75))
	_blocker.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_blocker.position = -LimboConsole.offset
	_blocker.size = get_viewport().get_visible_rect().size
	_layout_history.call_deferred()
