@tool
extends RichTextLabel

const FONT := preload("res://resources/launcher_font.tres")
const SYSTEM := preload("res://resources/orchidmantis_system_celestial.png")
const SHADER := preload("res://resources/webpage_theme_text.gdshader")
const Lines := preload("res://cogs/theme_text_lines.gd")


func _validate_property(property: Dictionary) -> void:
	if property.name in ["material", "theme_override_colors/default_color"]:
		# Editor previews are regenerated from the System texture, not serialized.
		property.usage = PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY


func _ready() -> void:
	var shader_material := ShaderMaterial.new()
	shader_material.shader = SHADER
	var strip := ImageTexture.create_from_image(SYSTEM.get_image().get_region(Rect2i(0, 48, 1, 16)))
	shader_material.set_shader_parameter("normal_strip", strip)
	shader_material.set_shader_parameter("strong_strip", strip)
	shader_material.set_shader_parameter("muted_strip", strip)
	material = shader_material
	add_theme_color_override("default_color", Color.MAGENTA)
	if not has_theme_font_override("normal_font"):
		add_theme_font_override("normal_font", FONT)
	Lines.install(self)
