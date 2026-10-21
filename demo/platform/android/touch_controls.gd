extends Control

const TouchVirtualControl := preload("res://platform/android/touch_virtual_control.gd")
const EasyRPGKeyCatalog := preload("res://platform/android/easyrpg_key_catalog.gd")
const LayoutConfig := preload("res://platform/android/touch_layout_config.gd")
const CONFIG_PATH := "user://touch_controller.cfg"
const SCHEMA_VERSION := LayoutConfig.SCHEMA_VERSION
const HISTORY_LIMIT := 100
const WEB_DEFAULT_OPACITY := LayoutConfig.WEB_DEFAULT_OPACITY
const WEB_COLOR := Color("#D3DFE1")
const APP_THEME := preload("res://resources/theme.tres")
const DPAD_KEYS := {"left": 12, "up": 13, "right": 14, "down": 15}
const BOTTOM_SLOTS := ["dpad", "escape", "enter", "shift", "digit1", "digit3", "digit5", "digit9"]
const ALIGNMENTS := LayoutConfig.ALIGNMENTS
const DEFAULT_BOTTOM_FRACTION := 0.88
const DEFAULT_DIAMETER_FRACTION := 16.0 / 75.0
const Metrics := preload("res://platform/android/launcher_presentation.gd")
const UiTheme := preload("res://platform/android/ui_theme.gd")
const ThemedDialog := preload("res://platform/android/themed_dialog.gd")
signal chat_requested()
signal console_requested()
signal editor_changed()
signal preview_orientation_requested(portrait: bool)
signal editor_fields_invalidated()
var config_path := CONFIG_PATH
var controls_enabled: bool:
	get: return _enabled
var _preview_pending := ""
var _interaction_blocked := false
var _toolbar_row: GridContainer
var _editor_scroll: ScrollContainer
var _scroll_gesture: Node
var _catalog_gesture: Node

@export var engine: Node

var _layouts: Dictionary = {}
var _group_settings: Dictionary = {}
var _enabled := true
var _opacity := WEB_DEFAULT_OPACITY
var _show_key_labels := true
var _panel_dock := "left"
var _runtime_active := false
var _last_orientation := ""
var _last_window_size := Vector2i.ZERO

var _control_nodes: Array[Control] = []
var _finger_bindings: Dictionary = {}

var _editor_open := false
var _editor_snapshot: Dictionary = {}
var _edit_orientation := "landscape"
var _selected_index := -1
var _updating_editor_ui := false
var _panel_collapsed := true

var _editor_toolbar: PanelContainer
var _toolbar_expand: Button
var _reset_confirmation: ThemedDialog
var _cancel_confirmation: ThemedDialog
var _save_error: ThemedDialog
var _editor_heading: Label
var _editor_title_wrap: MarginContainer
var _editor_column: VBoxContainer
var _editor_panel: PanelContainer
var _alignment_option: OptionButton
var _group_offset_slider: HSlider
var _opacity_slider: HSlider
var _labels_check: CheckButton
var _dock_option: OptionButton
var _selection_label: Label
var _width_slider: HSlider
var _height_slider: HSlider
var _visible_check: CheckButton
var _label_override: LineEdit
var _shape_option: OptionButton
var _delete_button: Button
var _catalog_search: LineEdit
var _catalog_category: OptionButton
var _catalog_list: ItemList
var _catalog_entries: Array = []
var _filtered_catalog: Array = []
var _single_panel: PanelContainer
var _add_panel: PanelContainer
var _selection_prompt: PanelContainer
var _single_toolbar: PanelContainer
var _single_toolbar_row: GridContainer
var _panels: Array[Dictionary] = []
var _single_dock_option: OptionButton
var _label_visible_check: CheckButton
var _group_offset_row: Control
var _undo_buttons: Array[Button] = []
var _redo_buttons: Array[Button] = []
var _single_cancel: ThemedDialog
var _active_panel := ""
var _single_editing := false
var _single_dock := "center"
var _undo: Array = []
var _redo: Array = []
var _single_undo: Array = []
var _single_redo: Array = []
var _single_snapshot: Dictionary = {}
var _pending_edit: Dictionary = {}
var _pending_kind := ""
var _restoring_history := false
var _loaded_schema := -1

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	Metrics.take_ownership(self)
	_create_editor_ui()
	_load_config()
	if not EasyRPGKeyCatalog.required_ids_are_valid():
		push_error("EasyRPG key catalogue validation failed")
	visibility_changed.connect(_on_controller_visibility_changed)
	_rebuild_controls()
	resized.connect(_layout)
	_layout()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		_finish_edit()
		_release_all_keys()

func _exit_tree() -> void:
	_release_all_keys()
	if _editor_open:
		_restore_editor_snapshot()


func on_game_started() -> void:
	_runtime_active = true
	_layout()
	_update_control_visibility()


func on_game_stopped() -> void:
	_release_all_keys()
	_runtime_active = false
	if _editor_open:
		_apply_editor_cancel()
	_update_control_visibility()


func open_editor() -> void:
	if _editor_open: return
	_release_all_keys()
	_edit_orientation = _orientation_name()
	_selected_index = -1
	_editor_snapshot = _capture_edit_state()
	_editor_open = true
	_single_editing = false
	_active_panel = ""
	_panel_collapsed = true
	_clear_history()
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	_rebuild_controls()
	_refresh_editor_ui()
	editor_changed.emit()

func release_all_keys() -> void:
	_release_all_keys()

func is_editor_open() -> bool:
	return _editor_open

func virtual_controls_enabled() -> bool:
	return _enabled

func set_virtual_controls_enabled(value: bool, persist: bool = true) -> bool:
	if persist:
		set_controls_enabled(value)
	else:
		_enabled = value
		_update_control_visibility()
	return _enabled


func toggle_virtual_controls() -> bool:
	return set_virtual_controls_enabled(not _enabled, true)

func set_interaction_blocked(value: bool) -> void:
	if _interaction_blocked and not value and _pending_kind == "label": _finish_edit()
	_interaction_blocked = value
	if value:
		_release_all_keys()
		if _scroll_gesture: _scroll_gesture.cancel()
		if _catalog_gesture: _catalog_gesture.cancel()


func handle_back_request() -> bool:
	for dialog: ThemedDialog in [_save_error, _reset_confirmation, _single_cancel, _cancel_confirmation]:
		if dialog and dialog.is_open_or_opening():
			dialog.dismiss()
			return true
	if not _editor_open: return false
	for option: OptionButton in [_alignment_option, _dock_option, _single_dock_option, _shape_option, _catalog_category]:
		if option.get_popup().visible:
			option.get_popup().hide()
			return true
	if _single_editing:
		_request_single_cancel()
	elif not _active_panel.is_empty():
		_set_panel("")
	else:
		_request_editor_cancel()
	return true

func _input(event: InputEvent) -> void:
	if not is_visible_in_tree() or _interaction_blocked or _editor_confirmation_visible():
		return
	if event is InputEventMouse and event.device == -1:
		if _editor_open and not _point_over_editor_ui(event.position):
			get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed: _begin_touch(-2, event.position)
		else: _end_touch(-2)
	elif event is InputEventMouseMotion and _finger_bindings.has(-2):
		_move_touch(-2, event.position)
	if event is InputEventScreenTouch:
		if event.canceled:
			_end_touch(event.index, true)
		elif event.pressed:
			_begin_touch(event.index, event.position)
		else:
			_end_touch(event.index, false)
		if _editor_open and not _point_over_editor_ui(event.position):
			get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag:
		_move_touch(event.index, event.position)
		if _editor_open and not _point_over_editor_ui(event.position):
			get_viewport().set_input_as_handled()


func _begin_touch(finger: int, point: Vector2) -> void:
	if _finger_bindings.has(finger):
		_end_touch(finger, true)
	if _editor_open:
		if _point_over_editor_ui(point): return
		if not _active_panel.is_empty():
			_set_panel("")
			_finger_bindings[finger] = {"mode": "consume"}
			get_viewport().set_input_as_handled()
			return
		var edit_index := _hit_test(point, true)
		if edit_index < 0: return
		editor_fields_invalidated.emit()
		if _single_editing:
			_finish_edit()
			_selected_index = edit_index
			_active_panel = "single"
			_finger_bindings[finger] = {"mode": "consume"}
		else:
			_begin_edit("drag")
			_selected_index = edit_index
			var node := _control_nodes[edit_index]
			_finger_bindings[finger] = {"mode": "edit", "index": edit_index, "offset": point - node.global_position}
		_refresh_editor_ui()
		_rebuild_selection_visuals()
		get_viewport().set_input_as_handled()
		return
	var index := _hit_test(point, false)
	if index < 0:
		return
	var controls := _active_layout()
	var control: Dictionary = controls[index]
	if not _can_interact_with_control(control):
		return
	var node := _control_nodes[index]
	var kind := str(control.get("type", "key"))
	_finger_bindings[finger] = {"mode": "runtime", "index": index, "key_id": -1, "active": true}
	if kind == "dpad":
		_switch_dpad_direction(finger, _dpad_direction_at(node, point))
	elif kind == "app_action":
		node.set_pressed_visual(true)
		var action_binding: Dictionary = _finger_bindings[finger]
		action_binding["mode"] = "app_action"
		action_binding["app_action"] = str(control.get("app_action", ""))
		_finger_bindings[finger] = action_binding
	else:
		var key_id := int(control.get("key_id", -1))
		if key_id >= 0:
			node.set_pressed_visual(true)
			var binding: Dictionary = _finger_bindings[finger]
			binding["key_id"] = key_id
			_finger_bindings[finger] = binding
			engine.set_touch_input(finger, key_id, true)
	get_viewport().set_input_as_handled()

func _move_touch(finger: int, point: Vector2) -> void:
	if not _finger_bindings.has(finger): return
	var binding: Dictionary = _finger_bindings[finger]
	var mode := str(binding.get("mode", ""))
	var index := int(binding.get("index", -1))
	if mode == "edit":
		if index >= 0 and index < _control_nodes.size():
			_move_editor_control(index, point - Vector2(binding.offset))
	elif mode == "app_action":
		if index >= 0 and not _control_nodes[index].get_global_rect().has_point(point):
			binding.active = false
			_refresh_pressed_visual(index)
	elif index >= 0 and str(_active_layout()[index].type) == "dpad":
		_switch_dpad_direction(finger, _dpad_direction_at(_control_nodes[index], point))
	else:
		# Keep ownership outside ordinary keys, including sliding onto another key.
		var next := _hit_test(point, false)
		if next >= 0 and str(_active_layout()[next].type) != "key": next = -1
		if next != index:
			_release_runtime_binding(finger)
			if next >= 0:
				_begin_touch(finger, point)
			else:
				_finger_bindings[finger] = {"mode": "runtime", "index": -1, "key_id": -1}
	get_viewport().set_input_as_handled()


func _end_touch(finger: int, canceled: bool = false) -> void:
	if not _finger_bindings.has(finger):
		return
	var binding: Dictionary = _finger_bindings[finger]
	var mode := str(binding.get("mode", ""))
	if mode == "runtime":
		_release_runtime_binding(finger)
	elif mode == "app_action":
		var activate_app_action := bool(binding.get("active", false)) and not canceled
		var app_action := str(binding.get("app_action", ""))
		_release_runtime_binding(finger)
		if activate_app_action:
			_trigger_app_action(app_action)
	else:
		_finger_bindings.erase(finger)
		if mode == "edit" and not _finger_bindings.values().any(func(b): return b.get("mode") == "edit"):
			_finish_edit()
	get_viewport().set_input_as_handled()

func _release_runtime_binding(finger: int) -> void:
	if not _finger_bindings.has(finger):
		return
	var binding: Dictionary = _finger_bindings[finger]
	var index := int(binding.get("index", -1))
	var key_id := int(binding.get("key_id", -1))
	if key_id >= 0 and is_instance_valid(engine):
		engine.set_touch_input(finger, key_id, false)
	_finger_bindings.erase(finger)
	_refresh_pressed_visual(index)


func _refresh_pressed_visual(index: int) -> void:
	if index < 0 or index >= _control_nodes.size(): return
	var pressed := false
	var direction := ""
	for binding: Dictionary in _finger_bindings.values():
		if int(binding.get("index", -1)) != index: continue
		pressed = pressed or int(binding.get("key_id", -1)) >= 0 or \
			(str(binding.get("mode", "")) == "app_action" and bool(binding.get("active", false)))
		if not str(binding.get("direction", "")).is_empty(): direction = binding.direction
	if _control_nodes[index].control_type == "dpad":
		_control_nodes[index].set_dpad_direction(direction)
	else:
		_control_nodes[index].set_pressed_visual(pressed)

func _switch_dpad_direction(finger: int, direction: String) -> void:
	if not _finger_bindings.has(finger):
		return
	var binding: Dictionary = _finger_bindings[finger]
	var old_id := int(binding.get("key_id", -1))
	var new_id := int(DPAD_KEYS.get(direction, -1))
	if old_id == new_id:
		return
	if old_id >= 0:
		engine.set_touch_input(finger, old_id, false)
	if new_id >= 0:
		engine.set_touch_input(finger, new_id, true)
	binding["key_id"] = new_id
	binding["direction"] = direction
	_finger_bindings[finger] = binding
	var index := int(binding.get("index", -1))
	_refresh_pressed_visual(index)

func _dpad_direction_at(node: Control, point: Vector2) -> String:
	var rect := node.get_global_rect()
	if not rect.has_point(point):
		return ""
	var local := (point - rect.position) / rect.size
	if local.y < 1.0 / 3.0 and local.x >= 1.0 / 3.0 and local.x <= 2.0 / 3.0:
		return "up"
	if local.y > 2.0 / 3.0 and local.x >= 1.0 / 3.0 and local.x <= 2.0 / 3.0:
		return "down"
	if local.x < 1.0 / 3.0 and local.y >= 1.0 / 3.0 and local.y <= 2.0 / 3.0:
		return "left"
	if local.x > 2.0 / 3.0 and local.y >= 1.0 / 3.0 and local.y <= 2.0 / 3.0:
		return "right"
	return ""

func _release_all_keys() -> void:
	for finger: int in _finger_bindings.keys():
		_release_runtime_binding(finger)
	_finger_bindings.clear()
	for node in _control_nodes:
		node.set_pressed_visual(false)
		node.set_dpad_direction("")


func _trigger_app_action(action: String) -> void:
	_release_all_keys()
	match action:
		"limbo_console_toggle": console_requested.emit()
		"chat_focus": chat_requested.emit()


func _can_send_game_input() -> bool:
	return _runtime_active and _enabled and not _editor_open and not _interaction_blocked \
		and is_visible_in_tree() and is_instance_valid(engine) and engine.is_running()


func _can_interact_with_control(_control: Dictionary) -> bool:
	return _can_send_game_input()


func _point_over_editor_ui(point: Vector2) -> bool:
	for control: Control in [_editor_toolbar, _single_toolbar, _editor_panel, _single_panel, _add_panel]:
		if control.visible and control.get_global_rect().has_point(point): return true
	return false

func _hit_test(point: Vector2, include_hidden: bool) -> int:
	var controls := _active_layout()
	for index in range(_control_nodes.size() - 1, -1, -1):
		var node := _control_nodes[index]
		if not node.visible or index >= controls.size():
			continue
		if not include_hidden and not bool(controls[index].get("visible", true)):
			continue
		if node.get_global_rect().has_point(point):
			return index
	return -1

func _load_config() -> void:
	_restore_all_defaults_in_memory()
	var cfg := ConfigFile.new()
	if cfg.load(config_path) != OK:
		return
	var state := LayoutConfig.decode(cfg)
	_loaded_schema = state.schema
	_apply_config_state(state)



func _backup_legacy_config() -> bool:
	if _loaded_schema not in [1, 2, 3] or not FileAccess.file_exists(config_path): return true
	var suffix := "-v1-backup.cfg" if _loaded_schema == 1 else "-pre-v4-backup.cfg"
	var backup := config_path.get_basename() + suffix
	if FileAccess.file_exists(backup): return true
	return DirAccess.copy_absolute(config_path, backup) == OK

func _save_config() -> bool:
	if not _backup_legacy_config():
		_save_error.dialog_text = "无法备份旧版触控布局，尚未保存。"
		_save_error.open()
		return false
	var cfg := LayoutConfig.encode({
		"enabled": _enabled, "opacity": _opacity, "show_key_labels": _show_key_labels, "panel_dock": _panel_dock,
		"layouts": _layouts, "group_settings": _group_settings,
	})
	var error := cfg.save(config_path)
	if error != OK:
		_save_error.dialog_text = "无法保存触控布局（错误 %d）。" % error
		_save_error.open()
		return false
	_loaded_schema = SCHEMA_VERSION
	return true

func _restore_all_defaults_in_memory() -> void:
	_apply_config_state(LayoutConfig.default_state())

func _apply_config_state(state: Dictionary) -> void:
	_enabled = state.enabled
	_opacity = state.opacity
	_show_key_labels = state.show_key_labels
	_panel_dock = state.panel_dock
	_layouts = state.layouts
	_group_settings = state.group_settings

func _restore_web_layouts() -> void:
	_layouts = {"portrait": _web_default_layout(), "landscape": _web_default_layout()}
	_group_settings = LayoutConfig.default_group_settings()

func _web_default_layout() -> Array:
	return LayoutConfig.default_layout()

func _dpad_control(web_slot: String = "") -> Dictionary:
	return LayoutConfig.dpad_control(web_slot)

func _key_control(key_id: int, key_name: String, label: String, shape: String, width_ratio: float, height_ratio: float, web_slot: String = "") -> Dictionary:
	return LayoutConfig.key_control(key_id, key_name, label, shape, width_ratio, height_ratio, web_slot)

func _app_action_control(action: String, label: String = "Console", web_slot: String = "") -> Dictionary:
	return LayoutConfig.app_action_control(action, label, web_slot)

func _active_layout() -> Array:
	var orientation := _edit_orientation if _editor_open else _orientation_name()
	return _layouts.get(orientation, [])

func _orientation_name() -> String:
	var window_size := Vector2(DisplayServer.window_get_size())
	if window_size.x <= 0.0 or window_size.y <= 0.0:
		window_size = size
	return "portrait" if window_size.y > window_size.x else "landscape"

func _rebuild_controls() -> void:
	_release_all_keys()
	for node in _control_nodes:
		remove_child(node)
		node.queue_free()
	_control_nodes.clear()
	var controls := _active_layout()
	for index in controls.size():
		var control: Dictionary = controls[index]
		var node: Control = TouchVirtualControl.new()
		node.name = "Touch_%d_%s" % [index, control.get("key_name", control.get("type", "control"))]
		node.z_index = 0
		node.configure(control, _opacity, _show_key_labels)
		UiScale.mark_geometry_physical(node)
		add_child(node)
		_control_nodes.append(node)
	_layout_controls()
	_update_control_visibility()
	_rebuild_selection_visuals()

func _layout_controls() -> void:
	var controls := _active_layout()
	if mini(controls.size(), _control_nodes.size()) == 0:
		_layout_editor_ui()
		return
	var safe := _safe_rect()
	var orientation := _edit_orientation if _editor_open else _orientation_name()
	var base_size := _free_control_unit(orientation)
	var group_offset := _bottom_group_offset(safe, base_size, orientation)
	for index in mini(controls.size(), _control_nodes.size()):
		_position_control_with_geometry(index, safe, base_size, group_offset)
	_layout_editor_ui()

func _position_control(index: int) -> void:
	if index < 0 or index >= _active_layout().size() or index >= _control_nodes.size():
		return
	var safe := _safe_rect()
	var orientation := _edit_orientation if _editor_open else _orientation_name()
	var base_size := _free_control_unit(orientation)
	_position_control_with_geometry(index, safe, base_size, _bottom_group_offset(safe, base_size, orientation))

func _position_control_with_geometry(index: int, safe: Rect2, base_size: float, group_offset: float) -> void:
	var controls := _active_layout()
	if index < 0 or index >= controls.size() or index >= _control_nodes.size():
		return
	var control: Dictionary = controls[index]
	var node := _control_nodes[index]
	var rect := _base_control_rect(control, safe, base_size)
	if str(control.get("web_slot", "")) in BOTTOM_SLOTS:
		rect.position.y += group_offset
	node.size = rect.size
	node.position = rect.position


func _base_control_rect(control: Dictionary, safe: Rect2, base_size: float) -> Rect2:
	var control_size := Vector2(
		maxf(20.0, base_size * float(control.get("width_ratio", 1.0))),
		maxf(20.0, base_size * float(control.get("height_ratio", 1.0)))
	)
	var web_slot := str(control.get("web_slot", ""))
	var requested := safe.position + safe.size * Vector2(float(control.get("normalized_x", 0.5)), float(control.get("normalized_y", 0.5)))
	if web_slot in BOTTOM_SLOTS or web_slot == "chat":
		var rect := _default_control_rect(web_slot, safe)
		control_size = rect.size
		requested = rect.position
	var maximum := safe.end - control_size
	maximum.x = maxf(maximum.x, safe.position.x)
	maximum.y = maxf(maximum.y, safe.position.y)
	# Bottom members are constrained together after applying the group preset.
	var y := requested.y if web_slot in BOTTOM_SLOTS else clampf(requested.y, safe.position.y, maximum.y)
	return Rect2(Vector2(clampf(requested.x, safe.position.x, maximum.x), y), control_size)


func _free_control_unit(orientation: String) -> float:
	# Keep existing free layouts in their old units. New portrait margins must
	# move their safe region without also shrinking their manually edited sizes.
	return get_viewport_rect().size.y * (0.10 if orientation == "portrait" else 0.20)


func _default_diameter() -> float:
	var viewport_size := get_viewport_rect().size
	return minf(viewport_size.x, viewport_size.y) * DEFAULT_DIAMETER_FRACTION


func _bottom_group_offset(safe: Rect2, base_size: float, orientation: String) -> float:
	# The complete default group is the reference even when a member is hidden,
	# removed or dragged away. Editing one key must not recenter the other keys.
	var diameter := _default_diameter()
	var baseline := safe.end.y - _dp_to_local(16.0)
	# D-pad has the largest drawing inset, hence the union extends by 2 px.
	var top := baseline - 2.0 * diameter - 2.0
	var bottom := baseline + 2.0
	var minimum := safe.position.y - top
	var maximum := safe.end.y - bottom
	var has_members := false
	for control: Dictionary in _layouts[orientation]:
		if str(control.get("web_slot", "")) not in BOTTOM_SLOTS: continue
		has_members = true
		var rect := _base_control_rect(control, safe, base_size)
		minimum = maxf(minimum, safe.position.y - rect.position.y)
		maximum = minf(maximum, safe.end.y - rect.end.y)
	if not has_members: return 0.0
	var settings: Dictionary = _group_settings[orientation]
	var alignment := str(settings.alignment)
	var basis := str(settings.get("legacy_custom_basis", "default")) if alignment == "custom" else alignment
	var shift := _group_basis(safe, basis)
	if alignment == "custom": shift += float(settings.offset) * safe.size.y
	return clampf(shift, minimum, maxf(minimum, maximum))

func _group_basis(safe: Rect2, alignment: String) -> float:
	var baseline := safe.end.y - _dp_to_local(16.0)
	if alignment == "center": return safe.get_center().y - (baseline - _default_diameter())
	if alignment == "default":
		var viewport_rect := get_viewport_rect()
		return viewport_rect.position.y + viewport_rect.size.y * DEFAULT_BOTTOM_FRACTION - baseline
	return 0.0

func _effective_custom_offset() -> float:
	var safe := _safe_rect()
	return (_bottom_group_offset(safe, _free_control_unit(_edit_orientation), _edit_orientation) - _group_basis(safe, "default")) / maxf(1, safe.size.y)


func _detach_default_position(control: Dictionary, index: int) -> void:
	if not control.has("web_slot"): return
	var safe := _safe_rect()
	var normalized := (_control_nodes[index].position - safe.position) / safe.size
	control["normalized_x"] = clampf(normalized.x, 0.0, 1.0)
	control["normalized_y"] = clampf(normalized.y, 0.0, 1.0)
	var unit := _free_control_unit(_edit_orientation if _editor_open else _orientation_name())
	control["width_ratio"] = _control_nodes[index].size.x / unit
	control["height_ratio"] = _control_nodes[index].size.y / unit
	control.erase("web_slot")


func _default_control_rect(slot: String, safe: Rect2) -> Rect2:
	# Geometry is specified by visible edges; keep the existing drawing insets.
	var diameter := _default_diameter()
	var rem := _dp_to_local(16.0)
	var right_edge := safe.end.x - rem
	var bottom_edge := safe.end.y - rem
	var rect := Rect2(Vector2.ZERO, Vector2.ONE * diameter)
	match slot:
		"dpad":
			rect = Rect2(Vector2(safe.position.x + rem, bottom_edge - 2.0 * diameter), Vector2.ONE * 2.0 * diameter)
		"escape": rect.position = Vector2(right_edge - diameter, bottom_edge - 2.0 * diameter)
		"enter": rect.position = Vector2(right_edge - 2.0 * diameter, bottom_edge - diameter)
		"shift", "chat":
			rect.size = Vector2.ONE * 0.6 * diameter
			rect.position = Vector2(right_edge - 0.79 * diameter, bottom_edge - 0.8 * diameter)
			if slot == "chat": rect.position.y = safe.position.y + rem + 1.0
		"digit1", "digit3", "digit5", "digit9":
			rect.size = Vector2.ONE * diameter * 153.0 / 380.0
			var step := diameter * 170.0 / 380.0
			rect.position = Vector2(right_edge - 2.0 * diameter, bottom_edge - 2.0 * diameter)
			if slot in ["digit3", "digit9"]: rect.position.x += step
			if slot in ["digit5", "digit9"]: rect.position.y += step
	return rect.grow(2.0 if slot == "dpad" else 1.0)

func _safe_rect() -> Rect2:
	return UiScale.safe_rect_for(get_viewport())


func _dp_to_local(dp: float) -> float:
	return float(Metrics.dp(dp))


func _update_control_visibility() -> void:
	var controls := _active_layout()
	for index in _control_nodes.size():
		var configured_visible := index < controls.size() and bool(controls[index].get("visible", true))
		_control_nodes[index].visible = _editor_open or (_runtime_active and _enabled and configured_visible)
	_editor_toolbar.visible = _editor_open and not _single_editing
	_single_toolbar.visible = _editor_open and _single_editing
	_editor_panel.visible = _editor_open and _active_panel == "general"
	_single_panel.visible = _editor_open and _active_panel == "single" and _selected_index >= 0
	_add_panel.visible = _editor_open and _active_panel == "add"
	_selection_prompt.visible = _editor_open and _single_editing and not _single_panel.visible
	_panel_collapsed = not _editor_panel.visible

func _rebuild_selection_visuals() -> void:
	for index in _control_nodes.size():
		_control_nodes[index].set_selected_visual(_editor_open and index == _selected_index)

func _move_editor_control(index: int, requested_position: Vector2) -> void:
	var controls := _active_layout()
	if index < 0 or index >= controls.size():
		return
	var safe := _safe_rect()
	var control: Dictionary = controls[index]
	var current := _control_nodes[index]
	var target := requested_position.clamp(safe.position, (safe.end - current.size).max(safe.position))
	if target.is_equal_approx(current.position): return
	_begin_edit("drag")
	_detach_default_position(control, index)
	control["normalized_x"] = clampf((requested_position.x - safe.position.x) / maxf(1.0, safe.size.x), 0.0, 1.0)
	control["normalized_y"] = clampf((requested_position.y - safe.position.y) / maxf(1.0, safe.size.y), 0.0, 1.0)
	controls[index] = control
	_position_control(index)

func _create_editor_ui() -> void:
	_create_editor_toolbar()
	_create_editor_panel()
	_create_editor_confirmations()
	_catalog_entries = EasyRPGKeyCatalog.editor_entries()
	_refresh_catalog()
	for option: OptionButton in [_alignment_option, _dock_option, _single_dock_option, _shape_option, _catalog_category]:
		UiTheme.configure_option(option)
	for panel: Dictionary in _panels:
		var gesture := preload("res://platform/android/touch_scroll.gd").new()
		gesture.scroll = panel.scroll
		gesture.slop = Metrics.dp(12)
		gesture.passthrough_controls.assign([_width_slider, _height_slider, _opacity_slider, _group_offset_slider, _catalog_list])
		panel.node.add_child(gesture)
		panel["gesture"] = gesture
		_size_editor_controls(panel.node)
	_scroll_gesture = _panels[0].gesture
	_catalog_gesture = preload("res://platform/android/item_list_touch.gd").new()
	_catalog_gesture.list = _catalog_list
	_catalog_gesture.slop = Metrics.dp(12)
	_add_panel.add_child(_catalog_gesture)
	for slider: HSlider in [_width_slider, _height_slider, _opacity_slider, _group_offset_slider]:
		slider.drag_started.connect(_begin_edit.bind("slider:%s" % slider.get_instance_id()))
		slider.drag_ended.connect(func(_changed): _finish_edit())
		slider.focus_exited.connect(_finish_edit)
	_label_override.focus_exited.connect(func():
		# Native input releases Godot focus when opening; its modal end owns completion.
		if OS.get_name() != "Android" and not _interaction_blocked: _finish_edit())

func _create_editor_toolbar() -> void:
	_editor_toolbar = _make_toolbar("TouchEditorToolbar")
	_toolbar_row = _editor_toolbar.get_child(0)
	_toolbar_expand = _toolbar_button(_toolbar_row, "总体设置", _on_toolbar_expand_pressed)
	_toolbar_expand.toggle_mode = true
	_toolbar_button(_toolbar_row, "恢复默认", _on_editor_reset_pressed)
	_toolbar_button(_toolbar_row, "保存", _on_editor_save_pressed)
	_toolbar_button(_toolbar_row, "放弃", _on_editor_cancel_pressed)
	_toolbar_button(_toolbar_row, "编辑单键", _enter_single_editor)
	_toolbar_button(_toolbar_row, "添加按钮", _toggle_add_panel)
	_undo_buttons.append(_toolbar_button(_toolbar_row, "撤销", _undo_edit))
	_redo_buttons.append(_toolbar_button(_toolbar_row, "重做", _redo_edit))
	_single_toolbar = _make_toolbar("SingleKeyToolbar")
	_single_toolbar_row = _single_toolbar.get_child(0)
	_toolbar_button(_single_toolbar_row, "保存并返回", _save_single_editor)
	_toolbar_button(_single_toolbar_row, "放弃并返回", _request_single_cancel)
	_undo_buttons.append(_toolbar_button(_single_toolbar_row, "撤销", _undo_edit))
	_redo_buttons.append(_toolbar_button(_single_toolbar_row, "重做", _redo_edit))

func _make_toolbar(title: String) -> PanelContainer:
	var toolbar := PanelContainer.new()
	toolbar.name = title
	toolbar.z_index = 110
	toolbar.mouse_filter = Control.MOUSE_FILTER_STOP
	toolbar.theme = UiTheme.theme(true)
	toolbar.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	add_child(toolbar)
	var row := GridContainer.new()
	row.columns = 4
	row.add_theme_constant_override("h_separation", Metrics.dp(3))
	row.add_theme_constant_override("v_separation", Metrics.dp(3))
	toolbar.add_child(row)
	toolbar.hide()
	return toolbar

func _toolbar_button(row: GridContainer, label: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = label
	button.pressed.connect(action)
	_configure_toolbar_button(button)
	row.add_child(button)
	return button

func _configure_toolbar_button(button: Button) -> void:
	button.custom_minimum_size = Vector2.ZERO
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL

func _create_editor_confirmations() -> void:
	_reset_confirmation = ThemedDialog.new()
	_reset_confirmation.in_game = true
	_reset_confirmation.title = "恢复默认布局"
	_reset_confirmation.dialog_text = "确认恢复默认布局吗？"
	_reset_confirmation.confirmed.connect(_apply_editor_reset)
	add_child(_reset_confirmation)
	_cancel_confirmation = ThemedDialog.new()
	_cancel_confirmation.in_game = true
	_cancel_confirmation.title = "放弃虚拟按键设置"
	_cancel_confirmation.dialog_text = "确认放弃未保存的虚拟按键设置吗？"
	_cancel_confirmation.confirmed.connect(_apply_editor_cancel)
	add_child(_cancel_confirmation)
	_single_cancel = ThemedDialog.new()
	_single_cancel.in_game = true
	_single_cancel.title = "放弃单键样式设置"
	_single_cancel.dialog_text = "确认放弃本次单键样式设置吗？"
	_single_cancel.confirmed.connect(_discard_single_editor)
	add_child(_single_cancel)
	_save_error = ThemedDialog.new()
	_save_error.in_game = true
	_save_error.title = "触控布局"
	_save_error.with_cancel = false
	add_child(_save_error)

func _editor_confirmation_visible() -> bool:
	return (_save_error and _save_error.is_open_or_opening()) or (_reset_confirmation and _reset_confirmation.is_open_or_opening()) \
			or (_cancel_confirmation and _cancel_confirmation.is_open_or_opening()) or (_single_cancel and _single_cancel.is_open_or_opening())

func _create_editor_panel() -> void:
	var general := _make_editor_panel("TouchLayoutEditor", "编辑虚拟按钮（横屏布局）")
	_editor_panel = general.node
	_editor_scroll = general.scroll
	_editor_heading = general.title
	_editor_column = general.column
	_editor_title_wrap = general.wrap
	var column: VBoxContainer = general.column
	_dock_option = _placement_option(_on_editor_dock_changed)
	column.add_child(_labeled_control("本窗口位置", _dock_option))
	_alignment_option = OptionButton.new()
	for text: String in ["默认", "底部", "居中", "自定义"]: _alignment_option.add_item(text)
	_alignment_option.item_selected.connect(_on_editor_alignment_changed)
	column.add_child(_labeled_control("主要按钮纵向位置", _alignment_option))
	_group_offset_slider = HSlider.new()
	_group_offset_slider.scrollable = false
	_group_offset_slider.min_value = -1.0
	_group_offset_slider.max_value = 1.0
	_group_offset_slider.step = 0.01
	_group_offset_slider.value_changed.connect(_on_editor_group_offset_changed)
	_group_offset_row = _labeled_control("自定义纵向位置", _group_offset_slider)
	column.add_child(_group_offset_row)
	_labels_check = CheckButton.new()
	_labels_check.text = "默认显示按钮文字"
	_labels_check.toggled.connect(_on_editor_labels_toggled)
	column.add_child(_labels_check)
	_opacity_slider = HSlider.new()
	_opacity_slider.scrollable = false
	_opacity_slider.min_value = 0.1
	_opacity_slider.max_value = 1.0
	_opacity_slider.step = 0.05
	_opacity_slider.value_changed.connect(_on_editor_opacity_changed)
	column.add_child(_labeled_control("按钮不透明度", _opacity_slider))

	var single := _make_editor_panel("SingleKeyEditor", "")
	_single_panel = single.node
	_selection_label = single.title
	column = single.column
	_single_dock_option = _placement_option(_on_single_dock_changed)
	column.add_child(_labeled_control("本窗口位置", _single_dock_option))
	_width_slider = _ratio_slider()
	_width_slider.value_changed.connect(_on_editor_width_changed)
	column.add_child(_labeled_control("按钮宽度", _width_slider))
	_height_slider = _ratio_slider()
	_height_slider.value_changed.connect(_on_editor_height_changed)
	column.add_child(_labeled_control("按钮高度", _height_slider))
	_visible_check = CheckButton.new()
	_visible_check.text = "暂时隐藏按钮"
	_visible_check.toggled.connect(_on_editor_control_visibility_toggled)
	column.add_child(_visible_check)
	_label_visible_check = CheckButton.new()
	_label_visible_check.text = "显示此按钮文字"
	_label_visible_check.toggled.connect(_on_label_visibility_toggled)
	column.add_child(_label_visible_check)
	_label_override = LineEdit.new()
	_label_override.expand_to_text_length = false
	_label_override.text_changed.connect(_on_editor_label_changed)
	column.add_child(_labeled_control("按钮文字标签", _label_override))
	_shape_option = OptionButton.new()
	_shape_option.add_item("圆形")
	_shape_option.add_item("圆角矩形")
	_shape_option.item_selected.connect(_on_editor_shape_changed)
	column.add_child(_labeled_control("按钮形状", _shape_option))
	_delete_button = Button.new()
	_delete_button.text = "删除此按钮"
	_delete_button.pressed.connect(_on_editor_delete_pressed)
	column.add_child(_delete_button)

	var adding := _make_editor_panel("AddTouchButton", "选择需要添加的按钮")
	_add_panel = adding.node
	column = adding.column
	_catalog_search = LineEdit.new()
	_catalog_search.placeholder_text = "搜索名称、标签或 ID"
	_catalog_search.expand_to_text_length = false
	_catalog_search.text_changed.connect(_on_catalog_filter_changed)
	column.add_child(_catalog_search)
	_catalog_category = OptionButton.new()
	for category in EasyRPGKeyCatalog.categories(): _catalog_category.add_item(category)
	_catalog_category.item_selected.connect(_on_catalog_category_changed)
	column.add_child(_catalog_category)
	_catalog_list = ItemList.new()
	_catalog_list.custom_minimum_size = Vector2(0, Metrics.dp(170))
	_catalog_list.select_mode = ItemList.SELECT_SINGLE
	column.add_child(_catalog_list)
	var add_button := Button.new()
	add_button.text = "添加所选按键"
	add_button.pressed.connect(_on_editor_add_pressed)
	column.add_child(add_button)

	_selection_prompt = PanelContainer.new()
	_selection_prompt.z_index = 100
	_selection_prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_selection_prompt.theme = UiTheme.theme(true)
	var prompt := Label.new()
	prompt.text = "请选择待编辑的按钮"
	prompt.set_meta(&"android_plain_text", true)
	prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_selection_prompt.add_child(prompt)
	add_child(_selection_prompt)
	_selection_prompt.hide()

func _make_editor_panel(title_name: String, heading: String) -> Dictionary:
	var panel := PanelContainer.new()
	panel.name = title_name
	panel.z_index = 100
	panel.theme = UiTheme.theme(true)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(panel)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.set_meta(&"android_section_spacing", true)
	scroll.add_child(column)
	var title := Label.new()
	title.text = heading
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var wrap := MarginContainer.new()
	wrap.add_child(title)
	column.add_child(wrap)
	var data := {"node": panel, "scroll": scroll, "column": column, "title": title, "wrap": wrap}
	_panels.append(data)
	panel.hide()
	return data

func _placement_option(action: Callable) -> OptionButton:
	var option := OptionButton.new()
	for text: String in ["左侧", "居中", "右侧"]: option.add_item(text)
	option.item_selected.connect(action)
	return option

func _ratio_slider() -> HSlider:
	var slider := HSlider.new()
	slider.scrollable = false
	slider.custom_minimum_size.y = Metrics.dp(48)
	slider.min_value = 0.15
	slider.max_value = 3.0
	slider.step = 0.05
	return slider

func _labeled_control(label_text: String, control: Control) -> Control:
	var column := VBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	column.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(control)
	return column

func _layout_editor_ui() -> void:
	if not _editor_open: return
	if not _editor_toolbar or not _editor_panel: return
	for field: LineEdit in [_label_override, _catalog_search]:
		preload("res://cogs/input_field_style.gd").apply(field, UiTheme.factor())
		field.custom_minimum_size.y = UiTheme.px(32)
	var safe := _safe_rect()
	var pad := float(Metrics.dp(8))
	for toolbar: PanelContainer in [_editor_toolbar, _single_toolbar]:
		toolbar.theme = UiTheme.theme(true)
		UiTheme.apply_tree(toolbar, true)
		var grid := toolbar.get_child(0) as GridContainer
		for columns: int in [4, 2, 1]:
			grid.columns = columns
			if grid.get_combined_minimum_size().x <= safe.size.x - pad * 2: break
		toolbar.size = Vector2.ZERO
		toolbar.position = safe.position + Vector2.ONE * pad
	var toolbar := _single_toolbar if _single_editing else _editor_toolbar
	var top := safe.position.y + toolbar.get_combined_minimum_size().y + pad * 2
	var available := Vector2(maxf(1, safe.size.x - pad * 2), maxf(1, safe.end.y - top - pad))
	for data: Dictionary in _panels:
		var panel: PanelContainer = data.node
		panel.theme = UiTheme.theme(true)
		UiTheme.apply_tree(panel, true)
		panel.add_theme_stylebox_override("panel", UiTheme.titled_frame(data.title))
		UiTheme.title_gap(data.title, data.column, data.wrap)
		UiTheme.scrollbar(data.scroll, true, UiTheme.px(4))
		var width := minf(_panel_content_width(data) + UiTheme.px(32) + UiTheme.px(8), available.x)
		var frame := panel.get_theme_stylebox("panel")
		var height := minf(data.column.get_combined_minimum_size().y + frame.get_minimum_size().y, available.y)
		panel.size = Vector2(width, maxf(1, height))
		var dock := _panel_dock if panel == _editor_panel else (_single_dock if panel == _single_panel else "center")
		var x := safe.get_center().x - width * 0.5
		if dock == "left": x = safe.position.x + pad
		elif dock == "right": x = safe.end.x - pad - width
		var y := maxf(top, safe.get_center().y - panel.size.y * 0.5) if dock == "center" else top
		panel.position = Vector2(x, y)
	UiTheme.style_bar(_catalog_list.get_v_scroll_bar(), false, UiTheme.px(4))
	_selection_prompt.theme = UiTheme.theme(true)
	UiTheme.apply_tree(_selection_prompt, true)
	var style := UiTheme.frame(4)
	var button_style := _toolbar_expand.get_theme_stylebox("normal")
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		style.set_content_margin(side, button_style.get_content_margin(side))
	_selection_prompt.add_theme_stylebox_override("panel", style)
	_selection_prompt.size = Vector2.ZERO
	_selection_prompt.position = Vector2(safe.get_center().x - _selection_prompt.size.x * 0.5, safe.end.y - pad - _selection_prompt.size.y)

func _panel_content_width(data: Dictionary) -> float:
	var width := _natural_text_width(data.column)
	if data.node == _single_panel:
		for entry: Dictionary in _catalog_entries:
			width = maxf(width, _measure_text(_selection_label, _entry_title(entry)))
		for layout: Array in _layouts.values():
			for control: Dictionary in layout: width = maxf(width, _measure_text(_selection_label, _entry_title(control)))
	if data.node == _add_panel:
		for entry: Dictionary in _catalog_entries:
			width = maxf(width, _measure_text(_catalog_list, _catalog_text(entry)) + UiTheme.px(12))
	return width

func _measure_text(control: Control, text: String) -> float:
	return control.get_theme_font("font").get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, control.get_theme_font_size("font_size")).x

func _natural_text_width(node: Node) -> float:
	var width := 0.0
	if node is OptionButton:
		for index in node.item_count: width = maxf(width, _measure_text(node, node.get_item_text(index)))
		width += node.get_theme_stylebox("normal").get_content_margin(SIDE_LEFT) + _measure_text(node, "汉") * 1.5
	elif node is Button:
		width = _measure_text(node, node.text) + node.get_theme_stylebox("normal").get_minimum_size().x
		if node is CheckButton: width += node.get_theme_icon("checked").get_width() + node.get_theme_constant("h_separation")
	elif node is Label: width = _measure_text(node, node.text)
	for child in node.get_children(): width = maxf(width, _natural_text_width(child))
	return width

func _refresh_editor_ui() -> void:
	if not _editor_panel: return
	_updating_editor_ui = true
	_editor_heading.text = "编辑虚拟按钮（%s布局）" % ("横屏" if _edit_orientation == "landscape" else "竖屏")
	_toolbar_expand.set_pressed_no_signal(_active_panel == "general")
	_dock_option.select(["left", "center", "right"].find(_panel_dock))
	_single_dock_option.select(["left", "center", "right"].find(_single_dock))
	_opacity_slider.set_value_no_signal(_opacity)
	_labels_check.set_pressed_no_signal(_show_key_labels)
	var controls := _active_layout()
	var has_selection := _selected_index >= 0 and _selected_index < controls.size()
	var has_group := controls.any(func(control): return str(control.get("web_slot", "")) in BOTTOM_SLOTS)
	_alignment_option.disabled = not has_group
	var group: Dictionary = _group_settings[_edit_orientation]
	_alignment_option.select(ALIGNMENTS.find(group.alignment))
	_group_offset_slider.editable = has_group and group.alignment == "custom"
	_group_offset_row.modulate.a = 1.0 if _group_offset_slider.editable else 0.45
	var offset := _effective_custom_offset() if group.has("legacy_custom_basis") and group.alignment == "custom" else float(group.offset)
	_group_offset_slider.min_value = minf(-1, offset)
	_group_offset_slider.max_value = maxf(1, offset)
	_group_offset_slider.set_value_no_signal(offset)
	_width_slider.editable = has_selection
	_height_slider.editable = has_selection
	_visible_check.disabled = not has_selection
	_label_override.editable = has_selection
	_label_visible_check.disabled = not has_selection
	_shape_option.disabled = not has_selection
	_delete_button.disabled = not has_selection
	if has_selection:
		var control: Dictionary = controls[_selected_index]
		var is_dpad := str(control.get("type", "key")) == "dpad"
		_selection_label.text = _entry_title(control)
		var ratio: Vector2 = _control_nodes[_selected_index].size / _free_control_unit(_edit_orientation)
		_width_slider.set_value_no_signal(ratio.x)
		_height_slider.set_value_no_signal(ratio.y)
		_height_slider.editable = not is_dpad
		_visible_check.set_pressed_no_signal(not bool(control.get("visible", true)))
		_label_visible_check.set_pressed_no_signal(bool(control.get("label_visible_override", _show_key_labels)))
		_label_visible_check.disabled = is_dpad
		_label_override.editable = not is_dpad
		_label_override.text = str(control.get("display_label", ""))
		_shape_option.select(_shape_index(str(control.get("shape", "circle"))))
		_shape_option.disabled = is_dpad
	else:
		_selection_label.text = "请选择待编辑的按钮"
		_label_override.text = ""
	_updating_editor_ui = false
	_update_history_buttons()
	_update_control_visibility()
	_layout_editor_ui()

func _entry_title(control: Dictionary) -> String:
	if control.get("type") == "dpad": return "Dpad"
	if control.get("type") == "app_action": return "T（聊天）" if control.get("app_action") == "chat_focus" else "`（控制台）"
	return "%s / ID %d" % [control.get("key_name", ""), int(control.get("key_id", -1))]

func _shape_index(shape: String) -> int:
	return 0 if shape == "circle" else 1

func _refresh_catalog() -> void:
	if not _catalog_list:
		return
	_filtered_catalog.clear()
	_catalog_list.clear()
	var search := _catalog_search.text.strip_edges().to_lower() if _catalog_search else ""
	var category := "全部类别"
	if _catalog_category and _catalog_category.selected >= 0:
		category = _catalog_category.get_item_text(_catalog_category.selected)
	for raw_entry in _catalog_entries:
		var entry: Dictionary = raw_entry
		if category == "梦日记派生常用" and not EasyRPGKeyCatalog.is_common(entry): continue
		if category not in ["全部类别", "梦日记派生常用"] and str(entry.get("category", "")) != category:
			continue
		var haystack := "%s %s %d" % [entry.get("key_name", ""), entry.get("display_label", ""), int(entry.get("key_id", -1))]
		if not search.is_empty() and search not in haystack.to_lower():
			continue
		_filtered_catalog.append(entry)
		_catalog_list.add_item(_catalog_text(entry))
	if _catalog_list.item_count > 0:
		_catalog_list.select(0)

func _on_toolbar_expand_pressed() -> void:
	_set_panel("" if _active_panel == "general" else "general")

func _on_editor_dock_changed(index: int) -> void:
	if _updating_editor_ui: return
	_panel_dock = ["left", "center", "right"][clampi(index, 0, 2)]
	_layout_editor_ui()



func _on_editor_alignment_changed(index: int) -> void:
	if _updating_editor_ui or _alignment_option.disabled: return
	_finish_edit()
	_begin_edit("alignment")
	var group: Dictionary = _group_settings[_edit_orientation]
	if ALIGNMENTS[index] == "custom" and not group.get("custom_initialized", false):
		group.offset = _effective_custom_offset()
		group["custom_initialized"] = true
	group.alignment = ALIGNMENTS[index]
	_release_all_keys()
	_layout_controls()
	_finish_edit()
	_refresh_editor_ui()

func _on_editor_group_offset_changed(value: float) -> void:
	if _updating_editor_ui or not _group_offset_slider.editable: return
	var group: Dictionary = _group_settings[_edit_orientation]
	var previous := _effective_custom_offset() if group.has("legacy_custom_basis") else float(group.offset)
	if is_equal_approx(previous, value): return
	_begin_edit("slider:%s" % _group_offset_slider.get_instance_id())
	group.offset = value
	group["custom_initialized"] = true
	group.erase("legacy_custom_basis")
	_layout_controls()

func _on_editor_opacity_changed(value: float) -> void:
	if _updating_editor_ui: return
	_begin_edit("slider:%s" % _opacity_slider.get_instance_id())
	_opacity = value
	_refresh_control_appearance()


func _on_editor_labels_toggled(value: bool) -> void:
	if _updating_editor_ui: return
	_begin_edit("labels")
	_show_key_labels = value
	_refresh_control_appearance()
	_finish_edit()


func _on_editor_width_changed(value: float) -> void:
	if _updating_editor_ui:
		return
	var controls := _active_layout()
	if _selected_index < 0 or _selected_index >= controls.size():
		return
	var control: Dictionary = controls[_selected_index]
	_begin_edit("slider:%s" % _width_slider.get_instance_id())
	_detach_default_position(control, _selected_index)
	control["width_ratio"] = value
	if str(control.get("type", "")) == "dpad":
		control["height_ratio"] = value
	controls[_selected_index] = control
	_position_control(_selected_index)
	_refresh_editor_ui()

func _on_editor_height_changed(value: float) -> void:
	if _updating_editor_ui:
		return
	var controls := _active_layout()
	if _selected_index < 0 or _selected_index >= controls.size():
		return
	var control: Dictionary = controls[_selected_index]
	if str(control.get("type", "")) == "dpad":
		return
	_begin_edit("slider:%s" % _height_slider.get_instance_id())
	_detach_default_position(control, _selected_index)
	control["height_ratio"] = value
	controls[_selected_index] = control
	_position_control(_selected_index)
	_refresh_editor_ui()

func _on_editor_control_visibility_toggled(value: bool) -> void:
	if _updating_editor_ui:
		return
	var controls := _active_layout()
	if _selected_index < 0 or _selected_index >= controls.size():
		return
	var control: Dictionary = controls[_selected_index]
	_begin_edit("visibility")
	control["visible"] = not value
	controls[_selected_index] = control
	_rebuild_controls()
	_refresh_editor_ui()
	_finish_edit()

func _on_editor_label_changed(value: String) -> void:
	if _updating_editor_ui:
		return
	var controls := _active_layout()
	if _selected_index < 0 or _selected_index >= controls.size():
		return
	var control: Dictionary = controls[_selected_index]
	if control.get("display_label", "") == value: return
	_begin_edit("label")
	control["display_label"] = value
	controls[_selected_index] = control
	_control_nodes[_selected_index].display_label = value
	_control_nodes[_selected_index].queue_redraw()

func _on_editor_shape_changed(index: int) -> void:
	if _updating_editor_ui:
		return
	var controls := _active_layout()
	if _selected_index < 0 or _selected_index >= controls.size():
		return
	var control: Dictionary = controls[_selected_index]
	if str(control.get("type", "")) not in ["key", "app_action"]:
		return
	_begin_edit("shape")
	control["shape"] = ["circle", "rectangle"][clampi(index, 0, 1)]
	controls[_selected_index] = control
	_rebuild_controls()
	_refresh_editor_ui()
	_finish_edit()

func _on_catalog_filter_changed(_value: String) -> void:
	_refresh_catalog()

func _on_catalog_category_changed(_index: int) -> void:
	_refresh_catalog()

func _on_editor_add_pressed() -> void:
	var selected_items := _catalog_list.get_selected_items()
	if selected_items.is_empty():
		return
	var filtered_index := int(selected_items[0])
	if filtered_index < 0 or filtered_index >= _filtered_catalog.size():
		return
	var entry: Dictionary = _filtered_catalog[filtered_index]
	var controls := _active_layout()
	_begin_edit("add")
	if entry.get("type") == "dpad":
		var dpad := _dpad_control()
		dpad.normalized_x = 0.5
		dpad.normalized_y = 0.5
		controls.append(dpad)
	elif entry.get("type") == "app_action": controls.append(_app_action_control(entry.app_action, entry.display_label))
	else: controls.append(_key_control(int(entry.key_id), str(entry.key_name), str(entry.display_label), "circle", 0.7, 0.7))
	_selected_index = controls.size() - 1
	_rebuild_controls()
	_refresh_editor_ui()
	_finish_edit()

func _on_editor_add_console_pressed() -> void:
	_begin_edit("add")
	var controls := _active_layout()
	controls.append(_app_action_control("limbo_console_toggle", "Console"))
	_selected_index = controls.size() - 1
	_rebuild_controls()
	_refresh_editor_ui()
	_finish_edit()

func _on_editor_add_chat_pressed() -> void:
	_begin_edit("add")
	var controls := _active_layout()
	controls.append(_app_action_control("chat_focus", "T"))
	_selected_index = controls.size() - 1
	_rebuild_controls()
	_refresh_editor_ui()
	_finish_edit()

func _on_editor_delete_pressed() -> void:
	var controls := _active_layout()
	if _selected_index < 0 or _selected_index >= controls.size():
		return
	_begin_edit("delete")
	editor_fields_invalidated.emit()
	controls.remove_at(_selected_index)
	_selected_index = -1
	_rebuild_controls()
	_refresh_editor_ui()
	_finish_edit()

func _on_editor_reset_pressed() -> void:
	_finish_edit()
	_release_all_keys()
	_reset_confirmation.open()

func _apply_editor_reset() -> void:
	_begin_edit("reset")
	editor_fields_invalidated.emit()
	_restore_web_layouts()
	_selected_index = -1
	_rebuild_controls()
	_refresh_editor_ui()
	_finish_edit()

func _on_editor_save_pressed() -> void:
	_finish_edit()
	_release_all_keys()
	editor_fields_invalidated.emit()
	if _save_config():
		_close_editor()

func _on_editor_cancel_pressed() -> void:
	_request_editor_cancel()

func _request_editor_cancel() -> void:
	if not _editor_open or not _cancel_confirmation:
		return
	_finish_edit()
	_release_all_keys()
	if _same_edit_state(_capture_edit_state(), _editor_snapshot): _apply_editor_cancel()
	else: _cancel_confirmation.open()

func _apply_editor_cancel() -> void:
	_restore_editor_snapshot()
	_close_editor()


func _close_editor() -> void:
	_release_all_keys()
	editor_fields_invalidated.emit()
	for dialog: ThemedDialog in [_reset_confirmation, _cancel_confirmation, _single_cancel, _save_error]:
		dialog.dismiss()
	_editor_open = false
	_single_editing = false
	_active_panel = ""
	_clear_history()
	_preview_pending = ""
	_editor_snapshot.clear()
	_selected_index = -1
	_panel_collapsed = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rebuild_controls()
	editor_changed.emit()


func _on_window_focus_exited() -> void:
	_finish_edit()
	_release_all_keys()

func _on_controller_visibility_changed() -> void:
	if not visible:
		_finish_edit()
		_release_all_keys()

func _restore_editor_snapshot() -> void:
	if _editor_snapshot.is_empty(): return
	_layouts = _editor_snapshot.layouts.duplicate(true)
	_group_settings = _editor_snapshot.group_settings.duplicate(true)
	_enabled = _editor_snapshot.enabled
	_opacity = _editor_snapshot.opacity
	_show_key_labels = _editor_snapshot.show_key_labels
	_panel_dock = _editor_snapshot.panel_dock


func release_touches() -> void:
	_finish_edit()
	_release_all_keys()


func set_controls_enabled(value: bool) -> Error:
	# The drawer edits the committed visibility only, never an editor draft.
	if _editor_open: return ERR_BUSY
	var config := ConfigFile.new()
	config.load(config_path)
	config.set_value("general", "enabled", value)
	var error := config.save(config_path)
	if error == OK:
		_enabled = value
		_release_all_keys()
		_update_control_visibility()
	return error


func _layout() -> void:
	_finish_edit()
	_release_all_keys()
	if _scroll_gesture: _scroll_gesture.cancel()
	if _catalog_gesture: _catalog_gesture.cancel()
	var orientation := _orientation_name()
	if _editor_open:
		if _edit_orientation != orientation:
			editor_fields_invalidated.emit()
			_edit_orientation = orientation
			_selected_index = -1
			if _single_editing: _active_panel = ""
			_rebuild_controls()
			_refresh_editor_ui()
	elif _last_orientation != orientation:
		_last_orientation = orientation
		_rebuild_controls()
	_layout_controls()


func _refresh_control_appearance() -> void:
	var controls := _active_layout()
	for index in _control_nodes.size():
		_control_nodes[index].configure(controls[index], _opacity, _show_key_labels)
	_rebuild_selection_visuals()


func input_fields() -> Array[Control]:
	return [_label_override, _catalog_search]


func field_available(field: Control = null) -> bool:
	if not _editor_open or _editor_confirmation_visible(): return false
	if field == _label_override: return _single_panel.visible and _label_override.editable and _selected_index >= 0
	if field == _catalog_search: return _add_panel.visible
	return false

func _size_editor_controls(node: Node) -> void:
	if node is Button:
		node.custom_minimum_size = Vector2.ZERO
		node.clip_text = node is OptionButton
		if not node is OptionButton:
			node.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	elif node is HSlider:
		node.custom_minimum_size.y = Metrics.dp(48)
	elif node is Label:
		node.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	for child in node.get_children(): _size_editor_controls(child)

# Editing snapshots contain data only; UI selection travels with history but is not dirty state.
func _capture_edit_state() -> Dictionary:
	return {"layouts": _layouts.duplicate(true), "group_settings": _group_settings.duplicate(true),
		"enabled": _enabled, "opacity": _opacity, "show_key_labels": _show_key_labels,
		"panel_dock": _panel_dock, "orientation": _edit_orientation, "selection": _selected_index}

func _same_edit_state(a: Dictionary, b: Dictionary) -> bool:
	for key: String in ["layouts", "group_settings", "enabled", "opacity", "show_key_labels"]:
		if a.get(key) != b.get(key): return false
	return true

func _begin_edit(kind: String) -> void:
	if not _editor_open or _restoring_history: return
	if not _pending_edit.is_empty() and _pending_kind != kind: _finish_edit()
	if _pending_edit.is_empty():
		_pending_edit = _capture_edit_state()
		_pending_kind = kind
	_update_history_buttons()

func _finish_edit() -> void:
	if _pending_edit.is_empty(): return
	var before := _pending_edit
	_pending_edit = {}
	_pending_kind = ""
	var after := _capture_edit_state()
	if not _same_edit_state(before, after):
		_record_edit(before, after, _single_undo if _single_editing else _undo, _single_redo if _single_editing else _redo)
	_update_history_buttons()

func _record_edit(before: Dictionary, after: Dictionary, undo: Array, redo: Array) -> void:
	undo.append({"before": before.duplicate(true), "after": after.duplicate(true)})
	if undo.size() > HISTORY_LIMIT: undo.pop_front()
	redo.clear()

func _apply_history_state(state: Dictionary) -> void:
	editor_fields_invalidated.emit()
	_release_all_keys()
	_restoring_history = true
	_layouts = state.layouts.duplicate(true)
	_group_settings = state.group_settings.duplicate(true)
	_enabled = state.enabled
	_opacity = state.opacity
	_show_key_labels = state.show_key_labels
	_selected_index = int(state.selection) if state.orientation == _edit_orientation else -1
	if _selected_index >= _active_layout().size(): _selected_index = -1
	if _single_editing: _active_panel = "single" if _selected_index >= 0 else ""
	_rebuild_controls()
	_refresh_editor_ui()
	_restoring_history = false

func _undo_edit() -> void:
	_finish_edit()
	var undo := _single_undo if _single_editing else _undo
	var redo := _single_redo if _single_editing else _redo
	if undo.is_empty(): return
	var step: Dictionary = undo.pop_back()
	redo.append(step)
	_apply_history_state(step.before)

func _redo_edit() -> void:
	_finish_edit()
	var undo := _single_undo if _single_editing else _undo
	var redo := _single_redo if _single_editing else _redo
	if redo.is_empty(): return
	var step: Dictionary = redo.pop_back()
	undo.append(step)
	_apply_history_state(step.after)

func _update_history_buttons() -> void:
	var undo := _single_undo if _single_editing else _undo
	var redo := _single_redo if _single_editing else _redo
	for button in _undo_buttons: button.disabled = undo.is_empty() and _pending_edit.is_empty()
	for button in _redo_buttons: button.disabled = redo.is_empty()

func _clear_history() -> void:
	_undo.clear()
	_redo.clear()
	_single_undo.clear()
	_single_redo.clear()
	_single_snapshot.clear()
	_pending_edit.clear()
	_pending_kind = ""

func _set_panel(panel: String) -> void:
	_finish_edit()
	_release_all_keys()
	editor_fields_invalidated.emit()
	for data: Dictionary in _panels:
		if data.has("gesture"): data.gesture.cancel()
	_active_panel = panel
	_refresh_editor_ui()

func _toggle_add_panel() -> void:
	_set_panel("" if _active_panel == "add" else "add")

func _enter_single_editor() -> void:
	_finish_edit()
	_release_all_keys()
	editor_fields_invalidated.emit()
	_single_snapshot = _capture_edit_state()
	_single_undo.clear()
	_single_redo.clear()
	_single_editing = true
	_selected_index = -1
	_single_dock = "center"
	_set_panel("")

func _save_single_editor() -> void:
	_finish_edit()
	var after := _capture_edit_state()
	if not _same_edit_state(_single_snapshot, after): _record_edit(_single_snapshot, after, _undo, _redo)
	_leave_single_editor()

func _request_single_cancel() -> void:
	_finish_edit()
	_release_all_keys()
	if _same_edit_state(_capture_edit_state(), _single_snapshot): _discard_single_editor()
	else: _single_cancel.open()

func _discard_single_editor() -> void:
	_pending_edit.clear()
	_apply_history_state(_single_snapshot)
	_leave_single_editor()

func _leave_single_editor() -> void:
	editor_fields_invalidated.emit()
	_release_all_keys()
	_single_editing = false
	_single_snapshot.clear()
	_single_undo.clear()
	_single_redo.clear()
	_selected_index = -1
	_set_panel("")

func _on_single_dock_changed(index: int) -> void:
	if _updating_editor_ui: return
	_single_dock = ["left", "center", "right"][clampi(index, 0, 2)]
	_layout_editor_ui()

func _on_label_visibility_toggled(value: bool) -> void:
	if _updating_editor_ui or _selected_index < 0: return
	_begin_edit("label_visibility")
	_active_layout()[_selected_index]["label_visible_override"] = value
	_refresh_control_appearance()
	_finish_edit()

func _catalog_text(entry: Dictionary) -> String:
	if entry.get("type") == "dpad": return "Dpad"
	if entry.get("type") == "app_action": return _entry_title(entry)
	return "%s  ·  %s  ·  ID %d" % [entry.display_label, entry.key_name, entry.key_id]
