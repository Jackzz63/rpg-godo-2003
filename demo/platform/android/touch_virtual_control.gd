extends Control

const NORMAL_COLOR := Color(0.06, 0.09, 0.13)
const PRESSED_COLOR := Color(0.22, 0.34, 0.48)
const BORDER_COLOR := Color(0.8, 0.85, 0.9)

var control_type := "key"
var key_id := -1
var key_name := ""
var display_label := ""
var shape := "circle"
var controller_opacity := 0.4
var show_label := false
var pressed_visual := false
var active_direction := ""
var selected_visual := false
var configured_visible := true

func configure(control: Dictionary, opacity: float, labels_visible: bool) -> void:
	control_type = str(control.get("type", "key"))
	key_id = int(control.get("key_id", -1))
	key_name = str(control.get("key_name", ""))
	display_label = str(control.get("display_label", key_name))
	shape = str(control.get("shape", "circle"))
	controller_opacity = clampf(opacity, 0.1, 1.0)
	show_label = bool(control.get("label_visible_override", labels_visible))
	configured_visible = bool(control.get("visible", true))
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	queue_redraw()

func set_pressed_visual(value: bool) -> void:
	if pressed_visual == value:
		return
	pressed_visual = value
	queue_redraw()

func set_dpad_direction(value: String) -> void:
	if active_direction == value:
		return
	active_direction = value
	pressed_visual = not value.is_empty()
	queue_redraw()

func set_selected_visual(value: bool) -> void:
	if selected_visual == value:
		return
	selected_visual = value
	queue_redraw()

func _draw() -> void:
	if control_type == "dpad":
		_draw_dpad()
	elif control_type == "editor_menu":
		_draw_menu()
	else:
		_draw_key_button()
	if selected_visual:
		draw_rect(Rect2(Vector2.ONE, size - Vector2(2.0, 2.0)), Color(1.0, 0.82, 0.2, 0.95), false, 2.0)

func _draw_dpad() -> void:
	# Draw within the existing four arms; the center still captures a neutral touch.
	var unit := size / 3.0
	var arms := {"left": Vector2(0, 1), "up": Vector2(1, 0), "right": Vector2(2, 1), "down": Vector2(1, 2)}
	var arrows := {"left": "◀", "up": "▲", "right": "▶", "down": "▼"}
	for direction: String in arms:
		var held := active_direction == direction
		var alpha := _visual_alpha(held)
		var rect := Rect2(unit * arms[direction], unit).grow(-2.0)
		_draw_button(rect, false, held, alpha)
		_draw_text(arrows[direction], rect, alpha)

func _draw_key_button() -> void:
	var alpha := _visual_alpha(pressed_visual)
	var rect := Rect2(Vector2.ZERO, size).grow(-1.0)
	_draw_button(rect, shape == "circle", pressed_visual, alpha)
	if show_label and not display_label.is_empty():
		_draw_text(display_label, rect, alpha)


func _visual_alpha(held: bool) -> float:
	return (1.0 if held else controller_opacity) * (1.0 if configured_visible else 0.38)


func _draw_button(rect: Rect2, circle: bool, held: bool, alpha: float) -> void:
	var color := Color(PRESSED_COLOR if held else NORMAL_COLOR, alpha)
	var border := Color(BORDER_COLOR, alpha)
	if circle:
		var radius := minf(rect.size.x, rect.size.y) * 0.5
		draw_circle(rect.get_center(), radius, color)
		draw_arc(rect.get_center(), maxf(1.0, radius - 1.0), 0.0, TAU, 64, border, 2.0, true)
	else:
		var style := StyleBoxFlat.new()
		style.bg_color = color
		style.border_color = border
		style.set_border_width_all(2)
		style.set_corner_radius_all(mini(10, int(minf(rect.size.x, rect.size.y) * 0.2)))
		draw_style_box(style, rect)

func _draw_menu() -> void:
	var alpha := 1.0 if pressed_visual else controller_opacity
	var color := Color(BORDER_COLOR, alpha)
	var stroke := maxf(2.0, minf(size.x, size.y) * 0.075)
	for y_ratio in [0.30, 0.50, 0.70]:
		draw_line(Vector2(size.x * 0.18, size.y * y_ratio), Vector2(size.x * 0.82, size.y * y_ratio), color, stroke, true)

func _draw_text(text: String, rect: Rect2, alpha: float) -> void:
	var font := ThemeDB.fallback_font
	var font_size := maxi(10, int(minf(rect.size.x, rect.size.y) * 0.34))
	var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var baseline := rect.get_center() + Vector2(-text_size.x * 0.5, font.get_ascent(font_size) - text_size.y * 0.5)
	draw_string(font, baseline, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(1, 1, 1, alpha))
