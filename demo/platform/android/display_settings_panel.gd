extends Control

signal closed()
const Metrics := preload("res://platform/android/launcher_presentation.gd")
const Settings := preload("res://platform/android/display_settings.gd")
const UiTheme := preload("res://platform/android/ui_theme.gd")
const ThemedDialog := preload("res://platform/android/themed_dialog.gd")
const Footer := preload("res://cogs/dialog_footer.gd")

var settings: Node
var panel: PanelContainer
var orientation: OptionButton
var scale_slider: HSlider
var left_slider: HSlider
var right_slider: HSlider
var _scale_label: RichTextLabel
var _left_label: RichTextLabel
var _right_label: RichTextLabel
var _direction: Label
var _error: Label
var _scroll: ScrollContainer
var _content: VBoxContainer
var _updating := false
var _last_rotation := -1
var _last_size := Vector2.ZERO
var _scale_dragging := false
var _pending_scale := 100.0
var _scale_touch_index := -1
var _suspended := false
var _reset_confirm: ThemedDialog
var _gesture: Node
var _actions: BoxContainer
var _footer_wrap: MarginContainer
var _heading: Label
var _title_wrap: MarginContainer
var _box: VBoxContainer
var _restore: Button


func _ready() -> void:
	Metrics.take_ownership(self)
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = UiTheme.theme(settings.in_game)
	panel = PanelContainer.new()
	add_child(panel)
	panel.minimum_size_changed.connect(_refresh, CONNECT_DEFERRED)
	var box := VBoxContainer.new()
	_box = box
	panel.add_child(box)
	var title := Label.new()
	_heading = title
	title.text = "UI与屏幕边距设置"
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_wrap = MarginContainer.new()
	box.add_child(_title_wrap)
	_title_wrap.add_child(title)
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.scroll_deadzone = Metrics.dp(12)
	box.add_child(_scroll)
	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_content)
	_restore = Button.new()
	_restore.text = "恢复默认"
	_restore.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_restore.pressed.connect(_defaults)
	_content.add_child(_restore)
	_section_gap()
	_scale_label = _value_label()
	scale_slider = _slider(60, 150, 5)
	scale_slider.drag_started.connect(_scale_drag_started)
	scale_slider.drag_ended.connect(_scale_drag_ended)
	scale_slider.value_changed.connect(_scale_value_changed)
	_section_gap()
	var orientation_title := _label()
	orientation_title.text = "画面方向"
	orientation = OptionButton.new()
	for label: String in Settings.ORIENTATION_NAMES:
		orientation.add_item(label)
	orientation.item_selected.connect(func(index: int):
		_cancel_gestures()
		settings.set_orientation(index))
	_content.add_child(orientation)
	_section_gap()
	_direction = _label()
	_left_label = _value_label()
	left_slider = _slider(0, 20, 0.1)
	left_slider.value_changed.connect(func(value: float):
		if not _updating and _accepts_edit(): settings.set_margin(settings.margin_sides()[0], value / 100.0))
	_right_label = _value_label()
	right_slider = _slider(0, 20, 0.1)
	right_slider.value_changed.connect(func(value: float):
		if not _updating and _accepts_edit(): settings.set_margin(settings.margin_sides()[1], value / 100.0))
	_gesture = preload("res://platform/android/touch_scroll.gd").new()
	_gesture.scroll = _scroll
	_gesture.slop = Metrics.dp(12)
	_gesture.passthrough_controls.assign([scale_slider, left_slider, right_slider])
	_scroll.add_child(_gesture)
	_error = Label.new()
	_error.set_meta(&"android_plain_text", true)
	_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_error)
	_actions = BoxContainer.new()
	box.add_child(_actions)
	for item: Array in [["取消", cancel], ["保存", save]]:
		var button := Button.new()
		button.text = item[0]
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(item[1])
		_actions.add_child(button)
	_footer_wrap = Footer.wrap_row(_actions)
	_reset_confirm = ThemedDialog.new()
	_reset_confirm.title = "恢复默认？"
	add_child(_reset_confirm)
	_reset_confirm.confirmed.connect(func():
		settings.restore_defaults()
		_refresh())
	_reset_confirm.canceled.connect(_refresh)
	resized.connect(_refresh)
	settings.geometry_changed.connect(_refresh)
	settings.preferences_changed.connect(_refresh)
	hide()


func _label() -> Label:
	var label := Label.new()
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_content.add_child(label)
	return label


func _value_label() -> RichTextLabel:
	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.add_child(label)
	return label


func _section_gap() -> void:
	var gap := Control.new()
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gap.set_meta(&"android_section_gap", true)
	_content.add_child(gap)


func _slider(minimum: float, maximum: float, step_size: float) -> HSlider:
	var slider := HSlider.new()
	slider.scrollable = false
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = step_size
	slider.custom_minimum_size.y = Metrics.dp(48)
	_content.add_child(slider)
	return slider


func open() -> void:
	settings.begin_edit()
	_cancel_gestures()
	_error.text = ""
	show()
	_refresh()


func cancel() -> void:
	_reset_confirm.dismiss()
	_cancel_gestures()
	orientation.get_popup().hide()
	settings.cancel_edit()
	hide()
	closed.emit()


func save() -> void:
	if _reset_confirm.is_open_or_opening(): return
	_finish_scale_drag()
	if settings.save_edit() != OK:
		_error.text = "设置保存失败，请重试或取消。"
		_refresh()
		return
	_reset_confirm.dismiss()
	_cancel_gestures()
	hide()
	closed.emit()


func handle_back() -> void:
	if _reset_confirm.is_open_or_opening():
		_reset_confirm.cancel()
	elif orientation.get_popup().visible:
		orientation.get_popup().hide()
	else:
		cancel()


func _defaults() -> void:
	if _reset_confirm.is_open_or_opening(): return
	orientation.get_popup().hide()
	_reset_confirm.open()
	_cancel_gestures()


func _accepts_edit() -> bool:
	return is_visible_in_tree() and not _suspended and not (is_instance_valid(_reset_confirm) and _reset_confirm.is_open_or_opening())


func _cancel_gestures() -> void:
	_cancel_scale_drag()
	if is_instance_valid(_gesture):
		_gesture.cancel()
	for slider: HSlider in [left_slider, right_slider]:
		if is_instance_valid(slider):
			slider.editable = false
			slider.editable = _accepts_edit()


func _scale_drag_started() -> void:
	if not _accepts_edit() or not settings.in_game:
		return
	_scale_dragging = true
	_pending_scale = scale_slider.value


func _scale_value_changed(value: float) -> void:
	if _updating or not _accepts_edit() or not settings.in_game:
		return
	_pending_scale = value
	_scale_label.text = "UI大小比例：[color=white]%d%%[/color]" % value
	if not _scale_dragging:
		# Keyboard and accessibility changes have no drag_ended signal.
		_apply_scale(value)


func _apply_scale(value: float) -> void:
	if not is_equal_approx(float(settings.preferences.ui_scale), value / 100.0):
		settings.set_ui_scale(value / 100.0)


func _scale_drag_ended(_changed: bool) -> void:
	_finish_scale_drag()


func _finish_scale_drag() -> void:
	if not _scale_dragging:
		return
	var value := _pending_scale
	_cancel_scale_drag()
	if _accepts_edit() and settings.in_game:
		_apply_scale(value)


func _cancel_scale_drag() -> void:
	_scale_dragging = false
	_scale_touch_index = -1
	if not is_instance_valid(scale_slider):
		return
	# Cancel Slider's internal mouse grab as well as our pending preview.
	# A late emulated mouse release must not commit an interrupted gesture.
	scale_slider.editable = false
	if not is_instance_valid(settings):
		return
	_pending_scale = float(settings.preferences.ui_scale) * 100.0
	scale_slider.set_value_no_signal(_pending_scale)
	_scale_label.text = "UI大小比例：[color=white]%d%%[/color]" % _pending_scale
	scale_slider.editable = settings.in_game and _accepts_edit()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_suspended = true
		_cancel_gestures()
	elif what == NOTIFICATION_APPLICATION_RESUMED or what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_suspended = false
		_refresh()
	elif what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree():
		_cancel_gestures()
	elif what == NOTIFICATION_EXIT_TREE:
		_cancel_gestures()
		if is_instance_valid(_reset_confirm): _reset_confirm.dismiss()


func _refresh() -> void:
	if not is_node_ready() or not visible:
		return
	if _last_rotation != settings.actual_rotation or _last_size != size:
		_cancel_gestures()
		_last_rotation = settings.actual_rotation
		_last_size = size
	_updating = true
	orientation.select(int(settings.preferences.orientation))
	if not _scale_dragging:
		_pending_scale = float(settings.preferences.ui_scale) * 100.0
		scale_slider.set_value_no_signal(_pending_scale)
	scale_slider.editable = settings.in_game and _accepts_edit()
	left_slider.editable = _accepts_edit()
	right_slider.editable = _accepts_edit()
	_scale_label.text = "UI大小比例：[color=white]%d%%[/color]" % scale_slider.value
	var sides: PackedStringArray = settings.margin_sides()
	var portrait := sides[0] == "top"
	_direction.text = "UI上下屏幕边距" if portrait else "UI左右屏幕边距"
	left_slider.value = settings.margin_fraction(sides[0]) * 100
	right_slider.value = settings.margin_fraction(sides[1]) * 100
	_left_label.text = ("上边距：" if portrait else "左边距：") + "[color=white]%.1f%%[/color]" % left_slider.value
	_right_label.text = ("下边距：" if portrait else "右边距：") + "[color=white]%.1f%%[/color]" % right_slider.value
	_updating = false
	# Calibration moves the cyan boundary, not the controls used to edit it.
	theme = UiTheme.theme(settings.in_game)
	UiTheme.apply_tree(panel, settings.in_game)
	_reset_confirm.in_game = settings.in_game
	var frame := UiTheme.titled_frame(_heading)
	frame.set_content_margin(SIDE_BOTTOM, UiTheme.px(8))
	panel.add_theme_stylebox_override("panel", frame)
	UiTheme.title_gap(_heading, _box, _title_wrap)
	_error.visible = not _error.text.is_empty()
	var safe: Rect2 = settings.view_rect.grow(-Metrics.dp(8))
	var width := minf(safe.size.x, minf(safe.size.x, Metrics.dp(480)) * 0.5 + UiTheme.px(24))
	Footer.apply_buttons(_actions, UiTheme.px(4), theme)
	Footer.set_gap(_footer_wrap, UiTheme.px(12))
	# Two minimum-size actions may need a few pixels beyond the old compact
	# form width. Grow only enough to keep this footer horizontal when it fits.
	width = minf(safe.size.x, maxf(width, UiTheme.actions_width(_actions) + UiTheme.px(32)))
	UiTheme.fit_actions(_actions, width - UiTheme.px(32))
	# Keep room for the scrollable form when narrow screens stack the actions.
	var fixed_height := panel.get_combined_minimum_size().y
	panel.size = Vector2(width, minf(safe.size.y, maxf(minf(safe.size.y, Metrics.dp(620)) * 2.0 / 3.0 + UiTheme.px(24), fixed_height + UiTheme.px(48))))
	panel.position = safe.position + (safe.size - panel.size) * 0.5
	UiTheme.scrollbar(_scroll, true, UiTheme.px(4))
	queue_redraw()


func _draw() -> void:
	var safe := UiScale.safe_rect_for(get_viewport())
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.35))
	draw_rect(safe.grow(-2), Color.CYAN, false, Metrics.dp(2))


func _input(event: InputEvent) -> void:
	if not _accepts_edit():
		return
	# Godot can dispatch this emulated mouse release before the canceled touch.
	# Cancel before Slider's GUI handler emits drag_ended for that release.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.canceled:
		_cancel_scale_drag()
	if event is InputEventScreenTouch:
		if event.canceled and event.index == _scale_touch_index:
			_cancel_scale_drag()
		elif event.pressed and _scale_touch_index < 0 and scale_slider.get_global_rect().has_point(event.position):
			_scale_touch_index = event.index
		elif not event.pressed and event.index == _scale_touch_index:
			_scale_touch_index = -1
