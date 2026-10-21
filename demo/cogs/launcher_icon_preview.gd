@tool
extends Button
## Editor-only icon initialization. Runtime status, cooldown and DPI updates stay
## with their existing owners.

const ThemeText := preload("res://cogs/webpage_theme_text_runtime.gd")

@export var preview_icon: Texture2D:
	set(value):
		preview_icon = value
		if Engine.is_editor_hint() and is_node_ready():
			_update_preview_icon()


func _ready() -> void:
	if Engine.is_editor_hint():
		_update_preview_icon()


func _validate_property(property: Dictionary) -> void:
	if property.name == "icon":
		# The generated white raster is a preview, never a serialized scene asset.
		property.usage = PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY


func _update_preview_icon() -> void:
	if preview_icon != null:
		icon = white_icon(ThemeText.make_dpi_icon_texture(preview_icon, Vector2i(32, 32)))


static func white_icon(rendered: Texture2D) -> Texture2D:
	var image := rendered.get_image()
	if image == null or image.is_empty():
		return rendered
	image = image.duplicate()
	for y in image.get_height():
		for x in image.get_width():
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, image.get_pixel(x, y).a))
	return ImageTexture.create_from_image(image)
