extends RefCounted
## Shared launcher dropdown presentation, without an Android dependency.
const Frame := preload("res://cogs/launcher_popup_frame.gd")
const Lines := preload("res://cogs/launcher_list_lines.gd")
const BASE := preload("res://resources/theme.tres")
const BORDER := preload("res://resources/borders_texture.tres")


static func frame(density: float, padding := 16.0) -> StyleBox:
	var result := Frame.new()
	result.background = UiScale.physical_stylebox(BASE.get_stylebox("panel", "PanelContainer"), -1.0, density)
	result.border = UiScale.physical_texture_stylebox(BORDER, density)
	result.set_content_margin_all(roundi(padding * density))
	return result


static func install(button: OptionButton) -> void:
	button.clip_text = true
	button.fit_to_longest_item = false
	var adapter := preload("res://cogs/option_popup_layout.gd").install(button)
	button.set_meta(&"compact_option_style", true)
	adapter.presentation = func(menu: PopupMenu, scroll: ScrollContainer):
		prepare(menu, scroll, UiScale.get_ui_scale(), button.get_theme_stylebox("normal"), button.material as ShaderMaterial, button)
	# A zero minimum keeps desktop exports independent of Android gestures.
	adapter.touch_height = func(): return UiScale.physical_int(24) if OS.get_name() == "Android" else 0


static func copy_frame(source: StyleBox) -> StyleBox:
	if not source is Frame: return source.duplicate()
	# Script-only StyleBox fields are not copied by Resource.duplicate().
	var result := Frame.new()
	result.background = source.background
	result.border = source.border
	result.right_edge = source.right_edge
	result.edge_width = source.edge_width
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		result.set_content_margin(side, source.get_content_margin(side))
	return result


static func prepare(menu: PopupMenu, scroll: ScrollContainer, density: float, source_style: StyleBox = null, text_material: ShaderMaterial = null, source: OptionButton = null) -> void:
	var panel := copy_frame(source_style) if source_style is Frame else frame(density, 4)
	# Launcher buttons provide a transparent border only. Expanded lists still
	# need the launcher's tiled fill; game options supply both layers themselves.
	if source_style != null and not source_style is Frame: panel.border = source_style
	var font := menu.get_theme_font("font")
	var font_size := menu.get_theme_font_size("font_size")
	var horizontal := maxf(roundi(4 * density), ceilf(font.get_string_size("汉", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x * 0.5))
	panel.set_content_margin(SIDE_LEFT, horizontal)
	panel.set_content_margin(SIDE_RIGHT, horizontal)
	panel.set_content_margin(SIDE_TOP, roundi(4 * density))
	panel.set_content_margin(SIDE_BOTTOM, roundi(4 * density))
	menu.add_theme_stylebox_override("panel", panel)
	menu.add_theme_constant_override("v_separation", maxi(1, roundi(8 * density)))
	if source != null:
		menu.add_theme_constant_override("h_separation", maxi(1, roundi(4 * density)))
	var text_color := Color.WHITE if source != null and source.get_meta(&"plain_option_text", false) else Color.MAGENTA
	for color: String in ["font_color", "font_hover_color"]:
		menu.add_theme_color_override(color, text_color)
	menu.add_theme_color_override("font_disabled_color", Color(text_color, 0.45))
	if scroll == null:
		return
	var bar := scroll.get_v_scroll_bar()
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.focus_mode = Control.FOCUS_NONE
	var width := maxi(1, roundi(4 * density))
	for state: String in ["scroll", "scroll_focus", "grabber", "grabber_highlight", "grabber_pressed"]:
		var style := StyleBoxFlat.new()
		style.bg_color = Color(1, 1, 1, 0.12 if state.begins_with("scroll") else 0.55)
		style.content_margin_left = width * 0.5
		style.content_margin_right = width * 0.5
		style.set_corner_radius_all(maxi(1, width / 2))
		bar.add_theme_stylebox_override(state, style)
	for key: String in ["increment", "increment_highlight", "increment_pressed", "decrement", "decrement_highlight", "decrement_pressed"]:
		var empty := PlaceholderTexture2D.new()
		empty.size = Vector2.ZERO
		bar.add_theme_icon_override(key, empty)
	scroll.add_theme_constant_override("h_separation", width)
	Lines.install_popup(menu, scroll, text_material)

static func option_width(button: OptionButton) -> float:
	var font := button.get_theme_font("font")
	var font_size := button.get_theme_font_size("font_size")
	var widest := 0.0
	for index in button.item_count:
		widest = maxf(widest, font.get_string_size(button.get_item_text(index), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x)
	var style := button.get_theme_stylebox("normal")
	var arrow := button.get_theme_icon("arrow")
	var arrow_space := style.get_margin(SIDE_RIGHT) + arrow.get_width() + button.get_theme_constant("arrow_margin")
	var right := maxf(font.get_string_size("汉", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x * 1.5, arrow_space)
	return ceilf(widest + style.get_margin(SIDE_LEFT) + right)

static func content_width(node: Control, option_minimums: Dictionary = {}) -> float:
	if node is OptionButton: return maxf(option_width(node), float(option_minimums.get(node, 0.0)))
	if node is Label and node.autowrap_mode == TextServer.AUTOWRAP_OFF:
		return node.get_theme_font("font").get_string_size(node.text, HORIZONTAL_ALIGNMENT_LEFT, -1, node.get_theme_font_size("font_size")).x
	var widths: Array[float] = []
	for child in node.get_children():
		if child is Control and child.visible and not child.is_set_as_top_level() and not child is SystemUISkin:
			widths.append(content_width(child, option_minimums))
	if node is HBoxContainer:
		var total := float(node.get_theme_constant("separation") * maxi(0, widths.size() - 1))
		for width in widths: total += width
		return total
	if node is VBoxContainer or node is MarginContainer:
		var width := 0.0
		for child_width in widths: width = maxf(width, child_width)
		if node is MarginContainer: width += node.get_theme_constant("margin_left") + node.get_theme_constant("margin_right")
		return width
	return node.get_combined_minimum_size().x
