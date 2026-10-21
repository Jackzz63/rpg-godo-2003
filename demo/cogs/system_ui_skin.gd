class_name SystemUISkin
extends Control

const _FALLBACK_BACKGROUND_COLOR := Color(0.035, 0.035, 0.045, 0.94)
const _FALLBACK_BORDER_COLOR := Color(0.78, 0.78, 0.82, 1.0)

var _background_style: StyleBox = null
var _border_style: StyleBox = null
var _background_panel: Panel = null
var _border_panel: Panel = null
var _border_insets := Vector4.ONE


static func install(
		panel,
		connection: Node,
		system_name: String,
		stretch_mode: int) -> void:
	if not is_instance_valid(panel) or not is_instance_valid(connection):
		return
	var resolved_stretch := stretch_mode
	if resolved_stretch < 0:
		resolved_stretch = int(connection.get_local_player_snapshot().get("system_stretch", 1))
	install_texture(panel, connection.get_menu_system_texture(system_name), resolved_stretch)


static func install_texture(panel, texture: Texture2D, stretch_mode: int) -> void:
	var skin := panel.get_node_or_null("__SystemUISkin") as SystemUISkin
	if skin == null:
		skin = SystemUISkin.new()
		skin.name = "__SystemUISkin"
		skin.mouse_filter = Control.MOUSE_FILTER_IGNORE
		skin.z_index = -1
		panel.add_child(skin)
		panel.move_child(skin, 0)
		skin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	skin.configure(texture, stretch_mode)


func configure(system_texture: Texture2D, stretch_mode: int) -> void:
	_ensure_layers()
	if not UiScale.scale_changed.is_connected(_on_ui_scale_changed):
		UiScale.scale_changed.connect(_on_ui_scale_changed)
	var background_texture := _opaque_background_texture(system_texture)
	if background_texture == null:
		_configure_fallback_styles()
		visible = true
		_apply_physical_styles()
		return
	visible = true
	_background_style = (StyleBoxTexture.new() if stretch_mode != 0
		else preload("res://cogs/system_ui_background.gd").new())
	_background_style.texture = background_texture
	_background_style.region_rect = Rect2(0, 0, 32, 32)
	_border_style = StyleBoxTexture.new()
	_border_style.texture = system_texture
	_border_style.region_rect = Rect2(32, 0, 32, 32)
	_border_style.texture_margin_left = 8.0
	_border_style.texture_margin_top = 8.0
	_border_style.texture_margin_right = 8.0
	_border_style.texture_margin_bottom = 8.0
	_border_style.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
	_border_style.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
	_border_style.draw_center = false
	_border_insets = Vector4(-1, -1, -1, -1)
	_apply_physical_styles()


func _opaque_background_texture(system_texture: Texture2D) -> Texture2D:
	if (system_texture == null or system_texture.get_width() < 64
			or system_texture.get_height() < 32):
		return null
	var source := system_texture.get_image()
	if source == null or source.is_empty():
		return null
	source = source.duplicate() as Image
	if source.is_compressed() and source.decompress() != OK:
		return null
	var background := source.get_region(Rect2i(0, 0, 32, 32))
	background.convert(Image.FORMAT_RGBA8)
	# The bridge returns straight RGBA. Match the native window's black base
	# without changing the shared System texture or its transparent frame.
	for y in 32:
		for x in 32:
			var color := background.get_pixel(x, y)
			background.set_pixel(x, y, Color(
				color.r * color.a, color.g * color.a, color.b * color.a, 1.0))
	return ImageTexture.create_from_image(background)


func _configure_fallback_styles() -> void:
	var background := StyleBoxFlat.new()
	background.bg_color = _FALLBACK_BACKGROUND_COLOR
	_background_style = background

	var border := StyleBoxFlat.new()
	border.bg_color = Color.TRANSPARENT
	border.border_color = _FALLBACK_BORDER_COLOR
	border.border_width_left = 1
	border.border_width_top = 1
	border.border_width_right = 1
	border.border_width_bottom = 1
	border.draw_center = false
	_border_style = border
	_border_insets = Vector4.ONE


func selection_border_style() -> StyleBox:
	return _border_style


func selection_border_insets() -> Vector4:
	if _border_insets.x < 0:
		_border_insets = _measure_border_insets((_border_style as StyleBoxTexture).texture)
	return _border_insets


func _measure_border_insets(texture: Texture2D) -> Vector4:
	var pixels := texture.get_image()
	if pixels.is_compressed():
		pixels.decompress()
	# The 8px nine-slice corners are not the visible straight-edge thickness.
	# Measure only this skin refresh; selection/layout reuses the same result.
	var edges := Vector4.ZERO
	for depth in 8:
		for along in range(8, 24):
			if pixels.get_pixel(32 + depth, along).a > 0.0: edges.x = depth + 1
			if pixels.get_pixel(32 + along, depth).a > 0.0: edges.y = depth + 1
			if pixels.get_pixel(63 - depth, along).a > 0.0: edges.z = depth + 1
			if pixels.get_pixel(32 + along, 31 - depth).a > 0.0: edges.w = depth + 1
	return edges


func _apply_physical_styles() -> void:
	if _background_style != null:
		UiScale.apply_physical_stylebox(
			_background_panel, &"panel", _background_style)
	if _border_style != null:
		UiScale.apply_physical_stylebox(
			_border_panel, &"panel", _border_style)


func _on_ui_scale_changed(_new_scale: float) -> void:
	_apply_physical_styles()


func _ensure_layers() -> void:
	if is_instance_valid(_background_panel) and is_instance_valid(_border_panel):
		return
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_background_panel = Panel.new()
	_background_panel.name = "Background"
	_background_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_background_panel.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(_background_panel)
	_background_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_border_panel = Panel.new()
	_border_panel.name = "Border"
	_border_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_border_panel.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(_border_panel)
	_border_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
