extends RefCounted
## Presentation for Android-created menus. Metrics follow the launcher, not the
## editable game UI multiplier. Touch thresholds remain in Android dp.
const FONT := preload("res://resources/launcher_font.tres")
const BASE := preload("res://resources/theme.tres")
const BORDER := preload("res://resources/borders_texture.tres")
const SYSTEM := preload("res://resources/orchidmantis_system_celestial.png")
const SHADER := preload("res://resources/webpage_theme_text.gdshader")
const Frame := preload("res://cogs/launcher_popup_frame.gd")
const PopupStyle := preload("res://cogs/launcher_popup_style.gd")
const TitleSpacing := preload("res://cogs/popup_title_spacing.gd")
const ListLines := preload("res://platform/android/ui_list_lines.gd")
const ButtonCaption := preload("res://platform/android/ui_button_caption.gd")
const Options := preload("res://cogs/option_popup_layout.gd")
static var _theme: Theme
static var _scale := -1.0
static var _themes: Dictionary = {}
static var _strip: Texture2D


static func factor() -> float:
	return UiScale.scale_for_size((Engine.get_main_loop() as SceneTree).root.size) * 1.2


static func px(value: float) -> int:
	return maxi(1, roundi(value * factor()))


static func font_px(design_size := 16.0, in_game := false) -> int:
	return px(design_size * (1.25 if in_game else 1.0))


static func frame(padding := 16.0) -> StyleBox:
	return PopupStyle.frame(factor(), padding)


static func titled_frame(title: Control) -> StyleBox:
	var style := frame()
	style.set_content_margin(SIDE_TOP, maxi(px(16), TitleSpacing.half_line(title)))
	return style


static func title_gap(title: Control, box: BoxContainer, wrap: MarginContainer) -> void:
	var gap := TitleSpacing.half_line(title) - box.get_theme_constant("separation")
	if wrap.get_theme_constant("margin_bottom") != gap:
		wrap.add_theme_constant_override("margin_bottom", gap)


static func theme(in_game := false) -> Theme:
	var scale := factor()
	if not is_equal_approx(_scale, scale):
		_themes.clear()
		_scale = scale
	if _themes.has(in_game):
		return _themes[in_game]
	_theme = ThemeDB.get_default_theme().duplicate(true)
	_theme.default_font = FONT
	_theme.default_font_size = font_px(16, in_game)
	for type: StringName in _theme.get_type_list():
		for key: StringName in _theme.get_font_list(type):
			_theme.set_font(key, type, FONT)
		for key: StringName in _theme.get_font_size_list(type):
			_theme.set_font_size(key, type, font_px(16, in_game))
	_theme.set_stylebox("panel", "PanelContainer", frame())
	_theme.set_stylebox("panel", "Panel", frame())
	_theme.set_stylebox("panel", "PopupMenu", frame())
	for state: String in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		var style := frame(4)
		var padding := maxf(px(4), ceilf(FONT.get_string_size("汉", HORIZONTAL_ALIGNMENT_LEFT, -1, font_px(16, in_game)).x * 0.5))
		style.set_content_margin(SIDE_LEFT, padding)
		style.set_content_margin(SIDE_RIGHT, padding)
		if state == "focus":
			style.background = null
		if state in ["disabled", "hover", "pressed", "hover_pressed"]:
			style.border.modulate_color = Color(0.56, 0.56, 0.56, 1)
		for type: String in ["Button", "OptionButton"]:
			_theme.set_stylebox(state, type, style)
	# These surfaces own physical pixels. Scale the same original controls used
	# by the launcher once; do not combine a dp knob with an unscaled track.
	var defaults := ThemeDB.get_default_theme()
	for type: String in ["HSlider", "CheckButton", "CheckBox"]:
		for key: StringName in defaults.get_stylebox_list(type):
			_theme.set_stylebox(key, type, UiScale.physical_stylebox(defaults.get_stylebox(key, type), -1.0, scale))
		for key: StringName in defaults.get_icon_list(type):
			var texture := defaults.get_icon(key, type)
			var pixels := texture.get_image()
			if pixels != null and not pixels.is_empty():
				pixels.resize(maxi(1, roundi(texture.get_width() * scale)), maxi(1, roundi(texture.get_height() * scale)), Image.INTERPOLATE_NEAREST)
				_theme.set_icon(key, type, ImageTexture.create_from_image(pixels))
		for key: StringName in defaults.get_constant_list(type):
			_theme.set_constant(key, type, roundi(defaults.get_constant(key, type) * scale))
	for type: String in ["VBoxContainer", "HBoxContainer", "GridContainer"]:
		for key: String in ["separation", "h_separation", "v_separation"]:
			_theme.set_constant(key, type, px(4))
	_themes[in_game] = _theme
	return _theme


static func text(control: Control, design_size := 16.0, in_game := false) -> void:
	if control is RichTextLabel:
		if control.get_theme_font("normal_font") != FONT:
			control.add_theme_font_override("normal_font", FONT)
		if control.get_theme_font_size("normal_font_size") != font_px(design_size, in_game):
			control.add_theme_font_size_override("normal_font_size", font_px(design_size, in_game))
		if control.get_theme_color("default_color") != Color.MAGENTA:
			control.add_theme_color_override("default_color", Color.MAGENTA)
	if control.get_theme_font("font") != FONT:
		control.add_theme_font_override("font", FONT)
	if control.get_theme_font_size("font_size") != font_px(design_size, in_game):
		control.add_theme_font_size_override("font_size", font_px(design_size, in_game))
	if control is LineEdit or control is OptionButton or control is ItemList or control.get_meta(&"android_plain_text", false):
		if control is OptionButton: control.set_meta(&"plain_option_text", true)
		for key: String in ["font_color", "font_selected_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color", "font_uneditable_color"]:
			if control.get_theme_color(key) != Color.WHITE:
				control.add_theme_color_override(key, Color.WHITE)
		for key: String in ["font_disabled_color", "font_placeholder_color"]:
			if control.get_theme_color(key) != Color(1, 1, 1, 0.45):
				control.add_theme_color_override(key, Color(1, 1, 1, 0.45))
		return
	if not control.get_meta(&"android_theme_text", false):
		if _strip == null:
			_strip = ImageTexture.create_from_image(SYSTEM.get_image().get_region(Rect2i(0, 48, 1, 16)))
		var material := ShaderMaterial.new()
		material.shader = SHADER
		for role: String in ["normal_strip", "strong_strip", "muted_strip"]:
			material.set_shader_parameter(role, _strip)
		control.material = material
		control.set_meta(&"android_theme_text", true)
	if not control.has_node("__AndroidCaption"):
		for color: String in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color", "font_selected_color"]:
			if control.get_theme_color(color) != Color.MAGENTA:
				control.add_theme_color_override(color, Color.MAGENTA)
		if control.get_theme_color("font_disabled_color") != Color(1, 0, 1, 0.45):
			control.add_theme_color_override("font_disabled_color", Color(1, 0, 1, 0.45))
	if control is ItemList:
		ListLines.install(control)
	else:
		ThemeTextLines.install(control)


static func apply_tree(node: Node, in_game := false) -> void:
	if node is Label or node is RichTextLabel or node is LineEdit or node is Button or node is ItemList:
		text(node, float(node.get_meta(&"android_font_design", 16.0)), in_game)
	if node is Button:
		preload("res://cogs/button_pointer_feedback.gd").install(node)
		if node is OptionButton:
			configure_option(node)
		elif node.autowrap_mode != TextServer.AUTOWRAP_OFF:
			ButtonCaption.install(node)
		if not (node is CheckButton or node is CheckBox):
			var natural: Vector2 = node.get_minimum_size()
			var height := ceilf(natural.y * float(node.get_meta(&"android_row_height", 1.0)))
			var minimum := Vector2(height, height)
			if node.custom_minimum_size != minimum:
				node.custom_minimum_size = minimum
	if node is VBoxContainer and node.get_meta(&"android_section_spacing", false):
		var spacing := ceili(FONT.get_height(font_px(16, in_game)) * 0.5)
		if node.get_theme_constant("separation") != spacing:
			node.add_theme_constant_override("separation", spacing)
	if node is Control and node.get_meta(&"android_section_gap", false):
		node.custom_minimum_size.y = ceilf(FONT.get_height(font_px(16, in_game)) * 0.5)
	for child: Node in node.get_children():
		if not child is Window and not child is ButtonCaption:
			apply_tree(child, in_game)


static func configure_option(button: OptionButton) -> void:
	button.clip_text = true
	button.fit_to_longest_item = false
	var original := ThemeDB.get_default_theme().get_icon("arrow", "OptionButton")
	if button.get_meta(&"android_arrow_scale", -1.0) != factor():
		var pixels := original.get_image()
		pixels.resize(px(10), px(10), Image.INTERPOLATE_NEAREST)
		button.add_theme_icon_override("arrow", ImageTexture.create_from_image(pixels))
		button.add_theme_constant_override("arrow_margin", px(4))
		button.set_meta(&"android_arrow_scale", factor())
	var adapter := Options.install(button)
	adapter.touch_height = px.bind(24)
	button.set_meta(&"compact_option_style", true)
	adapter.presentation = func(menu: PopupMenu, scroll: ScrollContainer):
		PopupStyle.prepare(menu, scroll, factor(), button.get_theme_stylebox("normal"), button.material as ShaderMaterial, button)


static func prepare_options(menu: PopupMenu, scroll: ScrollContainer) -> void:
	PopupStyle.prepare(menu, scroll, factor())


static func scrollbar(scroll: ScrollContainer, passive: bool, width: int) -> void:
	style_bar(scroll.get_v_scroll_bar(), passive, width)
	scroll.add_theme_constant_override("h_separation", px(4))
	# These helpers intentionally opt in; directory and catalog bars keep input.
	scroll.set_meta(&"android_passive_scrollbar", passive)


static func style_bar(bar: VScrollBar, passive: bool, width: int) -> void:
	bar.custom_minimum_size.x = 0
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE if passive else Control.MOUSE_FILTER_STOP
	bar.focus_mode = Control.FOCUS_NONE
	var key := Vector2i(width, int(passive))
	if bar.get_meta(&"android_bar_style", Vector2i(-1, -1)) == key:
		return
	bar.set_meta(&"android_bar_style", key)
	for state: String in ["scroll", "scroll_focus", "grabber", "grabber_highlight", "grabber_pressed"]:
		var style := StyleBoxFlat.new()
		style.bg_color = Color(1, 1, 1, 0.12 if state.begins_with("scroll") else 0.55)
		style.content_margin_left = width * 0.5
		style.content_margin_right = width * 0.5
		style.set_corner_radius_all(maxi(1, width / 2))
		bar.add_theme_stylebox_override(state, style)
	for icon: String in ["increment", "increment_highlight", "increment_pressed", "decrement", "decrement_highlight", "decrement_pressed"]:
		var empty := PlaceholderTexture2D.new()
		empty.size = Vector2.ZERO
		bar.add_theme_icon_override(icon, empty)


static func actions_width(row: BoxContainer) -> float:
	var needed := 0.0
	var count := 0
	for child: Node in row.get_children():
		if child is Control and child.visible:
			needed += child.get_combined_minimum_size().x
			count += 1
	return needed + row.get_theme_constant("separation") * maxi(0, count - 1)


static func fit_actions(row: BoxContainer, available: float) -> void:
	row.vertical = actions_width(row) > available
