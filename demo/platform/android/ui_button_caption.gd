extends Label
## Only wrapped Android menu buttons need a separate shaped-text surface.
## The Button still owns its hit testing, minimum size, focus and activation.
var button: Button


static func install(owner: Button) -> void:
	var caption := owner.get_node_or_null("__AndroidCaption")
	if caption == null:
		caption = new()
		caption.name = "__AndroidCaption"
		caption.button = owner
		owner.add_child(caption, false, Node.INTERNAL_MODE_FRONT)
	caption.refresh()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# The parent Button owns the wrapping minimum; this surface only paints its text.
	clip_text = true
	vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	button.draw.connect(refresh)
	button.resized.connect(refresh)
	material = button.material.duplicate()
	ThemeTextLines.install(self)


func refresh() -> void:
	text = button.text
	horizontal_alignment = button.alignment
	if get_theme_font("font") != button.get_theme_font("font"):
		add_theme_font_override("font", button.get_theme_font("font"))
	if get_theme_font_size("font_size") != button.get_theme_font_size("font_size"):
		add_theme_font_size_override("font_size", button.get_theme_font_size("font_size"))
	var color := Color(1, 0, 1, 0.45 if button.disabled else 1.0)
	if get_theme_color("font_color") != color:
		add_theme_color_override("font_color", color)
	var style := button.get_theme_stylebox("normal")
	var inset := style.get_offset()
	var content := button.size - style.get_minimum_size()
	if button is CheckButton or button is CheckBox:
		var icon_width := maxf(button.get_theme_icon("checked").get_width(), button.get_theme_icon("unchecked").get_width())
		var reserve := icon_width + button.get_theme_constant("h_separation")
		content.x -= reserve
		if (button is CheckBox) != button.is_layout_rtl(): inset.x += reserve
	position = inset
	size = content.max(Vector2.ONE)
	for state: String in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color", "font_disabled_color"]:
		if button.get_theme_color(state).a != 0:
			button.add_theme_color_override(state, Color.TRANSPARENT)
