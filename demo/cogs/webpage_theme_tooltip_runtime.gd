class_name WebpageThemeTooltipRuntime
extends Node

const _TOOLTIP_GROUP := &"webpage_theme_tooltip_runtime"
const _TOOLTIP_TEXT_META := &"webpage_tooltip_text"
const _TOOLTIP_ADOPTED_META := &"webpage_tooltip_adopted"
const _TOOLTIP_INTERNAL_META := &"webpage_tooltip_internal"
const _THEME_OVERRIDE_META := &"webpage_tooltip_theme_override"
const PLACEMENT_META := &"webpage_tooltip_placement"
const _CONTENT_MARGIN_X := 8.0
const _CONTENT_MARGIN_Y := 8.0
const _EDGE_MARGIN := 4.0
const _CURSOR_OFFSET := 12.0
const _MAX_CONTENT_WIDTH := 320.0

var _connection: Node = null
var _text_runtime: Node = null
var _window: Window = null
var _surface_owner: Window = null
var _surfaces: Dictionary = {}
var _panel: PanelContainer = null
var _margin: MarginContainer = null
var _label: Label = null
var _target: Control = null
var _request_serial := 0
var _using_touch := false
var _touch_finger := -1
var _touch_position := Vector2.ZERO
var _held_button: BaseButton
var _held_button_blocked := false
var _held_button_pressed := false


static func set_control_tooltip(control: Control, text: String) -> void:
	if not is_instance_valid(control):
		return
	var changed := str(control.get_meta(_TOOLTIP_TEXT_META, "")) != text
	control.set_meta(_TOOLTIP_TEXT_META, text)
	control.tooltip_text = ""
	if not control.is_inside_tree():
		return
	var tree := control.get_tree()
	if tree == null:
		return
	var runtime := tree.get_first_node_in_group(_TOOLTIP_GROUP)
	if runtime != null:
		runtime.call("_adopt_control", control)
		if changed:
			runtime.call("_on_control_tooltip_changed", control)


static func set_control_theme_override(
		control: Node, source: Node, text_runtime: Node, system_name: String,
		launcher_font: bool = false, stretch_mode: int = -1, plain_text: bool = false) -> void:
	control.set_meta(_THEME_OVERRIDE_META, {
		"source": source, "text_runtime": text_runtime, "system_name": system_name,
		"launcher_font": launcher_font, "stretch_mode": stretch_mode, "plain_text": plain_text,
	})


static func theme_override_for(target: Node) -> Dictionary:
	var node := target
	while is_instance_valid(node):
		if node.has_meta(_THEME_OVERRIDE_META):
			return node.get_meta(_THEME_OVERRIDE_META)
		node = node.get_parent()
	return {}


func _on_control_tooltip_changed(control: Control) -> void:
	if _target != control:
		return
	if str(control.get_meta(_TOOLTIP_TEXT_META, "")).is_empty():
		_cancel_tooltip()
	elif is_instance_valid(_window) and _window.visible:
		_reflow_current_tooltip()
	else:
		_request_serial += 1
		_wait_and_show(control, _request_serial)


func _ready() -> void:
	UiScale.safe_area_changed.connect(_on_root_size_changed)
	add_to_group(_TOOLTIP_GROUP)
	var tree := get_tree()
	if tree != null and not tree.node_added.is_connected(_on_node_added):
		tree.node_added.connect(_on_node_added)
	if not UiScale.scale_changed.is_connected(_on_ui_scale_changed):
		UiScale.scale_changed.connect(_on_ui_scale_changed)
	var root := get_tree().root
	_watch_window(root)
	if not root.size_changed.is_connected(_on_root_size_changed):
		root.size_changed.connect(_on_root_size_changed)
	# During the main scene's first _ready(), the root is still adding children.
	_ensure_popup.call_deferred()


func _exit_tree() -> void:
	var tree := get_tree()
	if tree != null and tree.node_added.is_connected(_on_node_added):
		tree.node_added.disconnect(_on_node_added)
	if UiScale.scale_changed.is_connected(_on_ui_scale_changed):
		UiScale.scale_changed.disconnect(_on_ui_scale_changed)
	var root := get_tree().root
	if root.size_changed.is_connected(_on_root_size_changed):
		root.size_changed.disconnect(_on_root_size_changed)
	for surface_value in _surfaces.values():
		if surface_value is Dictionary:
			var window_value: Variant = (surface_value as Dictionary).get("window")
			if is_instance_valid(window_value):
				var surface_window := window_value as Window
				surface_window.queue_free()
	_surfaces.clear()


func configure(connection: Node, text_runtime: Node) -> void:
	_connection = connection
	_text_runtime = text_runtime
	_ensure_popup.call_deferred()
	_apply_popup_style()
	_adopt_tree(get_tree().root)


func _ensure_popup() -> void:
	var root := get_tree().root if get_tree() != null else null
	if root is Window:
		_ensure_surface(root as Window)


func _ensure_surface(owner: Window) -> void:
	if not is_instance_valid(owner):
		return
	if _surface_owner == owner and is_instance_valid(_window):
		return
	_hide_panel()
	var owner_id := owner.get_instance_id()
	var surface_value: Variant = _surfaces.get(owner_id, {})
	if surface_value is Dictionary:
		var existing := surface_value as Dictionary
		var existing_window_value: Variant = existing.get("window")
		if is_instance_valid(existing_window_value):
			_activate_surface(owner, existing)
			return

	var tooltip_window := Window.new()
	tooltip_window.name = "WebpageThemeTooltipWindow"
	tooltip_window.visible = false
	tooltip_window.size = Vector2i.ONE
	tooltip_window.exclusive = false
	tooltip_window.transient = true
	tooltip_window.set_flag(Window.FLAG_BORDERLESS, true)
	tooltip_window.set_flag(Window.FLAG_TRANSPARENT, true)
	tooltip_window.set_flag(Window.FLAG_NO_FOCUS, true)
	tooltip_window.set_flag(Window.FLAG_MOUSE_PASSTHROUGH, true)
	tooltip_window.set_meta(_TOOLTIP_INTERNAL_META, true)
	owner.add_child(tooltip_window)

	var panel := PanelContainer.new()
	UiScale.mark_geometry_physical(panel)
	panel.name = "WebpageThemeTooltip"
	panel.visible = false
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.set_meta(_TOOLTIP_INTERNAL_META, true)
	tooltip_window.add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	margin.set_meta(&"physical_ui_design_constants", {
		&"margin_left": int(_CONTENT_MARGIN_X),
		&"margin_top": int(_CONTENT_MARGIN_Y),
		&"margin_right": int(_CONTENT_MARGIN_X),
		&"margin_bottom": int(_CONTENT_MARGIN_Y),
	})
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.set_meta(_TOOLTIP_INTERNAL_META, true)
	panel.add_child(margin)

	var label := Label.new()
	UiScale.mark_geometry_physical(label)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.autowrap_mode = TextServer.AUTOWRAP_OFF
	label.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	label.set_meta(_TOOLTIP_INTERNAL_META, true)
	margin.add_child(label)

	var surface := {
		"window": tooltip_window,
		"panel": panel,
		"margin": margin,
		"label": label,
	}
	_surfaces[owner_id] = surface
	_activate_surface(owner, surface)
	_apply_popup_style()


func _activate_surface(owner: Window, surface: Dictionary) -> void:
	_surface_owner = owner
	_window = surface.get("window") as Window
	_panel = surface.get("panel") as PanelContainer
	_margin = surface.get("margin") as MarginContainer
	_label = surface.get("label") as Label


func _apply_popup_style() -> void:
	if not is_instance_valid(_panel):
		return
	var margin_x := UiScale.physical_int(_CONTENT_MARGIN_X)
	var margin_y := UiScale.physical_int(_CONTENT_MARGIN_Y)
	_margin.add_theme_constant_override("margin_left", margin_x)
	_margin.add_theme_constant_override("margin_top", margin_y)
	_margin.add_theme_constant_override("margin_right", margin_x)
	_margin.add_theme_constant_override("margin_bottom", margin_y)
	_panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	var theme_override := theme_override_for(_target)
	var source: Node = theme_override.get("source")
	var text_runtime: Node = theme_override.get("text_runtime")
	var system_name := str(theme_override.get("system_name", ""))
	if not is_instance_valid(source) or not is_instance_valid(text_runtime):
		source = _connection
		text_runtime = _text_runtime
		system_name = ""
	if is_instance_valid(source):
		SystemUISkin.install(_panel, source, system_name, int(theme_override.get("stretch_mode", -1)))
	else:
		var old_skin := _panel.get_node_or_null("__SystemUISkin") as Control
		if old_skin != null:
			old_skin.hide()
	if is_instance_valid(text_runtime):
		_label.set_meta("webpage_launcher_font", bool(theme_override.get("launcher_font", false)))
		# A previous gradient marker must not become the fallback text color.
		_label.remove_theme_color_override("font_color")
		text_runtime.style_control(
			_label, source, system_name, WebpageThemeTextRuntime.ROLE_NORMAL)
		if theme_override.get("plain_text", false):
			_label.add_theme_color_override("font_color", Color.WHITE)


func _on_node_added(node: Node) -> void:
	if node is Window:
		_watch_window(node)
	call_deferred("_adopt_added_tree", node.get_instance_id())


func _watch_window(window: Window) -> void:
	_adopt_popup_padding(window)
	var callback := _pointer_input.bind(window)
	if not window.window_input.is_connected(callback):
		window.window_input.connect(callback)
		window.visibility_changed.connect(_window_visibility_changed.bind(window))


func _window_visibility_changed(window: Window) -> void:
	if not window.visible and is_instance_valid(_target) and not _target.is_visible_in_tree():
		_cancel_tooltip()


func _pointer_input(event: InputEvent, window: Window) -> void:
	if event is InputEventScreenTouch:
		_using_touch = true
		if not event.pressed and event.index == _touch_finger:
			_cancel_tooltip()
	elif event is InputEventScreenDrag and event.index == _touch_finger and is_instance_valid(_target):
		var point: Vector2 = _target.get_viewport().get_screen_transform().affine_inverse() * window.get_screen_transform() * event.position
		if point.distance_to(_touch_position) > maxf(12, UiScale.physical_value(4)):
			_cancel_tooltip()
	elif event is InputEventMouse and event.device >= 0:
		_using_touch = false


func _control_input(event: InputEvent, control: Control) -> void:
	if event is InputEventScreenTouch and event.pressed:
		_using_touch = true
		if _touch_finger >= 0 or bool(control.get_meta("android_context_hold", false)):
			return
		_cancel_tooltip()
		_touch_finger = event.index
		_touch_position = control.get_global_transform_with_canvas() * event.position
		_target = control
		_wait_and_show(control, _request_serial)


# PopupMenu items are not Controls. Its touch adapter supplies the focused
# item's text after the same hold threshold; release still uses the Window path.
func show_touch_tooltip(control: Control, text: String, point: Vector2, finger: int) -> void:
	_cancel_tooltip()
	_using_touch = true
	_touch_finger = finger
	_touch_position = point
	_target = control
	control.set_meta(_TOOLTIP_TEXT_META, text)
	_prepare_hidden_tooltip(control, _request_serial)


func _adopt_added_tree(id: int) -> void:
	var node := instance_from_id(id) as Node
	if not is_instance_valid(node) or not node.is_inside_tree() or node.is_queued_for_deletion():
		return
	var perf_start := ClientPerformance.begin()
	_adopt_tree(node)
	ClientPerformance.end(&"ui.added_node_tooltip", perf_start)


func _adopt_tree(node: Node) -> void:
	if not is_instance_valid(node) or bool(node.get_meta(_TOOLTIP_INTERNAL_META, false)):
		return
	if node is Control:
		_adopt_control(node as Control)
	elif node is Window:
		_adopt_popup_padding(node)
	for child in node.get_children():
		_adopt_tree(child)


func _adopt_control(control: Control) -> void:
	if (not is_instance_valid(control)
			or bool(control.get_meta(_TOOLTIP_INTERNAL_META, false))):
		return
	if not control.tooltip_text.is_empty():
		control.set_meta(_TOOLTIP_TEXT_META, control.tooltip_text)
		control.tooltip_text = ""
	if not control.has_meta(_TOOLTIP_TEXT_META):
		return
	if bool(control.get_meta(_TOOLTIP_ADOPTED_META, false)):
		return
	control.set_meta(_TOOLTIP_ADOPTED_META, true)
	control.mouse_entered.connect(_on_control_mouse_entered.bind(control))
	control.mouse_exited.connect(_on_control_mouse_exited.bind(control))
	control.tree_exiting.connect(_on_control_tree_exiting.bind(control))
	control.visibility_changed.connect(_on_control_visibility_changed.bind(control))
	control.gui_input.connect(_control_input.bind(control))


func _style_native_popup_padding(popup: Window) -> void:
	# Android-owned dialogs resolve their own dp padding in LauncherPresentation.
	if bool(popup.get_meta(UiScale.META_EXTERNAL_SCALE, false)):
		return
	var style: StyleBox = popup.get_theme_stylebox("panel").duplicate()
	style.set_content_margin_all(UiScale.physical_int(8.0))
	popup.add_theme_stylebox_override("panel", style)


func _adopt_popup_padding(node: Window) -> void:
	if (node is AcceptDialog or node is PopupMenu) and not node.has_meta("webpage_popup_padding"):
		node.set_meta("webpage_popup_padding", true)
		node.about_to_popup.connect(_style_native_popup_padding.bind(node))


func _on_control_mouse_entered(control: Control) -> void:
	if _using_touch:
		return
	if not is_instance_valid(control) or not control.is_visible_in_tree():
		return
	_request_serial += 1
	_target = control
	_hide_panel()
	_wait_and_show(control, _request_serial)


func _wait_and_show(control: Control, serial: int) -> void:
	var delay := float(ProjectSettings.get_setting(
		"gui/timers/tooltip_delay_sec", 0.5))
	if delay > 0.0:
		await get_tree().create_timer(delay).timeout
	if not _is_current_request(control, serial):
		return
	await _prepare_hidden_tooltip(control, serial)


func _prepare_hidden_tooltip(control: Control, serial: int) -> void:
	var tooltip_text := str(control.get_meta(_TOOLTIP_TEXT_META, ""))
	if tooltip_text.is_empty():
		return
	var owner := control.get_window()
	if not is_instance_valid(owner):
		return
	_ensure_surface(owner)
	_window.hide()
	_panel.visible = false
	_apply_popup_style()
	_label.text = tooltip_text
	_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_label.custom_minimum_size = Vector2.ZERO
	var bounds := _tooltip_bounds()
	var margin_x := UiScale.physical_value(_CONTENT_MARGIN_X)
	var edge := UiScale.physical_value(_EDGE_MARGIN)
	var maximum_content_width := maxf(1.0, minf(
		UiScale.physical_value(_MAX_CONTENT_WIDTH),
		float(bounds.size.x) - edge * 2.0 - margin_x * 2.0))
	var natural_width := _measure_label_width(_label)
	var content_width := minf(natural_width, maximum_content_width)
	_label.custom_minimum_size.x = maxf(1.0, floorf(content_width))
	# Hidden containers do not sort their children. Give the Label its wrapping
	# width before asking for minimum height (a new nested surface starts at 1px).
	if natural_width > maximum_content_width:
		_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.size.x = _label.custom_minimum_size.x
	# Label resize marks its shaped lines dirty, but a hidden Container can still
	# return its cached minimum. Shape at the final width and invalidate parents.
	_label.get_minimum_size()
	_label.update_minimum_size()
	_margin.update_minimum_size()
	_panel.update_minimum_size()
	var preliminary_width := ceili(content_width + margin_x * 2.0)
	_window.size = Vector2i(preliminary_width, maxi(1, _window.size.y))
	await get_tree().process_frame
	if not _is_current_request(control, serial):
		return
	var first_minimum := _margin.get_combined_minimum_size()
	await get_tree().process_frame
	if not _is_current_request(control, serial):
		return
	var minimum := _margin.get_combined_minimum_size()
	if minimum.is_equal_approx(Vector2.ZERO):
		minimum = first_minimum
	var edge_int := UiScale.physical_int(_EDGE_MARGIN)
	var available := Vector2i(
		maxi(1, bounds.size.x - edge_int * 2),
		maxi(1, bounds.size.y - edge_int * 2))
	var final_size := Vector2i(
		mini(available.x, maxi(1, ceili(minimum.x))),
		mini(available.y, maxi(1, ceili(minimum.y))))
	_window.size = final_size
	await get_tree().process_frame
	if not _is_current_request(control, serial):
		return
	_window.position = _tooltip_position(bounds, final_size)
	_panel.size = Vector2(final_size)
	_margin.size = Vector2(final_size)
	_panel.visible = true
	if _touch_finger >= 0 and control is BaseButton and _held_button != control:
		_held_button = control
		_held_button_blocked = control.is_blocking_signals()
		_held_button_pressed = control.button_pressed
		control.set_block_signals(true)
	_window.show()


func _measure_label_width(label: Label) -> float:
	var font := label.get_theme_font("font")
	var font_size := label.get_theme_font_size("font_size")
	var maximum_width := 1.0
	for line in label.text.split("\n"):
		maximum_width = maxf(maximum_width, font.get_string_size(
			line, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x)
	return maximum_width


func _tooltip_bounds() -> Rect2i:
	return PopupGeometry.bounds_for(_window)


func _tooltip_position(bounds: Rect2i, tooltip_size: Vector2i) -> Vector2i:
	var source := _target.get_viewport() if is_instance_valid(_target) else get_tree().root
	var point := _touch_position if _touch_finger >= 0 else source.get_mouse_position()
	var cursor := Vector2i(PopupGeometry.viewport_point(_window, source, point))
	var offset := UiScale.physical_int(_CURSOR_OFFSET)
	var edge := UiScale.physical_int(_EDGE_MARGIN)
	var position := cursor + Vector2i(offset, offset)
	if is_instance_valid(_target) and _target.get_meta(PLACEMENT_META, "") == "upper_left":
		position = cursor - tooltip_size
	else:
		if position.x + tooltip_size.x > bounds.end.x - edge:
			position.x = cursor.x - offset - tooltip_size.x
		if position.y + tooltip_size.y > bounds.end.y - edge:
			position.y = cursor.y - offset - tooltip_size.y
	var minimum := bounds.position + Vector2i(edge, edge)
	var maximum := bounds.end - tooltip_size - Vector2i(edge, edge)
	maximum.x = maxi(minimum.x, maximum.x)
	maximum.y = maxi(minimum.y, maximum.y)
	return Vector2i(
		clampi(position.x, minimum.x, maximum.x),
		clampi(position.y, minimum.y, maximum.y))


func _is_current_request(control, serial: int) -> bool:
	return (serial == _request_serial
		and is_instance_valid(control)
		and _target == control
		and control.is_visible_in_tree())


func _on_control_mouse_exited(control: Control) -> void:
	if _target == control and _touch_finger < 0:
		_cancel_tooltip()


func _on_control_tree_exiting(control: Control) -> void:
	if _target == control:
		_cancel_tooltip()


func _on_control_visibility_changed(control: Control) -> void:
	if _target == control and not control.is_visible_in_tree():
		_cancel_tooltip()


func _cancel_tooltip() -> void:
	_request_serial += 1
	_touch_finger = -1
	if is_instance_valid(_held_button):
		_release_button(_held_button, _held_button_blocked, _held_button_pressed)
	_held_button = null
	_target = null
	_hide_panel()


func _release_button(button: BaseButton, blocked: bool, pressed: bool) -> void:
	# Keep the release (including the emulated mouse release) from activating it.
	await get_tree().process_frame
	if is_instance_valid(button):
		if button.toggle_mode:
			button.set_pressed_no_signal(pressed)
		button.set_block_signals(blocked)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_APPLICATION_PAUSED:
		_cancel_tooltip()


func _hide_panel() -> void:
	if is_instance_valid(_window):
		_window.hide()
	if is_instance_valid(_panel):
		_panel.visible = false


func _on_ui_scale_changed(_scale: float) -> void:
	_apply_popup_style()
	_reflow_current_tooltip()


func _on_root_size_changed() -> void:
	_reflow_current_tooltip()


func _reflow_current_tooltip() -> void:
	if not is_instance_valid(_target) or not _target.is_visible_in_tree():
		_hide_panel()
		return
	_request_serial += 1
	var serial := _request_serial
	var target := _target
	_hide_panel()
	_prepare_hidden_tooltip(target, serial)
