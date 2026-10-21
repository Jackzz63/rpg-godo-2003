class_name WebpageThemeTextRuntime
extends Node

const GAME_UI_FONT := preload("res://resources/webpage_game_ui_font.tres")
const LAUNCHER_FONT := preload("res://resources/launcher_font.tres")
const TextLines := preload("res://cogs/theme_text_lines.gd")
const THEME_TEXT_SHADER := preload("res://resources/webpage_theme_text.gdshader")
const THEME_ICON_SHADER := preload("res://resources/webpage_theme_icon.gdshader")
const SystemThemePaletteScript := preload("res://cogs/system_theme_palette.gd")

const NORMAL_MARKER := Color(1.0, 0.0, 1.0, 1.0)
const STRONG_MARKER := Color(0.0, 1.0, 0.0, 1.0)
const MUTED_MARKER := Color(0.0, 0.0, 1.0, 1.0)
const SHADOW_MARKER := Color(1.0, 0.0, 0.0, 1.0)

const ROLE_NORMAL := 0
const ROLE_STRONG := 1
const ROLE_MUTED := 3
const FALLBACK_NORMAL_COLOR := Color(1.0, 1.0, 1.0, 1.0)
const FALLBACK_STRONG_COLOR := Color(1.0, 1.0, 0.0, 1.0)
const FALLBACK_MUTED_COLOR := Color(0.65, 0.65, 0.65, 1.0)
const FALLBACK_SHADOW_COLOR := Color(0.0, 0.0, 0.0, 1.0)

const _FONT_SIZE := 16
const _COLOR_CELL_SIZE := 16
const _COLOR_SAMPLE_X := 0
const _COLOR_TABLE_Y := 48
const _SHADOW_SAMPLE_X := 16
const _SHADOW_SAMPLE_Y := 40
const _ICON_SIZE_META := "webpage_theme_icon_size"
const _ICON_SOURCE_META := "webpage_theme_icon_source"
const _ICON_RENDERED_META := "webpage_theme_icon_rendered"
const _DESIGN_FONT_SIZES_META := "physical_ui_design_font_sizes"
const _DESIGN_CONSTANTS_META := "physical_ui_design_constants"
const _DPI_ICON_SUPERSAMPLE := 2.0

var _theme_cache: Dictionary = {}
var _scaled_icon_cache: Dictionary = {}
var _registered_icons: Dictionary = {}
var _icon_refresh_queued := false


func _ready() -> void:
	if not UiScale.scale_changed.is_connected(_on_ui_scale_changed):
		UiScale.scale_changed.connect(_on_ui_scale_changed)


func _exit_tree() -> void:
	if UiScale.scale_changed.is_connected(_on_ui_scale_changed):
		UiScale.scale_changed.disconnect(_on_ui_scale_changed)


func _on_ui_scale_changed(_ui_scale: float) -> void:
	_queue_registered_icon_refresh()


func clear_caches() -> void:
	_theme_cache.clear()
	_scaled_icon_cache.clear()


func marker_for_role(role: int) -> Color:
	match role:
		ROLE_STRONG:
			return STRONG_MARKER
		ROLE_MUTED:
			return MUTED_MARKER
		_:
			return NORMAL_MARKER


func role_color(connection: Node, system_name: String, role: int, fallback: Color) -> Color:
	return marker_for_role(role) if not get_theme_data(connection, system_name).is_empty() else fallback


func style_control(
		control: Control,
		connection: Node,
		system_name: String = "",
		role: int = ROLE_NORMAL,
		copy_layer: bool = false) -> bool:
	if not _is_text_control(control):
		return false
	ClientPerformance.count_event(&"ui.text_style_applications")

	_apply_font(control)
	if control is Button:
		style_button(control as Button)
	control.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

	if copy_layer:
		control.material = null
		_apply_colors(
			control, Color(1.0, 1.0, 1.0, 0.0),
			Color(1.0, 1.0, 1.0, 0.0), Color(1.0, 1.0, 1.0, 0.0))
		return true

	var theme_data := get_theme_data(connection, system_name)
	if theme_data.is_empty():
		control.material = null
		if not control.has_theme_color_override("font_color"):
			_apply_colors(
				control, _fallback_color_for_role(role),
				FALLBACK_MUTED_COLOR, FALLBACK_SHADOW_COLOR)
		if _is_chat_shadow_control(control):
			var fallback := ShaderMaterial.new()
			fallback.shader = THEME_TEXT_SHADER
			fallback.set_shader_parameter("use_theme_colors", false)
			fallback.set_shader_parameter("theme_shadow_color", FALLBACK_SHADOW_COLOR)
			control.material = fallback
			# Keep the caller's foreground, selection and placeholder colors.
			_apply_shadow(control, SHADOW_MARKER)
			_install_chat_shadow_clip(control)
			return false
		_apply_shadow(control, FALLBACK_SHADOW_COLOR)
		return false

	control.material = _make_control_material(theme_data, control)
	_bind_control_gradient_refresh(control)
	_apply_colors(control, marker_for_role(role), MUTED_MARKER, SHADOW_MARKER)
	_install_chat_shadow_clip(control)
	return true


func style_button(button: Button) -> void:
	for style_name in [
			"normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
		var source := button.get_theme_stylebox(style_name)
		var empty := StyleBoxEmpty.new()
		if source != null:
			empty.content_margin_left = source.get_content_margin(SIDE_LEFT)
			empty.content_margin_top = source.get_content_margin(SIDE_TOP)
			empty.content_margin_right = source.get_content_margin(SIDE_RIGHT)
			empty.content_margin_bottom = source.get_content_margin(SIDE_BOTTOM)
		button.add_theme_stylebox_override(style_name, empty)


func style_icon(
		control: Control,
		connection: Node,
		system_name: String = "",
		role: int = ROLE_NORMAL,
		stateful_button: bool = false,
		icon_size: float = 0.0,
		draw_shadow: bool = true) -> bool:
	if not (control is TextureRect or control is Button):
		return false
	if control is Button:
		style_button(control as Button)
	control.set_meta(_ICON_SIZE_META, icon_size)
	_register_icon_control(control)
	_refresh_icon_texture(control)

	var theme_data := get_theme_data(connection, system_name)
	if theme_data.is_empty():
		clear_icon_style(control)
		return false

	var material := ShaderMaterial.new()
	material.shader = THEME_ICON_SHADER
	material.set_shader_parameter("normal_strip", theme_data.get("normal_texture"))
	material.set_shader_parameter("strong_strip", theme_data.get("strong_texture"))
	material.set_shader_parameter("muted_strip", theme_data.get("muted_texture"))
	material.set_shader_parameter("theme_shadow_color", theme_data.get("shadow_color"))
	material.set_shader_parameter("draw_shadow", draw_shadow)
	material.set_shader_parameter("fixed_role", -1 if stateful_button else role)
	control.material = material
	control.self_modulate = Color.WHITE
	control.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	if control is Button:
		_apply_button_icon_colors(control as Button)
	_bind_icon_gradient_refresh(control)
	_refresh_icon_gradient(control)
	call_deferred("_refresh_icon_gradient", control)
	return true


func clear_icon_style(control: Control) -> void:
	control.material = null
	control.self_modulate = Color.WHITE
	_register_icon_control(control)
	_refresh_icon_texture(control)
	if control is Button:
		var button := control as Button
		style_button(button)
		for color_name in [
				"icon_normal_color", "icon_hover_color", "icon_pressed_color",
				"icon_hover_pressed_color", "icon_focus_color", "icon_disabled_color"]:
			button.add_theme_color_override(color_name, Color.WHITE)


func style_pixel_texture(
		control: TextureRect,
		connection: Node,
		system_name: String = "",
		role: int = ROLE_NORMAL,
		draw_shadow: bool = true) -> bool:
	if not is_instance_valid(control) or control.texture == null:
		return false
	var theme_data := get_theme_data(connection, system_name)
	if theme_data.is_empty():
		control.material = null
		control.self_modulate = Color.WHITE
		control.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		return false
	var material := ShaderMaterial.new()
	material.shader = THEME_ICON_SHADER
	material.set_shader_parameter("normal_strip", theme_data.get("normal_texture"))
	material.set_shader_parameter("strong_strip", theme_data.get("strong_texture"))
	material.set_shader_parameter("muted_strip", theme_data.get("muted_texture"))
	material.set_shader_parameter("theme_shadow_color", theme_data.get("shadow_color"))
	material.set_shader_parameter("draw_shadow", draw_shadow)
	material.set_shader_parameter("fixed_role", role)
	material.set_shader_parameter("gradient_origin_y", 0.0)
	material.set_shader_parameter("gradient_height", maxf(control.size.y, 1.0))
	var texture_size := control.texture.get_size()
	material.set_shader_parameter("shadow_uv_offset", Vector2(
		1.0 / maxf(texture_size.x, 1.0),
		1.0 / maxf(texture_size.y, 1.0)))
	control.material = material
	control.self_modulate = Color.WHITE
	control.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	return true


func make_text_glyph_icon(
		source_texture: Texture2D,
		connection: Node,
		system_name: String = "",
		role: int = ROLE_NORMAL,
		icon_size: int = 14,
		line_height: int = 16) -> Control:
	var resolved_icon_size := maxi(1, icon_size)
	var resolved_line_height := maxi(resolved_icon_size + 2, line_height)
	var inset := (resolved_line_height - resolved_icon_size) * 0.5
	var rendered_source := source_texture
	if source_texture is DPITexture:
		rendered_source = _target_dpi_icon_texture(
			source_texture as DPITexture,
			UiScale.physical_size(Vector2i(resolved_icon_size, resolved_icon_size)))
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(resolved_line_height, resolved_line_height)
	holder.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	holder.mouse_filter = Control.MOUSE_FILTER_PASS
	holder.clip_contents = true

	var theme_data := get_theme_data(connection, system_name)
	var material: ShaderMaterial = null
	if not theme_data.is_empty():
		var template := theme_data.get("material") as ShaderMaterial
		if template != null:
			material = template.duplicate() as ShaderMaterial
			material.set_shader_parameter(
				"gradient_origin_y", -UiScale.physical_value(inset))
			material.set_shader_parameter(
				"gradient_height", UiScale.physical_value(float(resolved_line_height)))

	var shadow := _make_text_glyph_icon_layer(
		rendered_source,
		Vector2(inset + 1.0, inset + 1.0),
		resolved_icon_size,
		SHADOW_MARKER if material != null else FALLBACK_SHADOW_COLOR,
		material)
	holder.add_child(shadow)
	var foreground := _make_text_glyph_icon_layer(
		rendered_source,
		Vector2(inset, inset),
		resolved_icon_size,
		marker_for_role(role) if material != null else Color.WHITE,
		material)
	holder.add_child(foreground)
	return holder


static func make_dpi_icon_texture(
		source_texture: Texture2D,
		target_size: Vector2i) -> Texture2D:
	if source_texture == null:
		return null
	if not source_texture is DPITexture:
		return source_texture
	var safe_size := Vector2i(maxi(target_size.x, 1), maxi(target_size.y, 1))
	var dpi_source := source_texture as DPITexture
	var source_svg := dpi_source.get_source()
	var source_size := Vector2(dpi_source.get_width(), dpi_source.get_height())
	if source_svg.is_empty() or source_size.x <= 0.0 or source_size.y <= 0.0:
		return source_texture
	var fit_scale := minf(
		float(safe_size.x) / source_size.x,
		float(safe_size.y) / source_size.y)
	var rendered := DPITexture.create_from_string(
		source_svg,
		dpi_source.base_scale * fit_scale * _DPI_ICON_SUPERSAMPLE,
		dpi_source.saturation,
		dpi_source.color_map)
	if rendered == null:
		return source_texture
	rendered.set_size_override(safe_size)
	return rendered


func _target_dpi_icon_texture(
		source_texture: DPITexture,
		target_size: Vector2i) -> Texture2D:
	if source_texture == null:
		return null
	var safe_size := Vector2i(maxi(target_size.x, 1), maxi(target_size.y, 1))
	var cache_key := "dpi:%d:%dx%d:%d" % [
		source_texture.get_instance_id(),
		safe_size.x,
		safe_size.y,
		int(round(_DPI_ICON_SUPERSAMPLE * 100.0))]
	if _scaled_icon_cache.has(cache_key):
		return _scaled_icon_cache[cache_key]
	var texture := make_dpi_icon_texture(source_texture, safe_size)
	_scaled_icon_cache[cache_key] = texture
	return texture


func _scaled_icon_texture(source_texture: Texture2D, target_size: Vector2i) -> Texture2D:
	if source_texture == null:
		return null
	var safe_size := Vector2i(maxi(target_size.x, 1), maxi(target_size.y, 1))
	var cache_key := "bitmap:%d:%dx%d" % [
		source_texture.get_instance_id(), safe_size.x, safe_size.y]
	if _scaled_icon_cache.has(cache_key):
		return _scaled_icon_cache[cache_key]
	var image := source_texture.get_image()
	if image == null or image.is_empty():
		return source_texture
	if image.has_mipmaps():
		image.clear_mipmaps()
	image.resize(safe_size.x, safe_size.y, Image.INTERPOLATE_LANCZOS)
	var texture := ImageTexture.create_from_image(image)
	_scaled_icon_cache[cache_key] = texture
	return texture


func _make_text_glyph_icon_layer(
		texture: Texture2D,
		layer_position: Vector2,
		icon_size: int,
		marker: Color,
		material: ShaderMaterial) -> TextureRect:
	var layer := TextureRect.new()
	layer.texture = texture
	layer.position = layer_position
	layer.size = Vector2(icon_size, icon_size)
	layer.custom_minimum_size = Vector2(icon_size, icon_size)
	layer.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	layer.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	layer.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.self_modulate = marker
	layer.material = material
	call_deferred(
		"_lock_text_glyph_icon_layer_rect",
		layer, layer_position, Vector2(icon_size, icon_size))
	return layer


func _lock_text_glyph_icon_layer_rect(
		layer: Variant, layer_position: Vector2, layer_size: Vector2) -> void:
	if not is_instance_valid(layer):
		return
	layer.position = layer_position
	layer.size = layer_size


func get_theme_data(connection: Node, system_name: String = "") -> Dictionary:
	if connection == null or not connection.has_method("get_menu_system_texture"):
		return {}

	var resolved_name := _resolve_system_name(connection, system_name)
	var cache_key := "%s:%s" % [connection.get_instance_id(), resolved_name]
	if _theme_cache.has(cache_key):
		return _theme_cache[cache_key]

	var texture: Variant = connection.call("get_menu_system_texture", resolved_name)
	if not texture is Texture2D:
		return {}
	var image := (texture as Texture2D).get_image()
	if image == null or image.is_empty():
		return {}

	var theme_data := build_theme_data_from_image(image)
	if theme_data.is_empty():
		return {}
	theme_data["material"] = _make_material(theme_data)
	_theme_cache[cache_key] = theme_data
	return theme_data


func build_theme_data_from_image(image: Image) -> Dictionary:
	if image == null or image.is_empty():
		return {}
	if (image.get_width() < (_COLOR_CELL_SIZE * 4)
			or image.get_height() < (_COLOR_TABLE_Y + _COLOR_CELL_SIZE)):
		return {}

	# WEBPAGE samples fontshadow.png at (0, 8). That image is the system
	# graphic's 16x16 shadow swatch cropped from (16, 32), so (16, 40)
	# is the exact equivalent while keeping this client fully offline.
	var shadow := _opaque(image.get_pixel(_SHADOW_SAMPLE_X, _SHADOW_SAMPLE_Y))
	var normal_colors := _read_strip(image, 0)
	var alternate_colors := _read_strip(image, 1)
	var muted_colors := _read_strip(image, 3)
	var strong_colors: Array[Color] = alternate_colors
	var strong_index := 1

	if SystemThemePaletteScript.strong_style_index(image) == 3:
		strong_colors = muted_colors
		strong_index = 3

	return {
		"normal_texture": _strip_texture(normal_colors),
		"strong_texture": _strip_texture(strong_colors),
		"muted_texture": _strip_texture(muted_colors),
		"normal_colors": normal_colors,
		"strong_colors": strong_colors,
		"muted_colors": muted_colors,
		"normal_color": normal_colors[8],
		"strong_color": strong_colors[8],
		"muted_color": muted_colors[8],
		"shadow_color": shadow,
		"strong_index": strong_index,
	}


func _fallback_color_for_role(role: int) -> Color:
	match role:
		ROLE_STRONG:
			return FALLBACK_STRONG_COLOR
		ROLE_MUTED:
			return FALLBACK_MUTED_COLOR
		_:
			return FALLBACK_NORMAL_COLOR


func _resolve_system_name(connection: Node, system_name: String) -> String:
	if not system_name.is_empty():
		return system_name
	if connection != null and connection.has_method("get_local_player_snapshot"):
		var snapshot: Variant = connection.call("get_local_player_snapshot")
		if snapshot is Dictionary:
			return str(snapshot.get("system_name", ""))
	return ""


func _read_strip(image: Image, style_index: int) -> Array[Color]:
	var colors: Array[Color] = []
	var x := (style_index * _COLOR_CELL_SIZE) + _COLOR_SAMPLE_X
	for row in range(_COLOR_CELL_SIZE):
		colors.append(_opaque(image.get_pixel(x, _COLOR_TABLE_Y + row)))
	return colors


func _same_strip(first: Array[Color], second: Array[Color]) -> bool:
	if first.size() != second.size():
		return false
	for index in range(first.size()):
		if not _same_rgb(first[index], second[index]):
			return false
	return true


func _strip_texture(colors: Array[Color]) -> ImageTexture:
	var image := Image.create(1, _COLOR_CELL_SIZE, false, Image.FORMAT_RGBA8)
	for row in range(_COLOR_CELL_SIZE):
		image.set_pixel(0, row, _quantize(colors[row]))
	return ImageTexture.create_from_image(image)


func _make_material(theme_data: Dictionary) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = THEME_TEXT_SHADER
	material.set_shader_parameter("normal_strip", theme_data.get("normal_texture"))
	material.set_shader_parameter("strong_strip", theme_data.get("strong_texture"))
	material.set_shader_parameter("muted_strip", theme_data.get("muted_texture"))
	material.set_shader_parameter("theme_shadow_color", theme_data.get("shadow_color"))
	return material


func _make_control_material(theme_data: Dictionary, control: Control) -> ShaderMaterial:
	var template := theme_data.get("material") as ShaderMaterial
	if template == null:
		return null
	var material := template.duplicate() as ShaderMaterial
	material.set_shader_parameter("gradient_origin_y", 0.0)
	material.set_shader_parameter("gradient_height", _control_gradient_height(control))
	ClientPerformance.count_event(&"ui.text_materials_created")
	return material


func _bind_icon_gradient_refresh(control: Control) -> void:
	if control.has_meta("webpage_theme_icon_gradient_refresh_bound"):
		return
	control.set_meta("webpage_theme_icon_gradient_refresh_bound", true)
	control.resized.connect(_refresh_icon_rendering.bind(control))


func _register_icon_control(control: Control) -> void:
	if not is_instance_valid(control):
		return
	_registered_icons[control.get_instance_id()] = weakref(control)


func _queue_registered_icon_refresh() -> void:
	if _icon_refresh_queued:
		return
	_icon_refresh_queued = true
	call_deferred("_refresh_registered_icons")


func _refresh_registered_icons() -> void:
	_icon_refresh_queued = false
	_scaled_icon_cache.clear()
	for instance_id in _registered_icons.keys():
		var reference := _registered_icons.get(instance_id) as WeakRef
		var object: Object = reference.get_ref() if reference != null else null
		if not object is Control or not is_instance_valid(object):
			_registered_icons.erase(instance_id)
			continue
		_refresh_icon_rendering(object as Control)


func _refresh_icon_rendering(control: Control) -> void:
	if not is_instance_valid(control):
		return
	_refresh_icon_texture(control)
	_refresh_icon_gradient(control)


func _refresh_icon_texture(control: Control) -> void:
	var source_texture := _capture_icon_source(control)
	if source_texture == null:
		return
	var logical_size := _requested_icon_size(control)
	var rendered_texture: Texture2D
	if source_texture is DPITexture:
		rendered_texture = _target_dpi_icon_texture(
			source_texture as DPITexture,
			_physical_icon_size(control, logical_size))
	else:
		var target_size := _physical_icon_size(control, logical_size)
		rendered_texture = _scaled_icon_texture(source_texture, target_size)
	control.set_meta(_ICON_RENDERED_META, rendered_texture)
	_set_control_icon_texture(control, rendered_texture)
	control.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR


func _capture_icon_source(control: Control) -> Texture2D:
	var current_texture := _get_control_icon_texture(control)
	var rendered_texture: Texture2D = null
	if control.has_meta(_ICON_RENDERED_META):
		rendered_texture = control.get_meta(_ICON_RENDERED_META) as Texture2D
	if current_texture != null and current_texture != rendered_texture:
		control.set_meta(_ICON_SOURCE_META, current_texture)
	if control.has_meta(_ICON_SOURCE_META):
		return control.get_meta(_ICON_SOURCE_META) as Texture2D
	return null


func _get_control_icon_texture(control: Control) -> Texture2D:
	if control is TextureRect:
		return (control as TextureRect).texture
	if control is Button:
		return (control as Button).icon
	return null


func _set_control_icon_texture(control: Control, texture: Texture2D) -> void:
	if control is TextureRect:
		(control as TextureRect).texture = texture
	elif control is Button:
		(control as Button).icon = texture


func _requested_icon_size(control: Control) -> float:
	var requested_size := float(control.get_meta(_ICON_SIZE_META, 0.0))
	if requested_size > 0.0:
		return requested_size
	if control is Button:
		requested_size = float(control.get_theme_constant("icon_max_width"))
	if requested_size <= 0.0:
		requested_size = minf(control.size.x, control.size.y)
	if requested_size <= 0.0:
		requested_size = minf(
			control.custom_minimum_size.x, control.custom_minimum_size.y)
	return maxf(requested_size, 1.0)


func _physical_icon_size(control: Control, logical_size: float) -> Vector2i:
	var physical_size := maxi(1, int(round(logical_size * UiScale.get_ui_scale())))
	return Vector2i(physical_size, physical_size)


func _refresh_icon_gradient(control: Variant) -> void:
	if not is_instance_valid(control):
		return
	var material := control.material as ShaderMaterial
	if material == null or material.shader != THEME_ICON_SHADER:
		return
	var requested_size := float(control.get_meta(_ICON_SIZE_META, 0.0))
	var rendered_size := UiScale.physical_value(requested_size)
	if rendered_size <= 0.0:
		rendered_size = minf(control.size.x, control.size.y)
	if rendered_size <= 0.0:
		rendered_size = _COLOR_CELL_SIZE
	material.set_shader_parameter(
		"gradient_origin_y", maxf((control.size.y - rendered_size) * 0.5, 0.0))
	material.set_shader_parameter("gradient_height", rendered_size)
	material.set_shader_parameter(
		"shadow_uv_offset", Vector2.ONE / maxf(rendered_size, 1.0))


func _bind_control_gradient_refresh(control: Control) -> void:
	TextLines.install(control)


func _is_chat_shadow_control(control: Control) -> bool:
	return control is LineEdit and control.is_in_group("rpg_godo_chat_input")


func _install_chat_shadow_clip(control: Control) -> void:
	if not _is_chat_shadow_control(control):
		return
	var refresh := _refresh_chat_shadow_clip.bind(control)
	if not control.draw.is_connected(refresh):
		control.draw.connect(refresh)
	_refresh_chat_shadow_clip(control)


func _refresh_chat_shadow_clip(field: LineEdit) -> void:
	var material := field.material as ShaderMaterial
	if material == null or material.shader != THEME_TEXT_SHADER:
		return
	var style := field.get_theme_stylebox("normal" if field.editable else "read_only")
	# Match LineEdit's integer content bounds. No extra UI-scale conversion:
	# the StyleBox margins and control width are already in drawing coordinates.
	var bounds := Vector2(int(style.get_margin(SIDE_LEFT)),
		int(int(field.size.x) - style.get_margin(SIDE_RIGHT)))
	material.set_shader_parameter("clip_shadow", true)
	if material.get_shader_parameter("shadow_clip_x") != bounds:
		material.set_shader_parameter("shadow_clip_x", bounds)


func _refresh_control_gradient(control: Control) -> void:
	if not is_instance_valid(control):
		return
	TextLines.install(control)


func _control_gradient_height(control: Control) -> float:
	if control.size.y > 0.0:
		return control.size.y
	var font_size := control.get_theme_font_size("font_size")
	if control is RichTextLabel:
		font_size = control.get_theme_font_size("normal_font_size")
	if font_size <= 0:
		font_size = _FONT_SIZE
	return maxf(GAME_UI_FONT.get_height(font_size), 1.0)


func _is_text_control(control: Control) -> bool:
	if control is Label or control is RichTextLabel or control is LineEdit or control is TextEdit:
		return true
	return control is Button and not (control as Button).text.is_empty()


func _apply_font(control: Control) -> void:
	var font_size := UiScale.physical_font_size(_FONT_SIZE)
	var font: Font = LAUNCHER_FONT if control.get_meta("webpage_launcher_font", false) else GAME_UI_FONT
	if control is RichTextLabel:
		for font_name in ["normal_font", "bold_font", "italics_font", "bold_italics_font", "mono_font"]:
			control.add_theme_font_override(font_name, font)
		for size_name in ["normal_font_size", "bold_font_size", "italics_font_size", "bold_italics_font_size", "mono_font_size"]:
			_record_design_value(control, _DESIGN_FONT_SIZES_META, size_name, _FONT_SIZE)
			control.add_theme_font_size_override(size_name, font_size)
	else:
		control.add_theme_font_override("font", font)
		_record_design_value(control, _DESIGN_FONT_SIZES_META, "font_size", _FONT_SIZE)
		control.add_theme_font_size_override("font_size", font_size)
	UiScale.apply_control(control)


func _apply_colors(control: Control, normal: Color, disabled: Color, shadow: Color) -> void:
	if control is RichTextLabel:
		control.add_theme_color_override("default_color", normal)
	elif control is Button:
		_apply_button_text_colors(control as Button, normal)
	else:
		for color_name in [
				"font_color", "font_hover_color", "font_pressed_color",
				"font_focus_color", "font_hover_pressed_color", "font_selected_color",
				"font_uneditable_color", "font_placeholder_color"]:
			control.add_theme_color_override(color_name, normal)
		control.add_theme_color_override("font_disabled_color", disabled)
	_apply_shadow(control, shadow)


func _apply_shadow(control: Control, shadow: Color) -> void:
	control.add_theme_color_override("font_shadow_color", shadow)
	control.add_theme_color_override("font_outline_color", Color.TRANSPARENT)
	_record_design_value(control, _DESIGN_CONSTANTS_META, "shadow_offset_x", 1)
	_record_design_value(control, _DESIGN_CONSTANTS_META, "shadow_offset_y", 1)
	_record_design_value(control, _DESIGN_CONSTANTS_META, "shadow_outline_size", 0)
	_record_design_value(control, _DESIGN_CONSTANTS_META, "outline_size", 0)
	control.add_theme_constant_override("shadow_offset_x", UiScale.physical_int(1.0))
	control.add_theme_constant_override("shadow_offset_y", UiScale.physical_int(1.0))
	control.add_theme_constant_override("shadow_outline_size", 0)
	control.add_theme_constant_override("outline_size", 0)


func _record_design_value(
		control: Control, metadata_name: StringName,
		item_name: StringName, value: int) -> void:
	var values: Dictionary = control.get_meta(metadata_name, {})
	values[item_name] = value
	control.set_meta(metadata_name, values)


func _apply_button_text_colors(button: Button, normal: Color) -> void:
	for color_name in ["font_color", "font_hover_color", "font_focus_color"]:
		button.add_theme_color_override(color_name, normal)
	for color_name in ["font_pressed_color", "font_hover_pressed_color", "font_selected_color"]:
		button.add_theme_color_override(color_name, STRONG_MARKER)
	button.add_theme_color_override("font_disabled_color", MUTED_MARKER)


func _apply_button_icon_colors(button: Button) -> void:
	for color_name in ["icon_normal_color", "icon_hover_color", "icon_focus_color"]:
		button.add_theme_color_override(color_name, NORMAL_MARKER)
	for color_name in ["icon_pressed_color", "icon_hover_pressed_color"]:
		button.add_theme_color_override(color_name, STRONG_MARKER)
	button.add_theme_color_override("icon_disabled_color", MUTED_MARKER)


func _opaque(color: Color) -> Color:
	return Color(color.r, color.g, color.b, 1.0)


func _quantize(color: Color) -> Color:
	return Color(
		round(color.r * 255.0) / 255.0,
		round(color.g * 255.0) / 255.0,
		round(color.b * 255.0) / 255.0,
		1.0)


func _same_rgb(first: Color, second: Color) -> bool:
	return _quantize(first).to_html(false) == _quantize(second).to_html(false)
