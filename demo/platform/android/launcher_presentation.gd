extends RefCounted

# Only Android-created launcher surfaces use these metrics and local resources.
const BASE_THEME := preload("res://resources/theme.tres")
const FONT := preload("res://resources/launcher_font.tres")
static var density_override := 0.0 # Desktop scene fixtures supply Android densities.
static var font_scale_override := 1.0
static var _theme: Theme
static var _theme_metrics: Array = []
static var _legacy_themes: Dictionary = {}
static var _legacy_metrics: Array = []


static func density() -> float:
	if density_override > 0.0:
		return density_override
	if Engine.has_singleton("NativeTextInput"):
		return float(Engine.get_singleton("NativeTextInput").uiDp(1.0))
	return UiScale.get_ui_scale()


static func dp(value: float) -> int:
	if density_override > 0.0:
		return roundi(value * density_override)
	if Engine.has_singleton("NativeTextInput"):
		return roundi(Engine.get_singleton("NativeTextInput").uiDp(value))
	return UiScale.physical_int(value)


static func sp(value: float) -> int:
	if density_override <= 0.0 and Engine.has_singleton("NativeTextInput"):
		return roundi(Engine.get_singleton("NativeTextInput").uiSp(value))
	return roundi(value * density_override * font_scale_override) if density_override > 0.0 else dp(value)


static func take_ownership(node: Node) -> void:
	node.set_meta(UiScale.META_EXTERNAL_SCALE, true)


static func legacy_theme(app_theme := true) -> Theme:
	# Preserve 0.0.2b's theme families while converting their design sizes once.
	var metrics := [density(), sp(16)]
	if metrics != _legacy_metrics:
		_legacy_themes.clear()
		_legacy_metrics = metrics
	if _legacy_themes.has(app_theme):
		return _legacy_themes[app_theme]
	var source := ThemeDB.get_default_theme().duplicate(true) as Theme
	if app_theme:
		source.merge_with(BASE_THEME)
	var result := source.duplicate(true) as Theme
	if app_theme: result.default_font = FONT
	result.default_font_size = sp(source.default_font_size)
	for type in source.get_type_list():
		for key in source.get_font_size_list(type):
			result.set_font_size(key, type, sp(source.get_font_size(key, type)))
		for key in source.get_constant_list(type):
			result.set_constant(key, type, dp(source.get_constant(key, type)))
		for key in source.get_stylebox_list(type):
			var style := _style(source.get_stylebox(key, type))
			if style is StyleBoxFlat:
				for corner in [CORNER_TOP_LEFT, CORNER_TOP_RIGHT, CORNER_BOTTOM_LEFT, CORNER_BOTTOM_RIGHT]:
					style.set_corner_radius(corner, dp(style.get_corner_radius(corner)))
			result.set_stylebox(key, type, style)
		for key in source.get_icon_list(type):
			var icon := source.get_icon(key, type)
			if icon == null: continue
			var pixels := icon.get_image()
			if pixels == null or pixels.is_empty(): continue
			pixels.resize(maxi(1, dp(icon.get_width())), maxi(1, dp(icon.get_height())))
			result.set_icon(key, type, ImageTexture.create_from_image(pixels))
	_legacy_themes[app_theme] = result
	return result


static func fit_legacy_dialog(dialog: Variant, design_size := Vector2(520, 280)) -> void:
	if not is_instance_valid(dialog) or not dialog.is_inside_tree(): return
	dialog.theme = legacy_theme()
	_apply_dialog_padding(dialog)
	_fit_dialog_rect(dialog, design_size, 12)


static func install_legacy_dialog(dialog: AcceptDialog, design_size := Vector2(520, 280)) -> void:
	take_ownership(dialog)
	dialog.theme = legacy_theme()
	var fit := func(): fit_legacy_dialog.call_deferred(dialog, design_size)
	var reflow := func():
		if is_instance_valid(dialog) and dialog.visible: fit.call()
	dialog.about_to_popup.connect(fit)
	dialog.get_label().minimum_size_changed.connect(reflow)
	UiScale.safe_area_changed.connect(reflow)
	dialog.tree_exiting.connect(func():
		if UiScale.safe_area_changed.is_connected(reflow): UiScale.safe_area_changed.disconnect(reflow))


static func dialog_decoration(dialog: Window) -> Vector4i:
	if dialog.borderless or not dialog.is_embedded(): return Vector4i.ZERO
	var edges := Vector4i(0, dialog.get_theme_constant("title_height", "Window"), 0, 0)
	for state: String in ["embedded_border", "embedded_unfocused_border"]:
		var style := dialog.get_theme_stylebox(state, "Window")
		if style is StyleBoxFlat or style is StyleBoxTexture:
			for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
				edges[side] = maxi(edges[side], ceili(style.get_expand_margin(side)))
	return edges


static func _fit_dialog_rect(dialog: AcceptDialog, design_size: Vector2, margin: int) -> void:
	var bounds := PopupGeometry.bounds_for(dialog).grow(-dp(margin))
	var edges := dialog_decoration(dialog)
	var decoration := Vector2i(edges.x + edges.z, edges.y + edges.w)
	var available := (bounds.size - decoration).max(Vector2i.ONE)
	dialog.min_size = Vector2i.ZERO
	dialog.size = Vector2i(dp(design_size.x), dp(design_size.y)).min(available)
	# AcceptDialog supplies the actual wrapped content minimum. Center its final
	# client size together with the title and theme decoration, not the client alone.
	dialog.position = bounds.position + (bounds.size - dialog.size - decoration) / 2 + Vector2i(edges.x, edges.y)


static func style_plain_action(button: Button, source_theme: Theme) -> void:
	# Read resolved margins from the dp-scaled theme, never a previous override.
	for state: String in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		var source := source_theme.get_stylebox(state, "Button")
		var style: StyleBox = StyleBoxEmpty.new()
		if state in ["hover", "pressed", "hover_pressed", "focus"]:
			var flat := StyleBoxFlat.new()
			flat.bg_color = Color(1, 1, 1, 0.08 if state == "hover" else 0.16)
			if state == "focus":
				flat.bg_color = Color.TRANSPARENT
				flat.border_color = Color(0.65, 0.65, 0.65)
				flat.set_border_width_all(maxi(1, dp(1)))
			style = flat
		for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
			style.set_content_margin(side, source.get_margin(side))
		button.add_theme_stylebox_override(state, style)


static func _style(source: StyleBox) -> StyleBox:
	var result := source.duplicate(true) as StyleBox
	if source is StyleBoxTexture:
		result = UiScale.physical_texture_stylebox(source, density())
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		var margin := source.get_content_margin(side)
		if margin >= 0.0:
			result.set_content_margin(side, dp(margin))
		if result is StyleBoxTexture:
			result.set_expand_margin(side, dp(source.get_expand_margin(side)))
		elif result is StyleBoxFlat:
			result.set_border_width(side, dp(source.get_border_width(side)))
			result.set_expand_margin(side, dp(source.get_expand_margin(side)))
	return result


static func _scroll_style(color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_content_margin_all(dp(12))
	style.set_corner_radius_all(dp(5))
	return style


static func make_theme() -> Theme:
	# Keep only the current immutable Android launcher theme. Font conversions
	# stay per-size (Android 14 sp conversion need not be linear).
	var metrics: Array = [density(), sp(18)]
	for type in BASE_THEME.get_type_list():
		for key in BASE_THEME.get_font_size_list(type):
			metrics.append(sp(BASE_THEME.get_font_size(key, type)))
	if _theme != null and metrics == _theme_metrics:
		return _theme
	var started := ClientPerformance.begin()
	var result := BASE_THEME.duplicate(true) as Theme
	result.default_font = FONT
	result.default_font_size = sp(18)
	for type in BASE_THEME.get_type_list():
		for key in BASE_THEME.get_stylebox_list(type):
			result.set_stylebox(key, type, _style(BASE_THEME.get_stylebox(key, type)))
		for key in BASE_THEME.get_constant_list(type):
			result.set_constant(key, type, dp(BASE_THEME.get_constant(key, type)))
		for key in BASE_THEME.get_font_size_list(type):
			result.set_font_size(key, type, sp(BASE_THEME.get_font_size(key, type)))
	for type in ["Button", "Label"]:
		result.set_font_size("font_size", type, sp(18))
	result.set_constant("separation", "VBoxContainer", dp(6))
	result.set_constant("separation", "HBoxContainer", dp(8))
	for side in ["left", "top", "right", "bottom"]:
		result.set_constant("margin_" + side, "MarginContainer", dp(10))
	result.set_stylebox("scroll", "VScrollBar", _scroll_style(Color(0.12, 0.14, 0.20)))
	result.set_stylebox("grabber", "VScrollBar", _scroll_style(Color(0.55, 0.58, 0.66)))
	result.set_stylebox("grabber_highlight", "VScrollBar", _scroll_style(Color(0.75, 0.78, 0.86)))
	result.set_stylebox("grabber_pressed", "VScrollBar", _scroll_style(Color(0.85, 0.88, 0.96)))
	var panel := _style(BASE_THEME.get_stylebox("panel", "PanelContainer"))
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		panel.set_content_margin(side, dp(10))
	result.set_stylebox("panel", "PanelContainer", panel)
	result.set_stylebox("panel", "AcceptDialog", panel)
	result.set_constant("buttons_min_height", "AcceptDialog", dp(48))
	result.set_constant("buttons_min_width", "AcceptDialog", dp(96))
	result.set_constant("buttons_separation", "AcceptDialog", dp(12))
	result.set_type_variation("DirectoryRow", "Button")
	for key in ["normal", "hover", "pressed", "hover_pressed"]:
		var row := StyleBoxFlat.new()
		row.bg_color = Color(0.05, 0.06, 0.09, 0.6 if key == "normal" else 0.9)
		row.border_color = Color(0.4, 0.42, 0.5, 0.6)
		row.border_width_bottom = maxi(1, dp(1))
		row.set_content_margin_all(dp(6))
		result.set_stylebox(key, "DirectoryRow", row)
	# Window decorations and PopupMenu icons are not Control children.
	var defaults := ThemeDB.get_default_theme()
	for type in ["Window"]:
		for key in defaults.get_icon_list(type):
			var texture := defaults.get_icon(key, type)
			var pixels := texture.get_image()
			if pixels != null and not pixels.is_empty():
				pixels.resize(maxi(1, dp(texture.get_width())), maxi(1, dp(texture.get_height())))
				if type == "Window":
					pixels.resize(dp(24), dp(24))
					var target := Image.create(dp(48), dp(48), false, Image.FORMAT_RGBA8)
					pixels.convert(Image.FORMAT_RGBA8)
					target.blit_rect(pixels, Rect2i(Vector2i.ZERO, pixels.get_size()), Vector2i.ONE * dp(12))
					pixels = target
				result.set_icon(key, type, ImageTexture.create_from_image(pixels))
	result.set_font("title_font", "Window", FONT)
	result.set_font_size("title_font_size", "Window", sp(18))
	for key in defaults.get_constant_list("Window"):
		result.set_constant(key, "Window", dp(defaults.get_constant(key, "Window")))
	result.set_constant("title_height", "Window", dp(48))
	result.set_constant("close_v_offset", "Window", dp(48))
	result.set_constant("close_h_offset", "Window", dp(48))
	for key in defaults.get_stylebox_list("Window"):
		var border := _style(defaults.get_stylebox(key, "Window"))
		border.set_expand_margin(SIDE_TOP, dp(48))
		result.set_stylebox(key, "Window", border)
	_theme_metrics = metrics
	_theme = result
	ClientPerformance.end(&"android.directory_theme", started)
	return result


static func fit_error(dialog: AcceptDialog) -> void:
	dialog.theme = make_theme()
	_apply_dialog_padding(dialog)
	dialog.get_label().add_theme_font_size_override("font_size", sp(18))
	dialog.get_ok_button().add_theme_font_size_override("font_size", sp(18))
	_fit_error_bounds(dialog)


static func _apply_dialog_padding(dialog: AcceptDialog) -> void:
	var panel := dialog.get_theme_stylebox("panel").duplicate() as StyleBox
	panel.set_content_margin_all(dp(8))
	dialog.add_theme_stylebox_override("panel", panel)


static func _fit_error_bounds(dialog: AcceptDialog) -> void:
	if not is_instance_valid(dialog) or not dialog.is_inside_tree():
		return
	preload("res://cogs/dialog_error_layout.gd").fit(dialog, dp(480), dp(4), dp(12), dp(8), dp(16))


static func install_error(dialog: AcceptDialog) -> void:
	take_ownership(dialog)
	dialog.get_label().autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dialog.about_to_popup.connect(func(): fit_error.call_deferred(dialog))
	var reflow := func():
		if is_instance_valid(dialog) and dialog.visible:
			_fit_error_bounds.call_deferred(dialog)
	UiScale.safe_area_changed.connect(reflow)
	dialog.tree_exiting.connect(func():
		if UiScale.safe_area_changed.is_connected(reflow):
			UiScale.safe_area_changed.disconnect(reflow))
	# Autowrapped text settles after the new width/font; fit again from that actual minimum.
	dialog.get_label().minimum_size_changed.connect(func():
		if dialog.visible:
			_fit_error_bounds.call_deferred(dialog))
	fit_error(dialog)
