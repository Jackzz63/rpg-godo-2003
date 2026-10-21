extends Control

var host: Control
var ranges: Array[Vector2i] = []
var _shape := TextLine.new()
var _signature: Array = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	show_behind_parent = true
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	clip_contents = true


func _process(_delta: float) -> void:
	if not is_instance_valid(host) or not host.is_visible_in_tree():
		return
	var scroll := float(host.get_scroll_offset()) if host is LineEdit else 0.0
	var body := str(host.get_meta("chat_select_text", "")) if host is RichTextLabel else str(host.text)
	var font_key := "normal_font" if host is RichTextLabel else "font"
	var size_key := "normal_font_size" if host is RichTextLabel else "font_size"
	var signature: Array = [body, host.size, host.get_theme_font(font_key),
		host.get_theme_font_size(size_key), scroll, ranges.duplicate(), host.text_direction]
	if signature != _signature:
		_signature = signature
		_shape.clear()
		_shape.direction = TextServer.DIRECTION_AUTO
		_shape.add_string(body, host.get_theme_font(font_key), host.get_theme_font_size(size_key))
		queue_redraw()


func _draw() -> void:
	if not is_instance_valid(host) or ranges.is_empty():
		return
	var left := 0.0
	var right := size.x
	if host is LineEdit:
		var style := host.get_theme_stylebox("normal")
		left = style.get_margin(SIDE_LEFT)
		right -= style.get_margin(SIDE_RIGHT)
	var origin := left + (float(host.get_scroll_offset()) if host is LineEdit else 0.0)
	var height := minf(size.y, _shape.get_size().y)
	var top := floorf((size.y - height) * 0.5)
	for span in ranges:
		var pieces := TextServerManager.get_primary_interface().shaped_text_get_selection(
			_shape.get_rid(), span.x, span.y)
		for piece in pieces:
			var x1 := maxf(left, origin + piece.x)
			var x2 := minf(right, origin + piece.y)
			if x2 > x1:
				var rect := Rect2(x1, top, x2 - x1, height)
				draw_rect(rect, Color(0.55, 0.8, 1.0, 0.2))
				draw_rect(rect, Color(0.7, 0.85, 1.0, 0.65), false, 1.0)
