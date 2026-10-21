extends Panel
## Border-only indicator for the two text selectors. Coordinates are physical.
var _style_source: StyleBox
var _style_scale := -1.0

static func add_to(button: Button) -> Panel:
	var indicator := new()
	indicator.name = "SelectedBorder"
	indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiScale.mark_geometry_physical(indicator)
	UiScale.mark_styles_physical(indicator)
	button.add_child(indicator)
	return indicator


static func label_ink(label: Label, layout_size := Vector2(-1, -1)) -> Rect2:
	var font := label.get_theme_font("font")
	var pixels := label.get_theme_font_size("font_size")
	var key := [font, pixels, label.text, label.language]
	var cached: Dictionary = label.get_meta(&"selection_ink", {})
	if cached.get("key", []) != key:
		var line := TextLine.new()
		line.add_string(label.text, font, pixels, label.language)
		var server := TextServerManager.get_primary_interface()
		var ink := Rect2()
		var advance := 0.0
		for glyph: Dictionary in server.shaped_text_get_glyphs(line.get_rid()):
			var rid: RID = glyph.font_rid
			var glyph_size := Vector2i(int(glyph.font_size), 0)
			for repeat in int(glyph.repeat):
				if rid.is_valid():
					var extent := server.font_get_glyph_size(rid, glyph_size, int(glyph.index))
					if extent.x > 0 and extent.y > 0:
						var offset := server.font_get_glyph_offset(rid, glyph_size, int(glyph.index))
						var bounds := Rect2(Vector2(advance, 0) + Vector2(glyph.offset) + offset, extent)
						ink = bounds if not ink.has_area() else ink.merge(bounds)
				advance += float(glyph.advance)
		var height := maxf(float(int(font.get_height(pixels))), line.get_size().y)
		var baseline := line.get_line_ascent() + maxf(0.0, height - line.get_size().y) * 0.5
		if not ink.has_area():
			ink = Rect2(Vector2(0, -baseline), line.get_size())
		cached = {"key": key, "ink": ink, "width": line.get_line_width(), "height": height, "baseline": baseline}
		label.set_meta(&"selection_ink", cached)
	if layout_size.x < 0:
		layout_size = label.size
	var offset := Vector2(0, float(cached.baseline))
	if label.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER:
		offset.x = floorf((layout_size.x - float(cached.width)) * 0.5)
	if label.vertical_alignment == VERTICAL_ALIGNMENT_CENTER:
		offset.y += floorf((layout_size.y - float(cached.height)) * 0.5)
	return Rect2((cached.ink as Rect2).position + offset, (cached.ink as Rect2).size)


func fit(ink: Rect2, padding: Vector2, skin: SystemUISkin, selected: bool) -> void:
	visible = selected
	if skin == null:
		return
	var source := skin.selection_border_style()
	var scale := UiScale.get_ui_scale()
	if source != _style_source or not is_equal_approx(scale, _style_scale):
		_style_source = source
		_style_scale = scale
		add_theme_stylebox_override("panel", UiScale.physical_stylebox(source))
	var edges := skin.selection_border_insets() * UiScale.get_ui_scale()
	position = (ink.position - padding - Vector2(edges.x, edges.y)).floor()
	size = (ink.end + padding + Vector2(edges.z, edges.w)).ceil() - position
