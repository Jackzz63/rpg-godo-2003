extends RichTextLabel

var _body := ""
var _ranges: Array[Dictionary] = []
var _revealed: Dictionary = {}
var _shape := TextLine.new()
var _shape_signature: Array = []


func configure(body: String, offset: int, record: Dictionary) -> void:
	_body = body
	_revealed = record.spoiler_revealed
	for span: Dictionary in record.spoilers:
		var start := maxi(offset, int(span.start))
		var end := mini(offset + body.length(), int(span.end))
		if end > start:
			_ranges.append({"id": int(span.id), "start": start - offset, "end": end - offset})
	selection_enabled = false
	context_menu_enabled = false
	shortcut_keys_enabled = false
	bbcode_enabled = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_meta("chat_select_text", body)
	_rebuild_text()


func reveal_segment(segment: int) -> void:
	for span in _ranges:
		if int(span.id) == segment:
			_rebuild_text()
			return


func _rebuild_text() -> void:
	clear()
	var offset := 0
	for span in _ranges:
		add_text(_body.substr(offset, int(span.start) - offset))
		var hidden := not _revealed.has(int(span.id))
		if hidden:
			# Alpha zero suppresses glyphs, outlines and shadows while keeping advances.
			push_color(Color.TRANSPARENT)
		add_text(_body.substr(int(span.start), int(span.end) - int(span.start)))
		if hidden:
			pop()
		offset = int(span.end)
	add_text(_body.substr(offset))
	queue_redraw()


func spoiler_regions() -> Array[Dictionary]:
	var signature: Array = [_body, get_theme_font("normal_font"), get_theme_font_size("normal_font_size"), text_direction]
	if signature != _shape_signature:
		_shape_signature = signature
		_shape.clear()
		_shape.direction = TextServer.DIRECTION_AUTO
		_shape.add_string(_body, get_theme_font("normal_font"), get_theme_font_size("normal_font_size"))
	var regions: Array[Dictionary] = []
	for span in _ranges:
		for piece in TextServerManager.get_primary_interface().shaped_text_get_selection(
				_shape.get_rid(), int(span.start), int(span.end)):
			regions.append({"id": int(span.id), "rect": Rect2(piece.x, 0.0, piece.y - piece.x, _shape.get_size().y)})
	return regions


func spoiler_at(local_position: Vector2) -> int:
	for region in spoiler_regions():
		if not _revealed.has(int(region.id)) and (region.rect as Rect2).has_point(local_position):
			return int(region.id)
	return -1


func _draw() -> void:
	for region in spoiler_regions():
		var hidden := not _revealed.has(int(region.id))
		var rect: Rect2 = region.rect
		draw_rect(rect, Color(0.35, 0.38, 0.42, 0.85 if hidden else 0.12))
		draw_rect(rect, Color(0.7, 0.75, 0.8, 0.6 if hidden else 0.3), false, 1.0)
