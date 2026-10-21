class_name NametagStylePopup
extends PopupPanel

signal mode_selected(mode: int)

const PopupGeometryScript := preload("res://cogs/popup_geometry.gd")
const _GAME_UI_FONT := preload("res://resources/webpage_game_ui_font.tres")
const _WEBPAGE_THEME_TEXT_RUNTIME := preload("res://cogs/webpage_theme_text_runtime.gd")
const SelectionBorder := preload("res://cogs/ui_selection_border.gd")
const _OPTIONS := [
	{"mode": 0, "text": "不显示"},
	{"mode": 1, "text": "经典"},
	{"mode": 2, "text": "全名"},
	{"mode": 3, "text": "全名(小)"},
]

var _connection: EasyMultiplayer = null
var _theme_source_override: Node
var _mode := 2
var _theme_text_runtime: Node
var _margin: MarginContainer
var _content: VBoxContainer
var _options_scroll: ScrollContainer
var _options_content: VBoxContainer
var _title: Label
var _title_spacing: Node
var _option_labels: Array[Label] = []
var _option_buttons: Array[Button] = []
var _recenter_pending := false
var _recenter_serial := 0
var _open_serial := 0
var _selection_frames: Array[Panel] = []
var _selection_layout_pending := false


func _ready() -> void:
	UiScale.safe_area_changed.connect(_queue_recenter)
	transparent_bg = true
	_theme_text_runtime = _WEBPAGE_THEME_TEXT_RUNTIME.new()
	add_child(_theme_text_runtime)
	_build_ui()
	popup_hide.connect(_on_popup_hidden)
	var root_viewport := get_tree().root
	if not root_viewport.size_changed.is_connected(_queue_recenter):
		root_viewport.size_changed.connect(_queue_recenter)
	if not UiScale.scale_changed.is_connected(_on_ui_scale_changed):
		UiScale.scale_changed.connect(_on_ui_scale_changed)
	_apply_scale()
	_refresh_styles()


func setup(connection: EasyMultiplayer) -> void:
	set_multiplayer_connection(connection)


func set_multiplayer_connection(connection: EasyMultiplayer) -> void:
	_connection = connection
	if is_node_ready():
		_theme_text_runtime.clear_caches()
		_refresh_styles()
		if visible: _apply_skin()


func set_nametag_mode(mode: int) -> void:
	_mode = clampi(mode, 0, 3)
	if is_node_ready():
		_refresh_styles()


func set_theme_source(source: Node) -> void:
	_theme_source_override = source
	if is_node_ready():
		_refresh_styles()
		if visible: _apply_skin()


func _theme_source() -> Node:
	return _theme_source_override if is_instance_valid(_theme_source_override) else _connection


func open_popup() -> void:
	if visible:
		return
	_open_serial += 1
	var serial := _open_serial
	_apply_skin()
	_show_after_layout(serial)


func dismiss() -> void:
	_open_serial += 1
	if visible:
		hide()


func _build_ui() -> void:
	_margin = MarginContainer.new()
	_margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_margin)
	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_margin.add_child(_content)
	_title = Label.new()
	_title.text = "玩家头顶昵称样式"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_override("font", _GAME_UI_FONT)
	_content.add_child(_title)
	_title_spacing = preload("res://cogs/popup_title_spacing.gd").install(_margin, _title, 16, true)
	var divider := HSeparator.new()
	divider.name = "HeaderDivider"
	_content.add_child(divider)
	_options_scroll = ScrollContainer.new()
	_options_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_options_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	UiScale.mark_geometry_physical(_options_scroll)
	_content.add_child(_options_scroll)
	_options_content = VBoxContainer.new()
	_options_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_options_content.add_theme_constant_override("separation", 6)
	_options_scroll.add_child(_options_content)
	for option in _OPTIONS:
		var button := Button.new()
		button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		button.focus_mode = Control.FOCUS_NONE
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		for style_name in ["normal", "hover", "pressed", "focus"]:
			button.add_theme_stylebox_override(style_name, StyleBoxEmpty.new())
		var label := Label.new()
		label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.text = str(option["text"])
		label.add_theme_font_override("font", _GAME_UI_FONT)
		button.add_child(label)
		var option_mode := int(option["mode"])
		button.pressed.connect(_select_mode.bind(option_mode))
		_options_content.add_child(button)
		_option_buttons.append(button)
		_option_labels.append(label)
		_selection_frames.append(SelectionBorder.add_to(button))
		button.resized.connect(_queue_selection_layout)


func _select_mode(mode: int) -> void:
	set_nametag_mode(mode)
	mode_selected.emit(_mode)


func _refresh_styles() -> void:
	if not is_instance_valid(_theme_text_runtime):
		return
	_theme_text_runtime.style_control(
		_title, _theme_source(), "", int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_NORMAL))
	for index in range(_option_labels.size()):
		_theme_text_runtime.style_control(
			_option_labels[index], _theme_source(), "",
			int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG)
			if index == _mode else int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_NORMAL))
	_queue_selection_layout()


func _apply_scale() -> void:
	if not is_instance_valid(_margin):
		return
	_content.add_theme_constant_override("separation", 6)
	_title.custom_minimum_size.y = 0.0
	_title_spacing.refresh()
	for button in _option_buttons:
		button.custom_minimum_size.y = 30.0


func _popup_rect() -> Rect2i:
	_title_spacing.refresh()
	var panel_padding := get_theme_stylebox("panel").get_minimum_size().y
	var fixed_height := _margin.get_combined_minimum_size().y - _options_scroll.get_combined_minimum_size().y + panel_padding
	var available := PopupGeometryScript.bounds_for(self).size.y - UiScale.physical_int(24) - fixed_height
	_options_scroll.custom_minimum_size.y = minf(ceilf(_options_content.get_combined_minimum_size().y), maxf(1.0, floorf(available)))
	var content_size := PopupGeometryScript.content_minimum_size(self) + Vector2i(get_theme_stylebox("panel").get_minimum_size().ceil())
	return PopupGeometryScript.centered_rect(self, content_size, Vector2i.ONE, UiScale.physical_int(12))


func _apply_skin() -> void:
	if is_instance_valid(_theme_source()):
		SystemUISkin.install(self, _theme_source(), "", -1)
	_queue_selection_layout()


func _queue_selection_layout() -> void:
	if _selection_layout_pending:
		return
	_selection_layout_pending = true
	_layout_selection_frames.call_deferred()


func _layout_selection_frames() -> void:
	_selection_layout_pending = false
	var skin := get_node_or_null("__SystemUISkin") as SystemUISkin
	if skin == null or _option_labels.size() != 4:
		return
	var scale := UiScale.get_ui_scale()
	var edges := skin.selection_border_insets() * scale
	var old_ink: Array[Rect2] = []
	var old_heights: Array[float] = []
	for label in _option_labels:
		var height := maxf(30.0 * scale, label.get_combined_minimum_size().y)
		old_heights.append(height)
		old_ink.append(SelectionBorder.label_ink(label, Vector2(label.size.x, height)))
	var gap := INF
	for index in 3:
		gap = minf(gap, 6.0 * scale + old_heights[index] - old_ink[index].end.y + old_ink[index + 1].position.y)
	for index in _option_labels.size():
		var label := _option_labels[index]
		var button := _option_buttons[index]
		var han := label.get_theme_font("font").get_string_size("汉", HORIZONTAL_ALIGNMENT_LEFT, -1, label.get_theme_font_size("font_size")).x
		var padding := Vector2(ceilf(han), ceilf(maxf(0.0, gap) / 3.0))
		UiScale.mark_geometry_physical(button)
		button.custom_minimum_size = label.get_combined_minimum_size() + padding * 2.0 + Vector2(edges.x + edges.z, edges.y + edges.w)
		_selection_frames[index].fit(SelectionBorder.label_ink(label), padding, skin, index == _mode)
	_queue_recenter()


func _queue_recenter() -> void:
	_recenter_serial += 1
	if not visible or _recenter_pending:
		return
	_recenter_pending = true
	_recenter_after_layout()


func _recenter_after_layout() -> void:
	while true:
		var serial := _recenter_serial
		await get_tree().process_frame
		if serial != _recenter_serial:
			continue
		await get_tree().process_frame
		if serial != _recenter_serial:
			continue
		break
	_recenter_pending = false
	if visible:
		PopupGeometryScript.apply_rect(self, _popup_rect())


func _show_after_layout(serial: int) -> void:
	await get_tree().process_frame
	if serial != _open_serial:
		return
	await get_tree().process_frame
	if serial != _open_serial:
		return
	popup(_popup_rect())
	await get_tree().process_frame
	if serial == _open_serial and visible:
		PopupGeometryScript.apply_rect(
			self,
			PopupGeometryScript.centered_rect(
				self,
				size,
				Vector2i.ONE,
				UiScale.physical_int(12.0)))


func _on_ui_scale_changed(_scale: float) -> void:
	_refresh_styles()
	_title_spacing.refresh.call_deferred()
	_queue_recenter()


func _on_popup_hidden() -> void:
	_open_serial += 1
	_recenter_serial += 1
	_recenter_pending = false
