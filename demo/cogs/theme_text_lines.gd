@tool
class_name ThemeTextLines
extends Node
## Reads Godot's shaped lines on redraw, and caches a constant-cost shader lookup.
## No glyphs are drawn here; native selection, shaping and wrapping stay in charge.

var _control: Control
var _last_lines: Array[Vector2] = []
var _last_height := -1
var _last_material: Material


static func install(control: Control) -> void:
	var binding := control.get_node_or_null("__ThemeTextLines") as ThemeTextLines
	if binding == null:
		binding = ThemeTextLines.new()
		binding.name = "__ThemeTextLines"
		control.add_child(binding)
	binding.refresh.call_deferred()


func _ready() -> void:
	_control = get_parent() as Control
	_control.draw.connect(refresh)
	_control.resized.connect(refresh.call_deferred)
	_control.theme_changed.connect(refresh.call_deferred)


func refresh() -> void:
	if not is_instance_valid(_control) or not _control.material is ShaderMaterial:
		return
	var lines := shaped_lines(_control)
	var height := maxi(1, ceili(_control.size.y))
	if lines == _last_lines and height == _last_height and _control.material == _last_material:
		return
	_last_lines = lines
	_last_height = height
	_last_material = _control.material
	var material := _control.material as ShaderMaterial
	material.set_shader_parameter("use_line_map", lines.size() > 1)
	if lines.size() <= 1:
		var line := lines[0] if not lines.is_empty() else Vector2(0, height)
		material.set_shader_parameter("gradient_origin_y", line.x)
		material.set_shader_parameter("gradient_height", maxf(line.y, 1.0))
		return
	var lookup := Image.create(1, height, false, Image.FORMAT_RF)
	var line_index := 0
	for y in height:
		while line_index + 1 < lines.size() and float(y) + 0.5 >= lines[line_index + 1].x:
			line_index += 1
		var line := lines[line_index]
		var fraction := clampf((float(y) + 0.5 - line.x) / maxf(line.y, 1.0), 0.0, 0.999999)
		lookup.set_pixel(0, y, Color(fraction, 0, 0, 1))
	material.set_shader_parameter("line_map", ImageTexture.create_from_image(lookup))
	material.set_shader_parameter("line_map_height", float(height))


static func shaped_lines(control: Control) -> Array[Vector2]:
	var lines: Array[Vector2] = []
	if control is RichTextLabel:
		var label := control as RichTextLabel
		var box := label.get_theme_stylebox("normal")
		var origin := box.get_margin(SIDE_TOP) - label.get_v_scroll_bar().value
		var free_height := maxf(0, label.size.y - label.get_content_height() - box.get_minimum_size().y)
		if label.vertical_alignment == VERTICAL_ALIGNMENT_CENTER:
			origin += floorf(free_height / 2.0)
		elif label.vertical_alignment == VERTICAL_ALIGNMENT_BOTTOM:
			origin += free_height
		for index in label.get_line_count():
			lines.append(Vector2(origin + label.get_line_offset(index),
				maxf(1, label.get_line_height(index) - label.get_theme_constant("line_separation"))))
	elif control is Label:
		var label := control as Label
		var previous_y := -INF
		for index in label.text.length():
			var bounds := label.get_character_bounds(index)
			if bounds.size.y <= 0 or is_equal_approx(bounds.position.y, previous_y):
				continue
			previous_y = bounds.position.y
			lines.append(Vector2(bounds.position.y, bounds.size.y))
	else:
		var font := control.get_theme_font("font")
		var height := font.get_height(control.get_theme_font_size("font_size"))
		if control is TextEdit:
			var edit := control as TextEdit
			for line in edit.get_line_count():
				for wrap in range(edit.get_line_wrap_count(line) + 1):
					var column := 0
					for part in wrap:
						column += edit.get_line_wrapped_text(line)[part].length()
					var rect := edit.get_rect_at_line_column(line, column)
					if rect.position.y >= 0:
						lines.append(Vector2(rect.position.y, edit.get_line_height()))
		else:
			lines.append(Vector2(floorf((control.size.y - height) / 2.0), height))
	return lines
