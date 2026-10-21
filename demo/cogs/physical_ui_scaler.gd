extends Node

signal scale_changed(ui_scale: float)
signal safe_area_changed()

const DESIGN_SIZE := Vector2(640.0, 480.0)
const META_ROOT := &"physical_ui_scale_root"
const META_EXTERNAL_SCALE := &"ui_scale_managed_externally"
const META_SKIP_GEOMETRY := &"physical_ui_scale_geometry_is_physical"
const META_SKIP_STYLES := &"physical_ui_scale_styles_are_physical"
const META_BASE := &"physical_ui_scale_base"
const META_DESIGN_FONT_SIZES := &"physical_ui_design_font_sizes"
const META_DESIGN_CONSTANTS := &"physical_ui_design_constants"
const META_DECLARED_OVERRIDES := &"physical_ui_declared_overrides"
const META_SPIN_BUTTON_MINIMUM := &"physical_ui_spin_button_minimum"
var _ui_scale := 1.0
var _interface_multiplier := 1.0
var _orientation_independent := false
var _refresh_queued := false
var _added_pending: Dictionary = {}
var _icon_cache: Dictionary = {}
var _safe_area := Rect2() # Root viewport coordinates; empty means unrestricted.
var _corner_top_insets := Vector2.ZERO


func set_corner_top_insets(insets: Vector2) -> void:
	if _corner_top_insets.is_equal_approx(insets):
		return
	_corner_top_insets = insets
	safe_area_changed.emit()


func corner_top_inset(right: bool) -> float:
	return _corner_top_insets.y if right else _corner_top_insets.x


func set_safe_area(rect: Rect2) -> void:
	if _safe_area.is_equal_approx(rect):
		return
	_safe_area = rect
	safe_area_changed.emit()


func safe_rect_for(viewport: Viewport) -> Rect2:
	var bounds := viewport.get_visible_rect()
	if not _safe_area.has_area():
		return bounds
	var transform := viewport.get_screen_transform().affine_inverse() * get_tree().root.get_screen_transform()
	return bounds.intersection(transform * _safe_area)


func _enter_tree() -> void:
	var root := get_tree().root
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_factor = 1.0
	_ui_scale = scale_for_size(root.size)
	if not root.size_changed.is_connected(_on_root_size_changed):
		root.size_changed.connect(_on_root_size_changed)
	if not get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.connect(_on_node_added)
	_queue_refresh_all()


func _exit_tree() -> void:
	var root := get_tree().root
	if root.size_changed.is_connected(_on_root_size_changed):
		root.size_changed.disconnect(_on_root_size_changed)
	if get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)


func get_ui_scale() -> float:
	return _ui_scale


func scale_for_size(size: Vector2i) -> float:
	if size.x <= 0 or size.y <= 0:
		return 1.0
	if _orientation_independent:
		return maxf(minf(float(maxi(size.x, size.y)) / DESIGN_SIZE.x,
			float(mini(size.x, size.y)) / DESIGN_SIZE.y), 0.01)
	return maxf(
		minf(float(size.x) / DESIGN_SIZE.x, float(size.y) / DESIGN_SIZE.y),
		0.01)


func set_orientation_independent(value: bool) -> void:
	if _orientation_independent == value:
		return
	_orientation_independent = value
	_on_root_size_changed()


func physical_value(design_value: float) -> float:
	return design_value * _ui_scale


func physical_int(design_value: float) -> int:
	if is_zero_approx(design_value):
		return 0
	var resolved := int(round(design_value * _ui_scale))
	if design_value > 0.0:
		return maxi(1, resolved)
	return mini(-1, resolved)


func physical_size(design_size: Vector2i) -> Vector2i:
	return Vector2i(
		physical_int(float(design_size.x)),
		physical_int(float(design_size.y)))


func physical_font_size(design_size: int) -> int:
	return maxi(1, int(round(float(design_size) * _ui_scale)))


func set_interface_multiplier(value: float) -> void:
	# A platform may enlarge the complete in-game UI. Base design values stay
	# captured once, so fonts, icons, styles and geometry use the same factor.
	if is_equal_approx(_interface_multiplier, value):
		return
	_interface_multiplier = value
	_on_root_size_changed()


func mark_geometry_physical(control: Control) -> void:
	if is_instance_valid(control):
		control.set_meta(META_SKIP_GEOMETRY, true)


func mark_styles_physical(control: Control) -> void:
	if not is_instance_valid(control):
		return
	control.set_meta(META_SKIP_STYLES, true)
	if control.has_meta(META_BASE):
		var base: Dictionary = control.get_meta(META_BASE, {})
		base["styles"] = {}
		control.set_meta(META_BASE, base)


func apply_physical_stylebox(
	control: Control,
	style_name: StringName,
	source: StyleBox,
	target_texture_margin: float = -1.0
) -> void:
	if not is_instance_valid(control) or source == null:
		return
	mark_styles_physical(control)
	control.add_theme_stylebox_override(
		style_name, physical_stylebox(source, target_texture_margin))


func apply_control(control: Control) -> void:
	if not is_instance_valid(control) or not _is_managed_control(control):
		return
	_added_pending.erase(control.get_instance_id())
	_capture_control(control)
	var perf_start := ClientPerformance.begin()
	_apply_control(control)
	# SpinBox's LineEdit is an internal child, absent from ordinary subtree walks.
	if control is SpinBox:
		# SpinBox lays out its editor around the buttons. Do not scale its offsets again.
		mark_geometry_physical(control.get_line_edit())
		apply_control(control.get_line_edit())
	if control is ScrollContainer or control is TextEdit:
		for bar: ScrollBar in [control.get_h_scroll_bar(), control.get_v_scroll_bar()]:
			mark_geometry_physical(bar)
			apply_control(bar)
	ClientPerformance.end(&"ui.scale_apply", perf_start)


# Opt-in for programmatically constructed controls whose override names are known.
# Values and geometry are still captured on adoption, after construction finishes.
# Undeclared controls keep the generic property scan, including custom themes.
func declare_control_overrides(
		control: Control, constants: PackedStringArray, styles: PackedStringArray) -> void:
	control.set_meta(META_DECLARED_OVERRIDES, {"constants": constants, "styles": styles})


func _on_root_size_changed() -> void:
	var next_scale := scale_for_size(get_tree().root.size) * _interface_multiplier
	if is_equal_approx(next_scale, _ui_scale):
		return
	_ui_scale = next_scale
	_queue_refresh_all()


func _on_node_added(node: Node) -> void:
	if node is Control:
		var id := node.get_instance_id()
		_added_pending[id] = true
		call_deferred("_apply_added_node", id)


func _apply_added_node(id: int) -> void:
	if not _added_pending.erase(id):
		return
	var node := instance_from_id(id) as Node
	if not is_instance_valid(node) or not node.is_inside_tree() or node.is_queued_for_deletion():
		return
	if node is Control:
		var perf_start := ClientPerformance.begin()
		apply_control(node as Control)
		ClientPerformance.end(&"ui.added_node_scale", perf_start)


func _queue_refresh_all() -> void:
	if _refresh_queued:
		return
	_refresh_queued = true
	call_deferred("_refresh_all")


func _refresh_all() -> void:
	_refresh_queued = false
	_icon_cache.clear()
	_apply_subtree(get_tree().root)
	scale_changed.emit(_ui_scale)


func _apply_subtree(node: Node) -> void:
	if node is Control:
		apply_control(node as Control)
	for child in node.get_children():
		_apply_subtree(child)


func _is_managed_control(control: Control) -> bool:
	var current: Node = control
	while current != null:
		# Platform UI can resolve its own density-based dimensions once.
		if bool(current.get_meta(META_EXTERNAL_SCALE, false)):
			return false
		if bool(current.get_meta(META_ROOT, false)):
			return true
		current = current.get_parent()
	return false


func _capture_control(control: Control) -> void:
	if control.has_meta(META_BASE):
		return
	var perf_start := ClientPerformance.begin()
	var base := {
		"offsets": Vector4(
			control.offset_left,
			control.offset_top,
			control.offset_right,
			control.offset_bottom),
		"custom_minimum_size": control.custom_minimum_size,
		"pivot_offset": control.pivot_offset,
		"container_managed": control.get_parent() is Container,
		"font_sizes": _capture_font_sizes(control),
		"constants": {},
		"styles": {},
		"icons": {},
		"theme": null,
	}
	var design_constants: Dictionary = control.get_meta(META_DESIGN_CONSTANTS, {})
	var styles_are_physical := bool(control.get_meta(META_SKIP_STYLES, false))
	var constants: Dictionary = base["constants"]
	var styles: Dictionary = base["styles"]
	var property_names: PackedStringArray = []
	if control.has_meta(META_DECLARED_OVERRIDES):
		var declared: Dictionary = control.get_meta(META_DECLARED_OVERRIDES)
		for constant_name in declared.constants:
			property_names.append("theme_override_constants/" + constant_name)
		for style_name in declared.styles:
			property_names.append("theme_override_styles/" + style_name)
		ClientPerformance.count_event(&"ui.scale_declared_captures")
	else:
		for property_data in control.get_property_list():
			var property_name := str(property_data.get("name", ""))
			if (property_name.begins_with("theme_override_constants/")
					or property_name.begins_with("theme_override_styles/")):
				property_names.append(property_name)
		ClientPerformance.count_event(&"ui.scale_generic_captures")
	for property_name in property_names:
		if property_name.begins_with("theme_override_constants/"):
			var constant_name := StringName(property_name.get_slice("/", 1))
			var raw_value: Variant = control.get(property_name)
			if typeof(raw_value) != TYPE_INT and typeof(raw_value) != TYPE_FLOAT:
				continue
			var value := int(raw_value)
			var design_value: Variant = design_constants.get(constant_name, value)
			if typeof(design_value) != TYPE_INT and typeof(design_value) != TYPE_FLOAT:
				design_value = value
			constants[constant_name] = int(design_value)
		elif property_name.begins_with("theme_override_styles/"):
			if styles_are_physical:
				continue
			var style_name := StringName(property_name.get_slice("/", 1))
			var style := control.get(property_name) as StyleBox
			if style != null:
				styles[style_name] = style.duplicate(true)
	if control.theme != null:
		base["theme"] = control.theme.duplicate(true)
	_capture_builtin_parts(control, base)
	control.set_meta(META_BASE, base)
	ClientPerformance.end(&"ui.scale_capture", perf_start)


func _capture_builtin_parts(control: Control, base: Dictionary) -> void:
	# Capture original resources once. Buttons with app-owned SVGs, checkboxes,
	# sliders and externally scaled menus keep their existing owners.
	var icons: Array[StringName] = []
	var constants: Array[StringName] = []
	if control is OptionButton:
		icons = [&"arrow"]
		constants = [&"arrow_margin", &"h_separation"]
	elif control is SpinBox:
		icons = [&"up", &"up_hover", &"up_pressed", &"up_disabled",
			&"down", &"down_hover", &"down_pressed", &"down_disabled", &"updown"]
		constants = [&"buttons_width", &"field_and_buttons_separation", &"buttons_vertical_separation"]
	elif control is ScrollBar and not bool(control.get_meta(META_SKIP_STYLES, false)):
		for style_name in [&"scroll", &"scroll_focus", &"grabber", &"grabber_highlight", &"grabber_pressed"]:
			if not base.styles.has(style_name):
				base.styles[style_name] = control.get_theme_stylebox(style_name).duplicate(true)
	for icon_name in icons:
		if control.has_theme_icon(icon_name):
			base.icons[icon_name] = control.get_theme_icon(icon_name)
	for constant_name in constants:
		if not base.constants.has(constant_name) and control.has_theme_constant(constant_name):
			base.constants[constant_name] = control.get_theme_constant(constant_name)


func _scaled_icon(source: Texture2D) -> Texture2D:
	var key := source.get_instance_id()
	if _icon_cache.has(key):
		return _icon_cache[key]
	var pixels := source.get_image()
	if pixels == null or pixels.is_empty():
		return source
	pixels = pixels.duplicate()
	pixels.resize(maxi(1, roundi(source.get_width() * _ui_scale)),
		maxi(1, roundi(source.get_height() * _ui_scale)), Image.INTERPOLATE_NEAREST)
	var result := ImageTexture.create_from_image(pixels)
	_icon_cache[key] = result
	return result


func _capture_font_sizes(control: Control) -> Dictionary:
	var captured := {}
	var design_sizes: Dictionary = control.get_meta(META_DESIGN_FONT_SIZES, {})
	for font_size_name in _font_size_names(control):
		var resolved := control.get_theme_font_size(font_size_name)
		if resolved > 0:
			captured[font_size_name] = int(design_sizes.get(font_size_name, resolved))
	return captured


func _font_size_names(control: Control) -> Array[StringName]:
	if control is RichTextLabel:
		return [
			&"normal_font_size", &"bold_font_size", &"italics_font_size",
			&"bold_italics_font_size", &"mono_font_size"]
	if (control is Label or control is LineEdit or control is TextEdit
			or control is Button or control is ItemList or control is Tree):
		return [&"font_size"]
	return []


func _apply_control(control: Control) -> void:
	var base: Dictionary = control.get_meta(META_BASE, {})
	if base.is_empty():
		return
	if not bool(control.get_meta(META_SKIP_GEOMETRY, false)):
		var minimum: Vector2 = base.get("custom_minimum_size", Vector2.ZERO)
		control.custom_minimum_size = minimum * _ui_scale
		control.pivot_offset = Vector2(base.get("pivot_offset", Vector2.ZERO)) * _ui_scale
		if not bool(base.get("container_managed", false)):
			var offsets: Vector4 = base.get("offsets", Vector4.ZERO)
			control.offset_left = offsets.x * _ui_scale
			control.offset_top = offsets.y * _ui_scale
			control.offset_right = offsets.z * _ui_scale
			control.offset_bottom = offsets.w * _ui_scale
	var base_theme := base.get("theme") as Theme
	if base_theme != null:
		control.theme = _scaled_theme(base_theme)
	control.begin_bulk_theme_override()
	for constant_name in (base.get("constants", {}) as Dictionary):
		var value := int(base["constants"][constant_name])
		# SpinBox uses -1 for automatic button width, not a negative pixel size.
		if control is SpinBox and constant_name == &"buttons_width" and value < 0:
			control.add_theme_constant_override(constant_name, value)
			continue
		control.add_theme_constant_override(
			constant_name,
			_scale_signed_int(value))
	for icon_name in base.get("icons", {}):
		control.add_theme_icon_override(icon_name, _scaled_icon(base.icons[icon_name]))
	if control is SpinBox and control.has_meta(META_SPIN_BUTTON_MINIMUM):
		var measure: Callable = control.get_meta(META_SPIN_BUTTON_MINIMUM)
		var button_minimum: Vector2 = measure.call()
		control.add_theme_constant_override("buttons_width",
			maxi(control.get_theme_constant("buttons_width"), ceili(button_minimum.x)))
		control.custom_minimum_size.y = maxf(control.custom_minimum_size.y, button_minimum.y * 2.0)
	if not bool(control.get_meta(META_SKIP_STYLES, false)):
		for style_name in (base.get("styles", {}) as Dictionary):
			var style := base["styles"][style_name] as StyleBox
			if style != null:
				control.add_theme_stylebox_override(style_name, _scaled_stylebox(style))
	for font_size_name in (base.get("font_sizes", {}) as Dictionary):
		control.add_theme_font_size_override(
			font_size_name,
			physical_font_size(int(base["font_sizes"][font_size_name])))
	control.end_bulk_theme_override()


func _scale_signed_int(value: int, density := -1.0) -> int:
	if value == 0:
		return 0
	var resolved := int(round(float(value) * (_ui_scale if density < 0 else density)))
	return maxi(1, resolved) if value > 0 else mini(-1, resolved)


func _scale_margin(value: float, density := -1.0) -> float:
	return value * (_ui_scale if density < 0 else density) if value >= 0.0 else value


func _scaled_stylebox(
	source: StyleBox,
	target_texture_margin: float = -1.0,
	density: float = -1.0
) -> StyleBox:
	if density < 0:
		density = _ui_scale
	var result := source.duplicate(true) as StyleBox
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		result.set_content_margin(
			side, _scale_margin(source.get_content_margin(side), density))
	if source is StyleBoxFlat and result is StyleBoxFlat:
		var source_flat := source as StyleBoxFlat
		var target_flat := result as StyleBoxFlat
		target_flat.border_width_left = _scale_signed_int(source_flat.border_width_left, density)
		target_flat.border_width_top = _scale_signed_int(source_flat.border_width_top, density)
		target_flat.border_width_right = _scale_signed_int(source_flat.border_width_right, density)
		target_flat.border_width_bottom = _scale_signed_int(source_flat.border_width_bottom, density)
		target_flat.corner_radius_top_left = _scale_signed_int(source_flat.corner_radius_top_left, density)
		target_flat.corner_radius_top_right = _scale_signed_int(source_flat.corner_radius_top_right, density)
		target_flat.corner_radius_bottom_right = _scale_signed_int(source_flat.corner_radius_bottom_right, density)
		target_flat.corner_radius_bottom_left = _scale_signed_int(source_flat.corner_radius_bottom_left, density)
		target_flat.expand_margin_left = source_flat.expand_margin_left * density
		target_flat.expand_margin_top = source_flat.expand_margin_top * density
		target_flat.expand_margin_right = source_flat.expand_margin_right * density
		target_flat.expand_margin_bottom = source_flat.expand_margin_bottom * density
		target_flat.shadow_size = _scale_signed_int(source_flat.shadow_size, density)
		target_flat.shadow_offset = source_flat.shadow_offset * density
		target_flat.anti_aliasing_size = source_flat.anti_aliasing_size * density
	elif source is StyleBoxTexture and result is StyleBoxTexture:
		var source_texture := source as StyleBoxTexture
		var target_texture := result as StyleBoxTexture
		_physicalize_stylebox_texture(
			source_texture,
			target_texture,
			target_texture_margin, density
		)
		target_texture.expand_margin_left = source_texture.expand_margin_left * density
		target_texture.expand_margin_top = source_texture.expand_margin_top * density
		target_texture.expand_margin_right = source_texture.expand_margin_right * density
		target_texture.expand_margin_bottom = source_texture.expand_margin_bottom * density
	elif source is StyleBoxLine and result is StyleBoxLine:
		var source_line := source as StyleBoxLine
		var target_line := result as StyleBoxLine
		target_line.thickness = _scale_signed_int(source_line.thickness, density)
		target_line.grow_begin = source_line.grow_begin * density
		target_line.grow_end = source_line.grow_end * density
	return result


func physical_stylebox(
	source: StyleBox,
	target_texture_margin: float = -1.0,
	density: float = -1.0
) -> StyleBox:
	if source == null:
		return null
	return _scaled_stylebox(source, target_texture_margin, density)


# Explicit density for platform-owned surfaces; never changes the global UI scale.
func physical_texture_stylebox(source: StyleBoxTexture, density: float) -> StyleBoxTexture:
	var target := source.duplicate(true) as StyleBoxTexture
	_physicalize_stylebox_texture(source, target, -1.0, density)
	return target


func _physicalize_stylebox_texture(
	source: StyleBoxTexture,
	target: StyleBoxTexture,
	target_texture_margin: float, scale_value: float
) -> void:
	if source.texture == null:
		return
	var source_image := source.texture.get_image()
	if source_image == null or source_image.is_empty():
		_scale_texture_margins_only(source, target, target_texture_margin, scale_value)
		return
	source_image = source_image.duplicate()
	if source_image.is_compressed() and source_image.decompress() != OK:
		_scale_texture_margins_only(source, target, target_texture_margin, scale_value)
		return
	if source_image.get_format() != Image.FORMAT_RGBA8:
		source_image.convert(Image.FORMAT_RGBA8)

	var region_position := Vector2i(
		roundi(source.region_rect.position.x),
		roundi(source.region_rect.position.y)
	)
	var region_size := Vector2i(
		roundi(source.region_rect.size.x),
		roundi(source.region_rect.size.y)
	)
	if region_size.x <= 0 or region_size.y <= 0:
		region_position = Vector2i.ZERO
		region_size = source_image.get_size()
	var source_bounds := Rect2i(Vector2i.ZERO, source_image.get_size())
	var source_region := Rect2i(region_position, region_size).intersection(source_bounds)
	if source_region.size.x <= 0 or source_region.size.y <= 0:
		_scale_texture_margins_only(source, target, target_texture_margin, scale_value)
		return

	var cropped := source_image.get_region(source_region)
	var source_left := clampi(roundi(source.texture_margin_left), 0, cropped.get_width())
	var source_right := clampi(
		roundi(source.texture_margin_right), 0, cropped.get_width() - source_left)
	var source_top := clampi(roundi(source.texture_margin_top), 0, cropped.get_height())
	var source_bottom := clampi(
		roundi(source.texture_margin_bottom), 0, cropped.get_height() - source_top)
	var has_slices := (
		source_left > 0 or source_right > 0 or source_top > 0 or source_bottom > 0
	)
	if not has_slices:
		var output_size := Vector2i(
			maxi(1, roundi(float(cropped.get_width()) * scale_value)),
			maxi(1, roundi(float(cropped.get_height()) * scale_value))
		)
		if cropped.get_size() != output_size:
			cropped.resize(output_size.x, output_size.y, Image.INTERPOLATE_NEAREST)
		target.texture = ImageTexture.create_from_image(cropped)
		target.region_rect = Rect2(Vector2.ZERO, output_size)
		target.texture_margin_left = 0.0
		target.texture_margin_top = 0.0
		target.texture_margin_right = 0.0
		target.texture_margin_bottom = 0.0
		return

	var source_center_width := cropped.get_width() - source_left - source_right
	var source_center_height := cropped.get_height() - source_top - source_bottom
	var target_left: int
	var target_right: int
	var target_top: int
	var target_bottom: int
	var horizontal_scale := scale_value
	var vertical_scale := scale_value
	if target_texture_margin >= 0.0:
		target_left = _scaled_positive_size(target_texture_margin, scale_value)
		target_right = target_left
		target_top = target_left
		target_bottom = target_left
		var horizontal_reference := maxf(
			1.0, (float(source_left) + float(source_right)) * 0.5)
		var vertical_reference := maxf(
			1.0, (float(source_top) + float(source_bottom)) * 0.5)
		horizontal_scale *= target_texture_margin / horizontal_reference
		vertical_scale *= target_texture_margin / vertical_reference
	else:
		target_left = _scaled_positive_size(float(source_left), scale_value)
		target_right = _scaled_positive_size(float(source_right), scale_value)
		target_top = _scaled_positive_size(float(source_top), scale_value)
		target_bottom = _scaled_positive_size(float(source_bottom), scale_value)
	var target_center_width := _scaled_positive_size(
		float(source_center_width), horizontal_scale)
	var target_center_height := _scaled_positive_size(
		float(source_center_height), vertical_scale)
	var source_widths := [source_left, source_center_width, source_right]
	var source_heights := [source_top, source_center_height, source_bottom]
	var target_widths := [target_left, target_center_width, target_right]
	var target_heights := [target_top, target_center_height, target_bottom]
	var output_size := Vector2i(
		target_left + target_center_width + target_right,
		target_top + target_center_height + target_bottom
	)
	var output := Image.create(
		maxi(1, output_size.x),
		maxi(1, output_size.y),
		false,
		cropped.get_format()
	)
	output.fill(Color(0, 0, 0, 0))
	var source_y := 0
	var target_y := 0
	for y_index in range(3):
		var source_x := 0
		var target_x := 0
		for x_index in range(3):
			var source_piece_size := Vector2i(
				int(source_widths[x_index]), int(source_heights[y_index]))
			var target_piece_size := Vector2i(
				int(target_widths[x_index]), int(target_heights[y_index]))
			if (source_piece_size.x > 0 and source_piece_size.y > 0
					and target_piece_size.x > 0 and target_piece_size.y > 0):
				var piece := cropped.get_region(Rect2i(
					Vector2i(source_x, source_y), source_piece_size))
				if piece.get_size() != target_piece_size:
					piece.resize(
						target_piece_size.x,
						target_piece_size.y,
						Image.INTERPOLATE_NEAREST
					)
				output.blit_rect(
					piece,
					Rect2i(Vector2i.ZERO, target_piece_size),
					Vector2i(target_x, target_y)
				)
			source_x += source_piece_size.x
			target_x += target_piece_size.x
		source_y += int(source_heights[y_index])
		target_y += int(target_heights[y_index])

	target.texture = ImageTexture.create_from_image(output)
	target.region_rect = Rect2(Vector2.ZERO, output.get_size())
	target.texture_margin_left = float(target_left)
	target.texture_margin_top = float(target_top)
	target.texture_margin_right = float(target_right)
	target.texture_margin_bottom = float(target_bottom)


func _scale_texture_margins_only(
	source: StyleBoxTexture,
	target: StyleBoxTexture,
	target_texture_margin: float, scale_value: float
) -> void:
	if target_texture_margin >= 0.0:
		var margin := float(_scaled_positive_size(target_texture_margin, scale_value))
		target.texture_margin_left = margin
		target.texture_margin_top = margin
		target.texture_margin_right = margin
		target.texture_margin_bottom = margin
		return
	target.texture_margin_left = source.texture_margin_left * scale_value
	target.texture_margin_top = source.texture_margin_top * scale_value
	target.texture_margin_right = source.texture_margin_right * scale_value
	target.texture_margin_bottom = source.texture_margin_bottom * scale_value


func _scaled_positive_size(value: float, scale_value: float) -> int:
	if value <= 0.0:
		return 0
	return maxi(1, roundi(value * scale_value))


func _scaled_theme(source: Theme) -> Theme:
	var result := source.duplicate(true) as Theme
	if source.has_default_font_size():
		result.default_font_size = physical_font_size(source.default_font_size)
	for raw_theme_type in source.get_type_list():
		var theme_type := StringName(raw_theme_type)
		for font_size_name in source.get_font_size_list(theme_type):
			result.set_font_size(
				font_size_name,
				theme_type,
				physical_font_size(source.get_font_size(font_size_name, theme_type)))
		for constant_name in source.get_constant_list(theme_type):
			result.set_constant(
				constant_name,
				theme_type,
				_scale_signed_int(source.get_constant(constant_name, theme_type)))
		for style_name in source.get_stylebox_list(theme_type):
			var style := source.get_stylebox(style_name, theme_type)
			if style != null:
				result.set_stylebox(
					style_name, theme_type, _scaled_stylebox(style))
	return result
