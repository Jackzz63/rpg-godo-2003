extends Node

# OptionButton owns selection and opening. This adapter only prepares the native
# gray menu and reflows an already open menu after its owner has moved.
const Geometry := preload("res://cogs/popup_geometry.gd")
const META := &"option_popup_layout"
var source: OptionButton
var menu: PopupMenu
var touch_height: Callable
var presentation: Callable # Android opt-in, after the shared geometry metrics.
var _generation := 0
var _pending := false
var _scroll: ScrollContainer
var _gesture: Node
var _icon_scale := -1.0
var _item_tooltips: Dictionary = {}
var _hover_item_index := -1


static func install(button: OptionButton) -> Node:
	if button.has_meta(META):
		return button.get_meta(META)
	var adapter := new()
	adapter.source = button
	button.set_meta(META, adapter)
	button.add_child(adapter)
	return adapter


static func refresh(button: OptionButton) -> void:
	if is_instance_valid(button) and button.has_meta(META):
		button.get_meta(META).request_layout()


func _ready() -> void:
	menu = source.get_popup()
	menu.set_meta(UiScale.META_EXTERNAL_SCALE, true)
	# An explicit default theme also keeps the game's text shader/role colors out.
	menu.theme = ThemeDB.get_default_theme().duplicate()
	menu.about_to_popup.connect(_prepare_open)
	menu.popup_hide.connect(_closed)
	menu.window_input.connect(_menu_input)
	source.item_rect_changed.connect(request_layout)
	source.theme_changed.connect(request_layout)
	source.visibility_changed.connect(_source_visibility_changed)
	source.gui_input.connect(_source_input)
	get_tree().root.size_changed.connect(request_layout)
	UiScale.safe_area_changed.connect(request_layout)
	UiScale.scale_changed.connect(_scale_changed)
	_scroll = _find_scroll(menu)
	preload("res://cogs/button_pointer_feedback.gd").install(source)


func _source_input(event: InputEvent) -> void:
	# Native OptionButton also reacts to raw touch. With mouse emulation the
	# matching mouse event has already handled this press; do not open twice.
	if event is InputEventScreenTouch and Input.emulate_mouse_from_touch:
		source.accept_event()


func _scale_changed(_scale: float) -> void:
	request_layout()


func _source_visibility_changed() -> void:
	if not source.is_visible_in_tree():
		menu.hide()
		_closed()


func _closed() -> void:
	_generation += 1
	_pending = false
	_hover_item_index = -1
	var runtime := get_tree().get_first_node_in_group("webpage_theme_tooltip_runtime")
	if runtime != null and runtime.get("_target") == _scroll:
		runtime.call("_cancel_tooltip")


func _prepare_open() -> void:
	_generation += 1
	_pending = true
	_prepare_metrics()
	# Native first placement happens after this signal. Then keep the source
	# exposed so a second tap can close it, even beside the screen's bottom edge.
	_reflow.call_deferred(_generation, false)


func prepare_content_metrics() -> void:
	# Also usable by an opt-in owner before its first popup. Do not replace the
	# installed presentation callback (Android supplies its own final metrics).
	_prepare_metrics()


func prepared_content_width() -> float:
	var width := menu.get_contents_minimum_size().x
	var panel := menu.get_theme_stylebox("panel")
	if panel is StyleBoxFlat and (menu.is_embedded() or DisplayServer.is_window_transparency_available()):
		width -= maxf(0, panel.shadow_size - panel.shadow_offset.x) + maxf(0, panel.shadow_size + panel.shadow_offset.x)
	var origin := Geometry.control_point(menu, source, Vector2.ZERO)
	var unit := Geometry.control_point(menu, source, Vector2.RIGHT).x - origin.x
	return ceilf(width / maxf(unit, 0.001))


func _prepare_metrics() -> void:
	var font := source.get_theme_font("font")
	var font_size := source.get_theme_font_size("font_size")
	var row_min := 0
	if touch_height.is_valid():
		row_min = int(touch_height.call())
	elif OS.get_name() == "Android" and Engine.has_singleton("NativeTextInput"):
		row_min = roundi(Engine.get_singleton("NativeTextInput").uiDp(48.0))
	var separation := maxi(UiScale.physical_int(4.0), row_min - ceili(font.get_height(font_size)))
	menu.begin_bulk_theme_override()
	if menu.get_theme_font("font") != font:
		menu.add_theme_font_override("font", font)
	if menu.get_theme_font_size("font_size") != font_size:
		menu.add_theme_font_size_override("font_size", font_size)
	if menu.get_theme_constant("v_separation") != separation:
		menu.add_theme_constant_override("v_separation", separation)
	menu.end_bulk_theme_override()
	# This Window deliberately opts out of UiScale. Scale the default menu's
	# internal indicators and scrollbar here, from their original resources.
	var density := float(font_size) / 16.0
	var defaults := ThemeDB.get_default_theme()
	var panel := defaults.get_stylebox("panel", "PopupMenu").duplicate() as StyleBox
	panel.set_content_margin_all(roundi(8.0 * density))
	menu.add_theme_stylebox_override("panel", panel)
	if not is_equal_approx(_icon_scale, density):
		_icon_scale = density
		for icon_name in defaults.get_icon_list("PopupMenu"):
			var texture := defaults.get_icon(icon_name, "PopupMenu")
			var pixels := texture.get_image()
			if pixels == null or pixels.is_empty():
				continue
			pixels.resize(maxi(1, roundi(texture.get_width() * density)), maxi(1, roundi(texture.get_height() * density)), Image.INTERPOLATE_NEAREST)
			menu.add_theme_icon_override(icon_name, ImageTexture.create_from_image(pixels))
		menu.add_theme_constant_override("h_separation", roundi(defaults.get_constant("h_separation", "PopupMenu") * density))
	if is_instance_valid(_scroll):
		var bar := _scroll.get_v_scroll_bar()
		var width := maxi(roundi(12 * density), roundi(row_min * 0.5))
		for style_name in ["scroll", "scroll_focus", "grabber", "grabber_highlight", "grabber_pressed"]:
			var style := defaults.get_stylebox(style_name, "VScrollBar").duplicate() as StyleBox
			style.content_margin_left = width * 0.5
			style.content_margin_right = width * 0.5
			bar.add_theme_stylebox_override(style_name, style)
		if row_min > 0 and not is_instance_valid(_gesture):
			# Desktop exports exclude Android resources. Resolve this only when
			# Android touch presentation requests the gesture, not at script parse time.
			_gesture = load("res://platform/android/touch_scroll.gd").new()
			_gesture.scroll = _scroll
			_gesture.window_events = true
			_gesture.item_tooltip = _touch_item_tooltip
			_scroll.add_child(_gesture)
		if is_instance_valid(_gesture):
			_gesture.slop = maxf(8, row_min / 6.0)
		# Both desktop hover and Android hold use the shared themed tooltip.
		# Keep adopted text across reopening: the native tooltip is already empty.
		for index in _item_tooltips.keys():
			if index >= menu.item_count:
				_item_tooltips.erase(index)
		for index in menu.item_count:
			var text := menu.get_item_tooltip(index)
			if not text.is_empty():
				_item_tooltips[index] = text
				menu.set_item_tooltip(index, "")
	if presentation.is_valid():
		presentation.call(menu, _scroll)
	menu.min_size = Vector2i.ZERO
	menu.max_size = Geometry.bounds_for(menu).size


func _touch_item_tooltip(point: Vector2, finger: int) -> bool:
	var motion := InputEventMouseMotion.new()
	motion.device = -2
	motion.position = get_tree().root.get_screen_transform().affine_inverse() * menu.get_screen_transform() * point
	Input.parse_input_event(motion)
	var index := menu.get_focused_item()
	var text := str(_item_tooltips.get(index, ""))
	var runtime := get_tree().get_first_node_in_group("webpage_theme_tooltip_runtime")
	if text.is_empty() or runtime == null:
		return false
	runtime.show_touch_tooltip(_scroll, text, point, finger)
	return true


func _menu_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and event.device >= 0:
		_hover_item.call_deferred(_generation)


func _hover_item(generation: int) -> void:
	if not menu.visible or generation != _generation:
		return
	var index := menu.get_focused_item()
	if index == _hover_item_index:
		return
	_hover_item_index = index
	WebpageThemeTooltipRuntime.set_control_tooltip(_scroll, str(_item_tooltips.get(index, "")))
	var runtime := get_tree().get_first_node_in_group("webpage_theme_tooltip_runtime")
	if runtime != null:
		runtime.call("_on_control_mouse_entered", _scroll)


func _find_scroll(node: Node) -> ScrollContainer:
	for child in node.get_children(true):
		if child is ScrollContainer:
			return child
		var found := _find_scroll(child)
		if found != null:
			return found
	return null


func request_layout() -> void:
	if not is_instance_valid(menu) or not menu.visible or _pending:
		return
	_pending = true
	_reflow.call_deferred(_generation)


func _reflow(generation: int, settle_owner := true) -> void:
	# The initial native placement can cover the source button. Move it as soon
	# as popup() has returned, before the opening press is released. Later owner
	# resizing still waits for its containers to finish sorting.
	if settle_owner: await get_tree().process_frame
	if generation != _generation:
		return
	_pending = false
	if not menu.visible or not source.is_visible_in_tree():
		return
	_prepare_metrics()
	# PopupMenu measures its internal children, including the default shadow.
	var desired := Vector2i(menu.get_contents_minimum_size().ceil())
	var panel := menu.get_theme_stylebox("panel")
	var shadow_before := Vector2.ZERO
	var shadow_after := Vector2.ZERO
	if panel is StyleBoxFlat and (menu.is_embedded() or DisplayServer.is_window_transparency_available()):
		shadow_before = (Vector2.ONE * panel.shadow_size - panel.shadow_offset).max(Vector2.ZERO)
		shadow_after = (Vector2.ONE * panel.shadow_size + panel.shadow_offset).max(Vector2.ZERO)
	var anchor := Geometry.control_point(menu, source, Vector2(0, source.size.y))
	var width := (Geometry.control_point(menu, source, source.size) - anchor).x
	desired.x = maxi(desired.x, ceili(width + shadow_before.x + shadow_after.x))
	var bounds := Geometry.bounds_for(menu)
	var top := Geometry.control_point(menu, source, Vector2.ZERO).y
	var below := maxi(1, floori(bounds.end.y - anchor.y))
	var above := maxi(1, floori(top - bounds.position.y))
	var upwards := desired.y > below and above > below
	var available := above if upwards else below
	desired.y = mini(desired.y, available)
	menu.max_size = Vector2i(bounds.size.x, available)
	var position := Vector2i(anchor - Vector2(shadow_before.x, 0))
	if upwards: position.y = floori(top) - desired.y
	Geometry.apply_rect(menu, Geometry.anchored_rect(menu, desired, position))
