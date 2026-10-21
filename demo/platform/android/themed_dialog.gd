extends Window
## Compact Android confirmation/message window with a cancellable layout phase.
signal confirmed()
signal canceled()
const UiTheme := preload("res://platform/android/ui_theme.gd")
const Footer := preload("res://cogs/dialog_footer.gd")
var dialog_text := ""
var with_cancel := true
var in_game := false
var _title_wrap: MarginContainer
var _pending := false
var _generation := 0
var _panel: PanelContainer
var _box: VBoxContainer
var _heading: Label
var _body: Label
var _actions: BoxContainer
var _footer_wrap: MarginContainer
var _body_scroll: ScrollContainer
var _fitting := false
var _reflow_pending := false
var _ok: Button
var _cancel: Button
var _shade: CanvasLayer
var _escape_owned := false


func _ready() -> void:
	set_meta(UiScale.META_EXTERNAL_SCALE, true)
	borderless = true
	unresizable = true
	transient = true
	exclusive = true
	visible = false
	_panel = PanelContainer.new()
	add_child(_panel)
	# The Window is fitted to this container. Full-rect anchors would feed its
	# initial wrapped minimum height back into the next Window resize.
	_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_panel.minimum_size_changed.connect(_reflow)
	_box = VBoxContainer.new()
	_panel.add_child(_box)
	_heading = Label.new()
	_heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_heading.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_title_wrap = MarginContainer.new()
	_box.add_child(_title_wrap)
	_title_wrap.add_child(_heading)
	_body_scroll = ScrollContainer.new()
	_body_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_body_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_box.add_child(_body_scroll)
	_body = Label.new()
	_body.set_meta(&"android_plain_text", true)
	_body.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body_scroll.add_child(_body)
	var gesture := preload("res://platform/android/touch_scroll.gd").new()
	gesture.scroll = _body_scroll
	_body_scroll.add_child(gesture)
	_actions = BoxContainer.new()
	_actions.alignment = BoxContainer.ALIGNMENT_CENTER
	_box.add_child(_actions)
	_ok = Button.new()
	_ok.text = "确认"
	_ok.pressed.connect(func():
		dismiss()
		confirmed.emit())
	_actions.add_child(_ok)
	_cancel = Button.new()
	_cancel.text = "取消"
	_cancel.pressed.connect(cancel)
	_actions.add_child(_cancel)
	_footer_wrap = Footer.wrap_row(_actions)
	close_requested.connect(cancel)
	_shade = CanvasLayer.new()
	_shade.layer = 128
	# Keep the blocker in the host viewport's input tree as well as its canvas.
	# A root-drawn CanvasLayer parented to this Window would block its own buttons.
	get_tree().root.add_child(_shade)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.35)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_shade.add_child(dim)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_shade.hide()
	get_tree().root.size_changed.connect(_reflow)
	UiScale.safe_area_changed.connect(_reflow)


func _exit_tree() -> void:
	if is_instance_valid(_shade):
		_shade.queue_free()


func _input(event: InputEvent) -> void:
	if not is_open_or_opening() or not event is InputEventKey or event.keycode != KEY_ESCAPE:
		return
	get_viewport().set_input_as_handled()
	if event.pressed and not event.echo:
		_escape_owned = true
	elif not event.pressed and _escape_owned:
		_escape_owned = false
		cancel()


func is_open_or_opening() -> bool:
	return _pending or visible


func get_label() -> Label:
	return _body


func get_ok_button() -> Button:
	return _ok


func get_cancel_button() -> Button:
	return _cancel


func open() -> void:
	_generation += 1
	_pending = true
	_shade.show()
	_layout_open(_generation)


func _layout_open(generation: int) -> void:
	_fit()
	await get_tree().process_frame
	await get_tree().process_frame
	if generation != _generation or not _pending:
		return
	_fit()
	popup()
	_pending = false


func _fit() -> void:
	if _fitting:
		return
	_fitting = true
	theme = UiTheme.theme(in_game)
	_heading.text = title
	_heading.visible = not title.is_empty()
	_title_wrap.visible = _heading.visible
	_body.text = dialog_text
	_body.visible = not dialog_text.is_empty()
	_body_scroll.visible = _body.visible
	_cancel.visible = with_cancel
	UiTheme.apply_tree(_panel, in_game)
	Footer.apply_buttons(_actions, UiTheme.px(4), theme)
	var frame := UiTheme.titled_frame(_heading) if _heading.visible else UiTheme.frame()
	frame.set_content_margin(SIDE_BOTTOM, UiTheme.px(8))
	_panel.add_theme_stylebox_override("panel", frame)
	UiTheme.title_gap(_heading, _box, _title_wrap)
	var footer_gap := UiTheme.px(12)
	if not _body_scroll.visible:
		_title_wrap.add_theme_constant_override("margin_bottom", 0)
		footer_gap = maxi(footer_gap, UiTheme.TitleSpacing.half_line(_heading)) if _heading.visible else 0
	Footer.set_gap(_footer_wrap, footer_gap)
	if not _heading.visible and not _body_scroll.visible:
		_footer_wrap.add_theme_constant_override("margin_top", 0)
	var bounds := PopupGeometry.bounds_for(self).grow(-UiTheme.px(4))
	var width := 0.0
	for line: String in (title + "\n" + dialog_text).split("\n"):
		width = maxf(width, UiTheme.FONT.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, UiTheme.font_px(16, in_game)).x)
	width = minf(bounds.size.x, maxf(width + frame.get_minimum_size().x, UiTheme.actions_width(_actions) + frame.get_minimum_size().x))
	UiTheme.fit_actions(_actions, width - frame.get_minimum_size().x)
	var content_width := maxf(1, width - frame.get_minimum_size().x)
	_heading.size.x = content_width
	var fixed := frame.get_minimum_size().y + _actions.get_combined_minimum_size().y
	if _heading.visible:
		fixed += _heading.get_minimum_size().y
		if _body_scroll.visible:
			fixed += UiTheme.TitleSpacing.half_line(_heading)
	fixed += footer_gap
	if _body_scroll.visible:
		_body.size.x = content_width
		var body_height := _body.get_minimum_size().y
		_body_scroll.custom_minimum_size.y = minf(body_height, maxf(UiTheme.px(16), bounds.size.y - fixed))
		UiTheme.scrollbar(_body_scroll, true, UiTheme.px(4))
	min_size = Vector2i.ZERO
	size.x = ceili(width)
	_panel.size.x = width
	size.y = ceili(_panel.get_combined_minimum_size().y)
	_panel.size = Vector2(size)
	position = bounds.position + (bounds.size - size) / 2
	_fitting = false


func _reflow() -> void:
	if is_open_or_opening() and not _fitting and not _reflow_pending:
		_reflow_pending = true
		_flush_reflow.call_deferred()


func _flush_reflow() -> void:
	_reflow_pending = false
	if is_open_or_opening():
		_fit()


func dismiss() -> void:
	_escape_owned = false
	_generation += 1
	_pending = false
	hide()
	if _shade != null:
		_shade.hide()


func cancel() -> void:
	dismiss()
	canceled.emit()
