@tool
extends Button
## Launcher-only decoration. The native Button retains focus, input and border scaling.

## Edit this caption instead of the generated child text.
@export var caption_text := "":
	set(value):
		caption_text = value
		_queue_editor_layout()

## Authored minimum in design units, separate from the measured caption minimum.
@export var design_minimum_size := Vector2(0, 28):
	set(value):
		design_minimum_size = value
		_queue_editor_layout()

const CAPTION_PATH := "MarginContainer/PanelContainer/VBoxContainer/Caption"
@export var footer_action := false
var _layout_queued := false

func _ready() -> void:
	_update_design_layout()
	if Engine.is_editor_hint():
		(get_node(CAPTION_PATH) as RichTextLabel).theme_changed.connect(_queue_editor_layout)


func _validate_property(property: Dictionary) -> void:
	if property.name == "custom_minimum_size":
		# Never save the measured result as a new authored minimum.
		property.usage = PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY


func _queue_editor_layout() -> void:
	if not Engine.is_editor_hint() or not is_node_ready() or _layout_queued:
		return
	_layout_queued = true
	_update_editor_layout.call_deferred()


func _update_editor_layout() -> void:
	_layout_queued = false
	if is_inside_tree():
		_update_design_layout()


func _update_design_layout() -> void:
	var caption := get_node(CAPTION_PATH) as RichTextLabel
	caption.text = caption_text
	var line := TextLine.new()
	line.add_string(caption_text, caption.get_theme_font("normal_font"),
		caption.get_theme_font_size("normal_font_size"))
	var margin := $MarginContainer as MarginContainer
	var panel := $MarginContainer/PanelContainer as PanelContainer
	var vertical_padding := margin.get_theme_constant("margin_top") \
		+ margin.get_theme_constant("margin_bottom") \
		+ panel.get_theme_stylebox("panel").get_minimum_size().y \
		+ caption.get_theme_stylebox("normal").get_minimum_size().y
	# Preserve the original horizontal padding (five 16px CJK glyphs => 124.8).
	# Runtime measures once, before UiScale captures and scales these design units.
	var measured := Vector2(line.get_size().x + 44.8, ceilf(line.get_size().y + vertical_padding))
	if footer_action:
		var footer := preload("res://cogs/dialog_footer.gd").metrics(
			caption.get_theme_font("normal_font"), caption.get_theme_font_size("normal_font_size"), 4, caption_text)
		margin.add_theme_constant_override("margin_left", int(footer.horizontal))
		margin.add_theme_constant_override("margin_right", int(footer.horizontal))
		margin.add_theme_constant_override("margin_top", 4)
		margin.add_theme_constant_override("margin_bottom", 4)
		measured = footer.minimum
	var minimum := design_minimum_size.max(measured)
	if not custom_minimum_size.is_equal_approx(minimum):
		custom_minimum_size = minimum
