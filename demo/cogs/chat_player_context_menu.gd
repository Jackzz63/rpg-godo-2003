class_name ChatPlayerContextMenu
extends Node

const PopupGeometryScript := preload("res://cogs/popup_geometry.gd")
const PlayerName := preload("res://cogs/chat_player_name.gd")

signal mention_requested(player_meta: Dictionary)
signal right_click_started
signal right_click_released(position: Vector2)

const _GAME_UI_FONT := preload("res://resources/webpage_game_ui_font.tres")
const _WEBPAGE_THEME_TEXT_RUNTIME := preload("res://cogs/webpage_theme_text_runtime.gd")
const _IP_ICON := preload("res://resources/icons/ip.svg")
const _GAME_UI_SHADOW_COLOR := Color(0.0, 0.0, 0.0, 1.0)
const _MUTE_COLOR := Color(1.0, 0.62, 0.18, 1.0)
const _BAN_COLOR := Color(1.0, 0.24, 0.18, 1.0)

var _mp_connection: EasyMultiplayer = null
var _chat_selection: Control = null
var _player_meta: Dictionary = {}
var _display_language := "en"
var _pending_request_id := 0
var _pending_action := ""
var _pending_kind := ""
var _pending_duration_seconds := 0
var _pending_duration_mode := "finite"
var _pending_include_network := false
var _editing_record: Dictionary = {}
var _network_unavailable_reason := ""

var _context_popup: PopupPanel
var _context_anchor_ratio := Vector2.ZERO
var _context_anchor_control: WeakRef = null
var _context_anchor_local := Vector2.ZERO
var _context_anchor_kind := "control"
var _context_text_anchor: Dictionary = {}
var _context_anchor_pending := false
var _context_player_resolver: Callable
var _right_click_held := false
var other_context_requested: Callable
var _action_row_states: Dictionary = {}
var _action_visibility: Array = []
var _context_content: MarginContainer
var _context_rows: VBoxContainer
var _mention_button: Button
var _mention_row: HBoxContainer
var _mute_button: Button
var _mute_row: HBoxContainer
var _mute_revoke_button: Button
var _mute_revoke_row: HBoxContainer
var _ban_button: Button
var _ban_row: HBoxContainer
var _ban_revoke_button: Button
var _ban_revoke_row: HBoxContainer
var _copy_button: Button
var _copy_row: HBoxContainer
var _select_all_button: Button
var _select_all_row: HBoxContainer

var _moderation_popup: PopupPanel
var _moderation_content: MarginContainer
var _moderation_title: HBoxContainer
var _moderation_title_spacing: Node
var _duration_options: OptionButton
var _custom_row: HBoxContainer
var _custom_duration: SpinBox
var _custom_unit: OptionButton
var _network_row: HBoxContainer
var _network_icon: TextureRect
var _network_checkbox: CheckBox
var _network_square: Panel
var _network_checkmark: TextureRect
var _network_checkbox_icons: Dictionary = {}
var _network_icon_scale := -1.0
var _network_help: Button
var _moderation_status: Label
var _moderation_scroll: ScrollContainer
var _moderation_fields: VBoxContainer
var _moderation_footer: Node
var _ui_normal_color := Color.WHITE
var _ui_strong_color := Color(1.0, 0.82, 0.28, 1.0)
var _ui_muted_color := Color(0.58, 0.58, 0.62, 1.0)
var _theme_text_runtime: Node = null
var _popup_geometry_refresh_pending := false
var _popup_geometry_refresh_serial := 0
var _context_open_serial := 0
var _moderation_open_serial := 0


var _context_requested := false


func _ready() -> void:
	UiScale.safe_area_changed.connect(_queue_popup_geometry_refresh)
	_theme_text_runtime = _WEBPAGE_THEME_TEXT_RUNTIME.new()
	add_child(_theme_text_runtime)
	_build_context_popup()
	_build_moderation_popup()
	_apply_game_ui_text_style(_moderation_popup)
	_refresh_network_row_style()
	var root_viewport := get_tree().root
	if not root_viewport.size_changed.is_connected(_queue_popup_geometry_refresh):
		root_viewport.size_changed.connect(_queue_popup_geometry_refresh)
	if not UiScale.scale_changed.is_connected(_queue_popup_geometry_refresh):
		UiScale.scale_changed.connect(_queue_popup_geometry_refresh)


var _theme_source_override: Node


func set_theme_source(source: Node) -> void:
	if source != _theme_source_override:
		_action_row_states.clear()
	_theme_source_override = source


func _theme_source() -> Node:
	return _theme_source_override if is_instance_valid(_theme_source_override) else _mp_connection


func set_ui_theme_colors(normal: Color, strong: Color, muted: Color) -> void:
	_action_row_states.clear()
	_ui_normal_color = normal
	_ui_strong_color = strong
	_ui_muted_color = muted
	if is_instance_valid(_theme_text_runtime):
		_theme_text_runtime.clear_caches()
	if is_instance_valid(_moderation_popup):
		_apply_game_ui_text_style(_moderation_popup)
		_refresh_network_row_style()
	if is_instance_valid(_moderation_title) and not _pending_kind.is_empty():
		_fill_moderation_title(
			_pending_kind, str(_player_meta.get("display_name", "")))
	if is_instance_valid(_context_popup) and _context_requested:
		_refresh_player_actions()


func setup(connection: EasyMultiplayer, selection: Control) -> void:
	_chat_selection = selection
	set_multiplayer_connection(connection)


func set_display_language(language: String) -> void:
	# Language refresh replaces player-list cards. Preserve this menu's screen
	# anchor before its old control is freed; the selected identity stays raw.
	if _context_anchor_kind == "control" and _context_anchor_control != null:
		var anchor: Variant = _resolved_context_anchor()
		if anchor != null:
			_context_anchor_ratio = PopupGeometryScript.anchor_ratio(_context_popup, anchor)
		_context_anchor_control = null
	_display_language = language
	if not is_node_ready():
		return
	if not _player_meta.is_empty():
		_fill_action_row(_mention_button, _mention_row, "@ ")
		_refresh_player_actions()
	if not _pending_kind.is_empty():
		_fill_moderation_title(_pending_kind, str(_editing_record.get("last_name", _player_meta.get("display_name", ""))))
	_queue_popup_geometry_refresh()


func set_multiplayer_connection(connection: EasyMultiplayer) -> void:
	if connection != _mp_connection:
		dismiss()
	if is_instance_valid(_mp_connection):
		var auth_callback := Callable(self, "_on_admin_authentication_changed")
		if _mp_connection.admin_authentication_changed.is_connected(auth_callback):
			_mp_connection.admin_authentication_changed.disconnect(auth_callback)
		var result_callback := Callable(self, "_on_admin_action_result")
		if _mp_connection.admin_action_result.is_connected(result_callback):
			_mp_connection.admin_action_result.disconnect(result_callback)
		var bans_callback := Callable(self, "_on_admin_snapshot_changed")
		if _mp_connection.admin_bans_received.is_connected(bans_callback):
			_mp_connection.admin_bans_received.disconnect(bans_callback)
		var roster_callback := Callable(self, "_on_admin_snapshot_changed")
		if _mp_connection.admin_roster_received.is_connected(roster_callback):
			_mp_connection.admin_roster_received.disconnect(roster_callback)
	_mp_connection = connection
	_action_row_states.clear()
	if is_instance_valid(_theme_text_runtime):
		_theme_text_runtime.clear_caches()
		# The local theme can already be loaded before networking is attached.
		# Restyle existing form controls when their source changes as well.
		_apply_game_ui_text_style(_moderation_popup)
		_refresh_network_row_style()
	if is_instance_valid(_mp_connection):
		_mp_connection.admin_authentication_changed.connect(_on_admin_authentication_changed)
		_mp_connection.admin_action_result.connect(_on_admin_action_result)
		_mp_connection.admin_bans_received.connect(_on_admin_snapshot_changed)
		_mp_connection.admin_roster_received.connect(_on_admin_snapshot_changed)
	_update_admin_visibility()


func open_player_menu(
		player_meta: Dictionary,
		global_position: Vector2, player_resolver: Callable = Callable()) -> void:
	_close_moderation()
	_player_meta = player_meta.duplicate(true)
	if (int(_player_meta.get("sender_id", _player_meta.get("pid", 0))) <= 0
			and str(_player_meta.get("public_chat_id", "")).is_empty()
			and str(_player_meta.get("subject_group_id", "")).is_empty()):
		return
	_subject_group_id()
	_refresh_player_actions()
	# Popup chrome follows the local client's active theme. The nickname pieces
	# populated above deliberately keep the selected player's theme source.
	_open_context_popup(global_position, "", -1, {}, player_resolver)
	if is_instance_valid(_mp_connection) and _mp_connection.is_admin_authenticated():
		_mp_connection.request_admin_context_snapshot()


func open_text_menu(global_position: Vector2) -> void:
	if (is_instance_valid(_chat_selection)
			and _chat_selection.has_method("is_layout_pending")
			and bool(_chat_selection.call("is_layout_pending"))):
		return
	_close_moderation()
	_player_meta.clear()
	_copy_button.disabled = (
		not is_instance_valid(_chat_selection)
		or str(_chat_selection.call("get_selected_text")).is_empty())
	_fill_local_action(_select_all_button, _select_all_row, "全选", 0)
	_fill_local_action(_copy_button, _copy_row, "复制", 3 if _copy_button.disabled else 0)
	_update_admin_visibility()
	var text_anchor: Dictionary = {}
	if (is_instance_valid(_chat_selection)
			and _chat_selection.has_method("capture_text_anchor")):
		var captured: Variant = _chat_selection.call(
			"capture_text_anchor", global_position)
		if captured is Dictionary:
			text_anchor = (captured as Dictionary).duplicate(true)
	_open_context_popup(global_position, "", -1, text_anchor)


func open_punishment_editor(record: Dictionary) -> void:
	if record.is_empty():
		return
	_player_meta = {
		"display_name": str(record.get("last_name", "")),
		"sender_id": int(record.get("online_pid", 0)),
		"subject_group_id": str(record.get("subject_group_id", "")),
		"system_name": str(record.get("system_name", "")),
	}
	_open_moderation_dialog(str(record.get("kind", "ban")), record)


func _open_context_popup(
		global_position: Vector2, system_name: String, stretch_mode: int,
		text_anchor: Dictionary = {}, player_resolver: Callable = Callable()) -> void:
	_context_requested = true
	_context_open_serial += 1
	var serial := _context_open_serial
	_capture_context_anchor(global_position, text_anchor)
	_context_player_resolver = player_resolver
	if player_resolver.is_valid():
		_context_anchor_kind = "player_list"
		_context_anchor_control = null
	_context_popup.min_size = Vector2i.ZERO
	SystemUISkin.install(_context_popup, _theme_source(), system_name, stretch_mode)
	_show_context_popup_after_layout(serial)


func _show_context_popup_after_layout(serial: int) -> void:
	await get_tree().process_frame
	if serial != _context_open_serial or not _context_requested:
		return
	_refit_context_action_buttons()
	await get_tree().process_frame
	if serial != _context_open_serial or not _context_requested:
		return
	var anchor: Variant = _resolved_context_anchor()
	if anchor == null:
		if not _context_anchor_pending:
			dismiss_context_menu()
		return
	var popup_rect := PopupGeometryScript.anchored_rect(
		_context_popup,
		_context_popup_size(),
		anchor as Vector2i,
		UiScale.physical_int(4.0))
	if _context_popup.visible:
		PopupGeometryScript.apply_rect(_context_popup, popup_rect)
	else:
		_context_popup.popup(popup_rect)
		await get_tree().process_frame
		if serial == _context_open_serial and _context_popup.visible:
			PopupGeometryScript.apply_rect(
				_context_popup,
				PopupGeometryScript.anchored_rect(
					_context_popup,
					_context_popup.size,
					anchor as Vector2i,
					UiScale.physical_int(4.0)))
	if serial == _context_open_serial and _context_popup.visible \
			and _context_anchor_kind == "player_list":
		_context_anchor_ratio = PopupGeometryScript.anchor_ratio(
			_context_popup, _context_popup.position)


func _build_context_popup() -> void:
	_context_popup = PopupPanel.new()
	_context_popup.name = "ChatPlayerContextPopup"
	_context_popup.transparent_bg = true
	_context_popup.wrap_controls = true
	_context_popup.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	_context_popup.popup_hide.connect(_cancel_context_request)
	watch_right_click_popup(_context_popup)
	add_child(_context_popup)

	_context_content = MarginContainer.new()
	_context_content.name = "ContextContent"
	_context_content.add_theme_constant_override("margin_left", 8)
	_context_content.add_theme_constant_override("margin_top", 8)
	_context_content.add_theme_constant_override("margin_right", 8)
	_context_content.add_theme_constant_override("margin_bottom", 8)
	_context_popup.add_child(_context_content)

	_context_rows = VBoxContainer.new()
	_context_rows.name = "ContextRows"
	_context_rows.add_theme_constant_override("separation", 0)
	_context_content.add_child(_context_rows)

	_mention_button = _new_texture_action("MentionAction", _on_mention_pressed)
	_mention_row = _mention_button.get_meta("texture_row") as HBoxContainer
	_mute_button = _new_texture_action("MuteAction", _on_mute_pressed)
	_mute_row = _mute_button.get_meta("texture_row") as HBoxContainer
	_mute_revoke_button = _new_texture_action(
		"MuteRevokeAction", _on_mute_revoke_pressed)
	_mute_revoke_row = _mute_revoke_button.get_meta("texture_row") as HBoxContainer
	_ban_button = _new_texture_action("BanAction", _on_ban_pressed)
	_ban_row = _ban_button.get_meta("texture_row") as HBoxContainer
	_ban_revoke_button = _new_texture_action(
		"BanRevokeAction", _on_ban_revoke_pressed)
	_ban_revoke_row = _ban_revoke_button.get_meta("texture_row") as HBoxContainer
	_select_all_button = _new_texture_action("SelectAllAction", _on_select_all_pressed)
	_select_all_row = _select_all_button.get_meta("texture_row") as HBoxContainer
	_copy_button = _new_texture_action("CopyAction", _on_copy_pressed)
	_copy_row = _copy_button.get_meta("texture_row") as HBoxContainer


func watch_right_click_popup(popup: PopupPanel) -> void:
	popup.window_input.connect(_on_context_window_input.bind(popup))


func _begin_right_click() -> void:
	dismiss_context_menu()
	right_click_started.emit()
	_right_click_held = true


# Also used by Android's local long-press replay, which does not pass through
# Window.window_input or update Input's global button mask.
func handle_right_click(event: InputEventMouseButton) -> bool:
	if event.button_index != MOUSE_BUTTON_RIGHT:
		return false
	if event.pressed:
		_begin_right_click()
		return false
	var completed := _right_click_held
	_right_click_held = false
	return completed


func _on_context_window_input(event: InputEvent, popup: PopupPanel) -> void:
	var mouse := event as InputEventMouseButton
	if mouse == null or mouse.button_index != MOUSE_BUTTON_RIGHT:
		return
	if mouse.pressed and not Rect2(Vector2.ZERO, Vector2(popup.size)).has_point(mouse.position):
		_begin_right_click()
		popup.set_input_as_handled()


func _input(event: InputEvent) -> void:
	var mouse := event as InputEventMouseButton
	if mouse == null or mouse.button_index != MOUSE_BUTTON_RIGHT:
		return
	if mouse.pressed:
		# A second click can cancel a menu still awaiting its first layout.
		if _context_requested or (other_context_requested.is_valid() and other_context_requested.call()):
			_begin_right_click()
			get_viewport().set_input_as_handled()
	elif _right_click_held:
		_right_click_held = false
		get_viewport().set_input_as_handled()
		right_click_released.emit(mouse.position)


func _new_texture_action(control_name: String, callback: Callable) -> Button:
	var button := Button.new()
	UiScale.mark_geometry_physical(button)
	button.name = control_name
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.flat = true
	button.focus_mode = Control.FOCUS_NONE
	for style_name in ["normal", "hover", "pressed", "focus", "disabled"]:
		button.add_theme_stylebox_override(style_name, StyleBoxEmpty.new())
	button.pressed.connect(callback)
	_context_rows.add_child(button)
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 1
	row.offset_right = -1
	row.add_theme_constant_override("separation", 0)
	button.add_child(row)
	button.set_meta("texture_row", row)
	button.button_down.connect(_set_action_row_pressed.bind(row, true))
	button.button_up.connect(_set_action_row_pressed.bind(row, false))
	return button


func _fill_action_row(
		button: Button, row: HBoxContainer, prefix: String) -> void:
	_clear_row(row)
	_add_text_piece(
		row, prefix, "", int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG), true)
	_add_text_piece(
		row,
		PlayerName.display(str(_player_meta.get("display_name", "")), _display_language),
		str(_player_meta.get("system_name", "")),
		int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_NORMAL), false)
	_fit_action_button(button, row)


func _fill_local_action(
		button: Button, row: HBoxContainer, text: String, color_index: int) -> void:
	_clear_row(row)
	var role := int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_NORMAL)
	if color_index == 1:
		role = int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG)
	elif color_index == 3:
		role = int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_MUTED)
	_add_text_piece(
		row, text, "", role, not button.disabled)
	_fit_action_button(button, row)


func _fill_player_punishment_action(
		button: Button, row: HBoxContainer, kind: String,
		active_record: Dictionary) -> void:
	_clear_row(row)
	if active_record.is_empty():
		_add_fixed_text_piece(
			row, "禁言 " if kind == "mute" else "封禁 ",
			_MUTE_COLOR if kind == "mute" else _BAN_COLOR)
		_add_text_piece(
			row,
			PlayerName.display(str(_player_meta.get("display_name", "")), _display_language),
			str(_player_meta.get("system_name", "")),
			int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_NORMAL), false)
	else:
		_add_text_piece(
			row, "更改", "", int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG), true)
		_add_fixed_text_piece(
			row, "禁言" if kind == "mute" else "封禁",
			_MUTE_COLOR if kind == "mute" else _BAN_COLOR)
		_add_text_piece(
			row, "时长", "", int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG), true)
	_fit_action_button(button, row)


func _fill_player_revoke_action(
		button: Button, row: HBoxContainer, kind: String) -> void:
	_clear_row(row)
	_add_text_piece(
		row, "立即解除", "", int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG), true)
	_add_fixed_text_piece(
		row, "禁言" if kind == "mute" else "封禁",
		_MUTE_COLOR if kind == "mute" else _BAN_COLOR)
	_fit_action_button(button, row)


func _add_fixed_text_piece(
		row: HBoxContainer, text: String, color: Color) -> void:
	var label := Label.new()
	label.text = text
	label.set_meta("fixed_punishment_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_apply_text_style(label)
	row.add_child(label)


func _clear_row(row: HBoxContainer) -> void:
	for child in row.get_children():
		row.remove_child(child)
		child.queue_free()


func _add_text_piece(
		row: HBoxContainer, text: String, system_name: String, role: int,
		stateful: bool = false) -> void:
	var label := Label.new()
	label.text = text
	label.set_meta("button_stateful_theme", stateful)
	label.set_meta("button_base_role", role)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_apply_text_style(label)
	var fallback_color := _ui_normal_color
	if role == int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG):
		fallback_color = _ui_strong_color
	elif role == int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_MUTED):
		fallback_color = _ui_muted_color
	label.add_theme_color_override("font_color", fallback_color)
	if is_instance_valid(_theme_text_runtime):
		_theme_text_runtime.style_control(
			label, _theme_source(), system_name, role)
	row.add_child(label)


func _set_action_row_pressed(row: HBoxContainer, pressed: bool) -> void:
	for child in row.get_children():
		if not child is Label or not bool(child.get_meta("button_stateful_theme", false)):
			continue
		var label := child as Label
		var role := int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG if pressed
			else label.get_meta("button_base_role", _WEBPAGE_THEME_TEXT_RUNTIME.ROLE_NORMAL))
		var fallback := _ui_normal_color
		if role == int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG):
			fallback = _ui_strong_color
		elif role == int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_MUTED):
			fallback = _ui_muted_color
		label.add_theme_color_override("font_color", fallback)
		if is_instance_valid(_theme_text_runtime):
			_theme_text_runtime.style_control(label, _theme_source(), "", role)


func _fit_action_button(button: Button, row: HBoxContainer) -> void:
	preload("res://cogs/ui_text_baseline.gd").install(row)
	var minimum := row.get_combined_minimum_size()
	button.custom_minimum_size = Vector2(
		ceilf(minimum.x) + UiScale.physical_value(2.0), ceilf(minimum.y))


func _apply_text_style(control: Control) -> void:
	control.add_theme_font_override("font", _GAME_UI_FONT)
	control.add_theme_font_override("normal_font", _GAME_UI_FONT)
	control.add_theme_color_override("font_color", _ui_normal_color)
	control.add_theme_color_override("font_hover_color", _ui_normal_color)
	control.add_theme_color_override("font_pressed_color", _ui_normal_color)
	control.add_theme_color_override("font_focus_color", _ui_normal_color)
	control.add_theme_color_override("font_selected_color", _ui_normal_color)
	control.add_theme_color_override("font_disabled_color", _ui_muted_color)
	control.add_theme_color_override("font_placeholder_color", _ui_muted_color)
	control.add_theme_color_override("font_uneditable_color", _ui_muted_color)
	if control is RichTextLabel:
		control.add_theme_color_override("default_color", _ui_normal_color)
	control.add_theme_color_override("font_shadow_color", _GAME_UI_SHADOW_COLOR)
	control.add_theme_color_override("font_outline_color", Color.TRANSPARENT)
	control.add_theme_constant_override("shadow_offset_x", 1)
	control.add_theme_constant_override("shadow_offset_y", 1)
	control.add_theme_constant_override("shadow_outline_size", 0)
	control.add_theme_constant_override("outline_size", 0)
	if is_instance_valid(_theme_text_runtime):
		_theme_text_runtime.style_control(control, _theme_source())
	if control is OptionButton: _style_duration_option(control)
	if control.has_meta("fixed_punishment_color"):
		var fixed_color := control.get_meta("fixed_punishment_color") as Color
		# Keep the System shader: it resolves the shadow marker while passing
		# these fixed foreground colors through, just like player-list statuses.
		for color_name in [
				"font_color", "font_hover_color", "font_pressed_color",
				"font_focus_color", "font_selected_color"]:
			control.add_theme_color_override(color_name, fixed_color)


func _apply_game_ui_text_style(root: Node) -> void:
	if root is Control:
		_apply_text_style(root as Control)
	if root is SpinBox:
		# Godot 4.7 makes this internal editor inherit the SpinBox material.
		# Its text has its own System material; inheriting would expose marker colors.
		root.get_line_edit().use_parent_material = false
		_apply_text_style(root.get_line_edit())
	for child in root.get_children():
		_apply_game_ui_text_style(child)
	if root == _moderation_popup:
		_style_moderation_actions()


func dismiss() -> void:
	_right_click_held = false
	dismiss_context_menu()
	_popup_geometry_refresh_serial += 1
	_close_moderation()


func _close_moderation() -> void:
	_cancel_moderation_request()
	if is_instance_valid(_moderation_popup):
		_moderation_popup.hide()


func _cancel_moderation_request() -> void:
	_moderation_open_serial += 1
	_pending_request_id = 0
	_pending_action = ""
	_pending_kind = ""
	_editing_record.clear()


func dismiss_context_menu() -> void:
	_right_click_held = false
	_cancel_context_request()
	if is_instance_valid(_context_popup):
		_context_popup.hide()


func _cancel_context_request() -> void:
	_context_requested = false
	_context_open_serial += 1
	_popup_geometry_refresh_serial += 1
	_context_text_anchor.clear()
	_context_anchor_control = null
	_context_anchor_pending = false
	_context_player_resolver = Callable()


func _queue_popup_geometry_refresh(_scale: float = 0.0) -> void:
	_popup_geometry_refresh_serial += 1
	if _popup_geometry_refresh_pending:
		return
	_popup_geometry_refresh_pending = true
	call_deferred("_refresh_visible_popup_geometry")


func _refresh_visible_popup_geometry() -> void:
	while true:
		var serial := _popup_geometry_refresh_serial
		await get_tree().process_frame
		if serial != _popup_geometry_refresh_serial:
			continue
		_refresh_network_checkbox_visual()
		if is_instance_valid(_context_popup) and _context_popup.visible:
			_refit_context_action_buttons()
		await get_tree().process_frame
		if serial != _popup_geometry_refresh_serial:
			continue
		break
	_popup_geometry_refresh_pending = false
	if is_instance_valid(_context_popup) and _context_popup.visible:
		var anchor: Variant = _resolved_context_anchor()
		if anchor == null:
			if not _context_anchor_pending:
				_context_popup.hide()
		else:
			PopupGeometryScript.apply_rect(
				_context_popup,
				PopupGeometryScript.anchored_rect(
					_context_popup,
					_context_popup_size(),
					anchor as Vector2i,
					UiScale.physical_int(4.0)))
	if is_instance_valid(_moderation_popup) and _moderation_popup.visible:
		_style_duration_option(_duration_options)
		_style_duration_option(_custom_unit)
		_style_moderation_actions()
		PopupGeometryScript.apply_rect(
			_moderation_popup,
			PopupGeometryScript.centered_rect(
				_moderation_popup,
				_moderation_popup_size(),
				Vector2i.ONE,
				UiScale.physical_int(12.0)))
		preload("res://cogs/option_popup_layout.gd").refresh(_duration_options)
		preload("res://cogs/option_popup_layout.gd").refresh(_custom_unit)


func _build_moderation_popup() -> void:
	_moderation_popup = PopupPanel.new()
	_moderation_popup.name = "ChatModerationPopup"
	_moderation_popup.transparent_bg = true
	_moderation_popup.wrap_controls = false
	_moderation_popup.exclusive = false
	_moderation_popup.popup_hide.connect(_cancel_moderation_request)
	_moderation_popup.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	add_child(_moderation_popup)

	_moderation_content = MarginContainer.new()
	_moderation_content.add_theme_constant_override("margin_left", 8)
	_moderation_content.add_theme_constant_override("margin_top", 8)
	_moderation_content.add_theme_constant_override("margin_right", 8)
	_moderation_content.add_theme_constant_override("margin_bottom", 8)
	_moderation_popup.add_child(_moderation_content)
	_moderation_content.minimum_size_changed.connect(_queue_popup_geometry_refresh)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 6)
	_moderation_content.add_child(content)

	_moderation_title = HBoxContainer.new()
	_moderation_title.alignment = BoxContainer.ALIGNMENT_CENTER
	_moderation_title.add_theme_constant_override("separation", 0)
	content.add_child(_moderation_title)
	_moderation_title_spacing = preload("res://cogs/popup_title_spacing.gd").install(_moderation_content, _moderation_title, 16, true)
	_moderation_title_spacing.bottom_design = 8
	_moderation_scroll = ScrollContainer.new()
	_moderation_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_moderation_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_moderation_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_moderation_scroll.follow_focus = true
	UiScale.mark_geometry_physical(_moderation_scroll)
	content.add_child(_moderation_scroll)
	_moderation_fields = VBoxContainer.new()
	_moderation_fields.add_theme_constant_override("separation", 6)
	_moderation_fields.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_moderation_fields.minimum_size_changed.connect(_queue_popup_geometry_refresh)
	_moderation_scroll.add_child(_moderation_fields)
	_duration_options = OptionButton.new()
	_duration_options.clip_text = true
	_duration_options.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	for spec in [
			["1分钟", 60], ["2分钟", 120], ["5分钟", 300],
			["30分钟", 1800], ["1小时", 3600], ["12小时", 43200],
			["1天", 86400], ["2天", 172800], ["7天", 604800]]:
		_duration_options.add_item(spec[0])
		_duration_options.set_item_metadata(
			_duration_options.item_count - 1,
			{"mode": "finite", "seconds": int(spec[1])})
	_duration_options.add_item("永久")
	_duration_options.set_item_metadata(
		_duration_options.item_count - 1,
		{"mode": "permanent", "seconds": 0})
	_duration_options.add_item("自定义时长")
	_duration_options.set_item_metadata(
		_duration_options.item_count - 1,
		{"mode": "custom", "seconds": 0})
	_duration_options.item_selected.connect(_on_duration_selected)
	_moderation_fields.add_child(_duration_options)
	preload("res://cogs/launcher_popup_style.gd").install(_duration_options)
	_custom_row = HBoxContainer.new()
	_custom_row.visible = false
	_moderation_fields.add_child(_custom_row)
	_custom_duration = SpinBox.new()
	_custom_duration.gui_input.connect(_on_duration_gui_input)
	_custom_duration.get_line_edit().gui_input.connect(_on_duration_gui_input)
	_custom_duration.min_value = 1
	_custom_duration.max_value = 10_080
	_custom_duration.value = 10
	_custom_duration.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_custom_row.add_child(_custom_duration)
	preload("res://cogs/input_field_style.gd").install(_custom_duration.get_line_edit())
	_custom_unit = OptionButton.new()
	_custom_unit.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	for unit_spec in [["分钟", 60], ["小时", 3600], ["天", 86400]]:
		_custom_unit.add_item(unit_spec[0])
		_custom_unit.set_item_metadata(
			_custom_unit.item_count - 1, int(unit_spec[1]))
	_custom_unit.item_selected.connect(_on_custom_unit_selected)
	_custom_row.add_child(_custom_unit)
	preload("res://cogs/launcher_popup_style.gd").install(_custom_unit)
	_network_row = HBoxContainer.new()
	_network_row.add_theme_constant_override("separation", 4)
	_moderation_fields.add_child(_network_row)
	_network_icon = TextureRect.new()
	_network_icon.texture = _IP_ICON
	_network_icon.custom_minimum_size = Vector2(16, 16)
	_network_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_network_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_network_icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_network_row.add_child(_network_icon)
	_network_checkbox = CheckBox.new()
	_network_checkbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_network_checkbox.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_network_checkbox.layout_direction = Control.LAYOUT_DIRECTION_RTL
	_network_checkbox.text_direction = Control.TEXT_DIRECTION_LTR
	_network_checkbox.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_network_checkbox.add_theme_constant_override("h_separation", 8)
	_network_checkbox.toggled.connect(_on_network_checkbox_toggled)
	_network_checkbox.resized.connect(_layout_network_checkbox_square)
	_network_row.add_child(_network_checkbox)
	_network_square = Panel.new()
	UiScale.mark_geometry_physical(_network_square)
	_network_square.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_network_square.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	_network_checkbox.add_child(_network_square)
	_network_checkmark = TextureRect.new()
	UiScale.mark_geometry_physical(_network_checkmark)
	_network_checkmark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_network_checkmark.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_network_checkmark.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	# Sibling of the dimmed frame: native disabled icons already carry their tint.
	_network_checkbox.add_child(_network_checkmark)
	_network_help = Button.new()
	_network_help.text = "?"
	_network_help.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_network_help.flat = true
	_network_help.focus_mode = Control.FOCUS_NONE
	_network_help.set_meta(WebpageThemeTooltipRuntime.PLACEMENT_META, "upper_left")
	WebpageThemeTooltipRuntime.set_control_tooltip(
		_network_help, "一般情况不建议勾选，可能误杀同一校园网下的全部玩家")
	_network_row.add_child(_network_help)
	_moderation_status = Label.new()
	_moderation_status.hide()
	_moderation_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_moderation_fields.add_child(_moderation_status)
	var action_row := HBoxContainer.new()
	action_row.alignment = BoxContainer.ALIGNMENT_CENTER
	action_row.add_theme_constant_override("separation", 12)
	preload("res://cogs/ui_text_baseline.gd").install_buttons(action_row)
	content.add_child(action_row)
	var confirm_button := Button.new()
	confirm_button.custom_minimum_size = Vector2(80, 32)
	confirm_button.text = "确认"
	confirm_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	confirm_button.pressed.connect(_on_moderation_confirmed)
	action_row.add_child(confirm_button)
	var cancel_button := Button.new()
	cancel_button.custom_minimum_size = Vector2(80, 32)
	cancel_button.text = "取消"
	cancel_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	cancel_button.pressed.connect(_moderation_popup.hide)
	action_row.add_child(cancel_button)
	_moderation_footer = preload("res://cogs/dialog_footer.gd").install_shared(action_row, true, true)


func _update_admin_visibility() -> void:
	var player_mode := not _player_meta.is_empty()
	var admin_actions_visible := player_mode and (
		is_instance_valid(_mp_connection)
		and _mp_connection.is_admin_authenticated())
	if is_instance_valid(_mention_button):
		_mention_button.visible = player_mode
		_mention_button.disabled = (not is_instance_valid(_mp_connection)
			or _mp_connection.get_chat_mention_target(_player_meta).is_empty())
	if is_instance_valid(_mute_button):
		_mute_button.visible = admin_actions_visible
		_mute_revoke_button.visible = admin_actions_visible
		_ban_button.visible = admin_actions_visible
		_ban_revoke_button.visible = admin_actions_visible
	if is_instance_valid(_select_all_button):
		_select_all_button.visible = not player_mode
		_copy_button.visible = not player_mode


func _capture_context_anchor(
		requested_position: Vector2, text_anchor: Dictionary = {}) -> void:
	_context_anchor_ratio = PopupGeometryScript.anchor_ratio(
		_context_popup, Vector2i(PopupGeometryScript.viewport_point(
			_context_popup, get_viewport(), requested_position)))
	_context_anchor_control = null
	_context_anchor_kind = "control"
	_context_text_anchor.clear()
	if not text_anchor.is_empty():
		_context_anchor_kind = "chat_text"
		_context_text_anchor = text_anchor.duplicate(true)
		return
	var hovered := get_viewport().gui_get_hovered_control()
	if not is_instance_valid(hovered) or _control_belongs_to_popup(hovered):
		return
	_context_anchor_control = weakref(hovered)
	_context_anchor_local = (
		hovered.get_global_transform_with_canvas().affine_inverse()
		* requested_position)


func _resolved_context_anchor() -> Variant:
	_context_anchor_pending = false
	if _context_anchor_kind == "player_list":
		if _current_list_player().is_empty():
			return null
		# Data refreshes validate identity without moving an open menu with a
		# reordered/recreated card. Actual window geometry still uses this ratio.
		return PopupGeometryScript.anchor_from_ratio(_context_popup, _context_anchor_ratio)
	if _context_anchor_kind == "chat_text":
		if (not is_instance_valid(_chat_selection)
				or not _chat_selection.has_method("resolve_text_anchor")):
			return null
		var result: Variant = _chat_selection.call(
			"resolve_text_anchor", _context_text_anchor)
		if not result is Dictionary:
			return null
		var state := str((result as Dictionary).get("state", "missing"))
		if state == "pending":
			_context_anchor_pending = true
			return null
		if state != "resolved":
			return null
		return Vector2i(PopupGeometryScript.viewport_point(
			_context_popup, _chat_selection.get_viewport(),
			(result as Dictionary).get("position", Vector2.ZERO)))
	if _context_anchor_control != null:
		var control := _context_anchor_control.get_ref() as Control
		if not is_instance_valid(control) or not control.is_visible_in_tree():
			return null
		return Vector2i(
			PopupGeometryScript.control_point(_context_popup, control, _context_anchor_local))
	return PopupGeometryScript.anchor_from_ratio(
		_context_popup, _context_anchor_ratio)


func _current_list_player() -> Dictionary:
	if not _context_player_resolver.is_valid():
		return {}
	var current: Dictionary = _context_player_resolver.call()
	for field in ["subject_group_id", "public_chat_id"]:
		var original := str(_player_meta.get(field, ""))
		var latest := str(current.get(field, ""))
		if not original.is_empty() and not latest.is_empty() and original != latest:
			return {}
	return current


func notify_player_list_changed() -> void:
	if not _context_requested or _context_anchor_kind != "player_list":
		return
	var current := _current_list_player()
	if current.is_empty():
		dismiss_context_menu()
		return
	# Preserve a known authenticated identity if the public snapshot omits it.
	for field in ["subject_group_id", "public_chat_id"]:
		if str(current.get(field, "")).is_empty() and _player_meta.has(field):
			current[field] = _player_meta[field]
	_player_meta = current
	_refresh_player_actions()


func notify_chat_layout_changed() -> void:
	if (not _context_requested
			or _context_anchor_kind != "chat_text" or _context_text_anchor.is_empty()):
		return
	if is_instance_valid(_context_popup) and _context_popup.visible:
		_queue_popup_geometry_refresh()
	else:
		_show_context_popup_after_layout(_context_open_serial)


func _control_belongs_to_popup(control: Control) -> bool:
	var current: Node = control
	while current != null:
		if current == _context_popup or current == _moderation_popup:
			return true
		current = current.get_parent()
	return false


func _context_popup_size() -> Vector2i:
	var content_size := PopupGeometryScript.content_minimum_size(_context_popup)
	return Vector2i(
		maxi(UiScale.physical_int(16.0), content_size.x),
		maxi(UiScale.physical_int(16.0), content_size.y))


func _moderation_popup_size() -> Vector2i:
	_moderation_title_spacing.refresh()
	_moderation_footer._refresh()
	var width := preload("res://cogs/launcher_popup_style.gd").content_width(_moderation_content)
	width = maxf(width, preload("res://cogs/launcher_popup_style.gd").content_width(_moderation_fields)
		+ _moderation_content.get_theme_constant("margin_left") + _moderation_content.get_theme_constant("margin_right"))
	# A wrapping CheckBox reports a reduced text minimum. Reserve the complete
	# IP caption beside its larger icon before clamping to the available screen.
	var caption_width := _network_checkbox.get_theme_font("font").get_string_size(
		_network_checkbox.text, HORIZONTAL_ALIGNMENT_LEFT, -1, _network_checkbox.get_theme_font_size("font_size")).x
	var network_width := caption_width + _network_checkbox.get_theme_stylebox("normal").get_minimum_size().x \
		+ _network_checkbox.get_theme_icon("unchecked").get_width() + _network_checkbox.get_theme_constant("h_separation") \
		+ _network_icon.get_combined_minimum_size().x + _network_help.get_combined_minimum_size().x \
		+ 2 * _network_row.get_theme_constant("separation") \
		+ _moderation_content.get_theme_constant("margin_left") + _moderation_content.get_theme_constant("margin_right")
	width = minf(maxf(width, network_width), PopupGeometryScript.bounds_for(_moderation_popup).size.x - UiScale.physical_int(24))
	_moderation_content.size.x = width
	var fixed_height := _moderation_content.get_combined_minimum_size().y - _moderation_scroll.get_combined_minimum_size().y
	var available := PopupGeometryScript.bounds_for(_moderation_popup).size.y - UiScale.physical_int(24) - fixed_height
	_moderation_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO if _moderation_fields.get_combined_minimum_size().y > available else ScrollContainer.SCROLL_MODE_DISABLED
	_moderation_scroll.custom_minimum_size.y = minf(ceilf(_moderation_fields.get_combined_minimum_size().y), maxf(1.0, floorf(available)))
	var content_size := PopupGeometryScript.content_minimum_size(_moderation_popup)
	return Vector2i(
		ceili(width),
		maxi(1, content_size.y))


func _refit_context_action_buttons() -> void:
	for pair in [
			[_mention_button, _mention_row],
			[_mute_button, _mute_row],
			[_mute_revoke_button, _mute_revoke_row],
			[_ban_button, _ban_row],
			[_ban_revoke_button, _ban_revoke_row],
			[_select_all_button, _select_all_row],
			[_copy_button, _copy_row]]:
		var button := pair[0] as Button
		var row := pair[1] as HBoxContainer
		if is_instance_valid(button) and is_instance_valid(row):
			_fit_action_button(button, row)


func _on_mention_pressed() -> void:
	_context_popup.hide()
	mention_requested.emit(_player_meta.duplicate(true))


func _on_mute_pressed() -> void:
	_open_moderation_dialog("mute", _active_punishment("mute"))


func _on_mute_revoke_pressed() -> void:
	_revoke_player_punishment("mute")


func _on_ban_pressed() -> void:
	_open_moderation_dialog("ban", _active_punishment("ban"))


func _on_ban_revoke_pressed() -> void:
	_revoke_player_punishment("ban")


func _subject_group_id() -> String:
	var group_id := str(_player_meta.get("subject_group_id", ""))
	if (group_id.is_empty() and is_instance_valid(_mp_connection)
			and int(_player_meta.get("sender_id", 0)) > 0):
		group_id = _mp_connection.get_admin_subject_group_for_pid(
			int(_player_meta.get("sender_id", 0)))
		if not group_id.is_empty():
			_player_meta["subject_group_id"] = group_id
	return group_id


func _active_punishment(kind: String) -> Dictionary:
	if not is_instance_valid(_mp_connection):
		return {}
	var group_id := _subject_group_id()
	if group_id.is_empty():
		return {}
	return _mp_connection.get_active_admin_punishment(_player_meta, kind)


func _resolve_target_pid() -> int:
	if not is_instance_valid(_mp_connection):
		return 0
	return _mp_connection.resolve_admin_target_pid(
		int(_player_meta.get("sender_id", 0)), _subject_group_id())


func _refresh_player_actions() -> void:
	if _player_meta.is_empty():
		_update_admin_visibility()
		return
	var active_mute := _active_punishment("mute")
	var active_ban := _active_punishment("ban")
	var name_state := [str(_player_meta.get("display_name", "")),
		str(_player_meta.get("system_name", "")), _display_language]
	var changed := false
	if _action_row_changed("mention", name_state):
		_fill_action_row(_mention_button, _mention_row, "@ ")
		changed = true
	for kind in ["mute", "ban"]:
		var active: Dictionary = active_mute if kind == "mute" else active_ban
		var row: HBoxContainer = _mute_row if kind == "mute" else _ban_row
		var button: Button = _mute_button if kind == "mute" else _ban_button
		var state := [active.is_empty(), name_state if active.is_empty() else []]
		if _action_row_changed(kind, state):
			_fill_player_punishment_action(button, row, kind, active)
			changed = true
		if _action_row_changed(kind + "_revoke", [true]):
			_fill_player_revoke_action(
				_mute_revoke_button if kind == "mute" else _ban_revoke_button,
				_mute_revoke_row if kind == "mute" else _ban_revoke_row, kind)
			changed = true
	var authenticated := (
		is_instance_valid(_mp_connection)
		and _mp_connection.is_admin_authenticated())
	var target_available := _resolve_target_pid() > 0
	var mention_disabled := (not is_instance_valid(_mp_connection)
		or _mp_connection.get_chat_mention_target(_player_meta).is_empty())
	var visibility := [authenticated, target_available, not active_mute.is_empty(),
		not active_ban.is_empty(), mention_disabled]
	changed = changed or visibility != _action_visibility or not _mention_button.visible
	_action_visibility = visibility
	_mention_button.visible = true
	_mention_button.disabled = mention_disabled
	_copy_button.visible = false
	_select_all_button.visible = false
	_mute_button.visible = authenticated and (
		target_available or not active_mute.is_empty())
	_mute_revoke_button.visible = authenticated and not active_mute.is_empty()
	_ban_button.visible = authenticated and (
		target_available or not active_ban.is_empty())
	_ban_revoke_button.visible = authenticated and not active_ban.is_empty()
	if changed and _context_popup.visible:
		_queue_popup_geometry_refresh()


func _action_row_changed(key: String, state: Array) -> bool:
	if _action_row_states.has(key) and _action_row_states[key] == state:
		return false
	_action_row_states[key] = state.duplicate(true)
	return true


func _revoke_player_punishment(kind: String) -> void:
	_context_popup.hide()
	if (not is_instance_valid(_mp_connection)
			or not _mp_connection.is_admin_authenticated()):
		return
	var active := _active_punishment(kind)
	if active.is_empty():
		return
	var target_pid := _resolve_target_pid()
	if target_pid > 0:
		if kind == "mute":
			_mp_connection.admin_revoke_mute(target_pid)
		else:
			_mp_connection.admin_revoke_ban_for_player(target_pid)
	else:
		_mp_connection.admin_revoke_punishment(str(active.get("ban_id", "")))


func _open_moderation_dialog(action: String, record: Dictionary = {}) -> void:
	_context_open_serial += 1
	_context_popup.hide()
	_pending_kind = action
	_pending_action = ""
	_pending_request_id = 0
	_editing_record = record.duplicate(true)
	_duration_options.select(0)
	_custom_row.visible = false
	_custom_unit.select(0)
	_update_custom_duration_limit()
	_set_moderation_status("")
	var display_name := str(record.get(
		"last_name", _player_meta.get("display_name", "")))
	_configure_network_scope(action, record)
	_select_record_duration(record)
	_fill_moderation_title(action, display_name)
	_moderation_open_serial += 1
	var serial := _moderation_open_serial
	_moderation_popup.min_size = Vector2i.ZERO
	SystemUISkin.install(_moderation_popup, _theme_source(), "", -1)
	_style_duration_option(_duration_options)
	_style_duration_option(_custom_unit)
	_style_moderation_actions()
	_show_moderation_popup_after_layout(serial)


func _show_moderation_popup_after_layout(serial: int) -> void:
	await get_tree().process_frame
	if serial != _moderation_open_serial:
		return
	_refresh_network_checkbox_visual()
	await get_tree().process_frame
	if serial != _moderation_open_serial:
		return
	var popup_rect := PopupGeometryScript.centered_rect(
		_moderation_popup,
		_moderation_popup_size(),
		Vector2i.ONE,
		UiScale.physical_int(12.0))
	if _moderation_popup.visible:
		PopupGeometryScript.apply_rect(_moderation_popup, popup_rect)
	else:
		_moderation_popup.popup(popup_rect)
		await get_tree().process_frame
		if serial == _moderation_open_serial and _moderation_popup.visible:
			PopupGeometryScript.apply_rect(
				_moderation_popup,
				PopupGeometryScript.centered_rect(
					_moderation_popup,
					_moderation_popup.size,
					Vector2i.ONE,
					UiScale.physical_int(12.0)))
	if _custom_row.visible and not _custom_duration.has_meta("android_native_input"):
		_custom_duration.grab_focus()
	else:
		_duration_options.grab_focus()


func _fill_moderation_title(kind: String, display_name: String) -> void:
	preload("res://cogs/ui_text_baseline.gd").install(_moderation_title)
	_clear_row(_moderation_title)
	_add_fixed_text_piece(
		_moderation_title, "禁言" if kind == "mute" else "封禁",
		_MUTE_COLOR if kind == "mute" else _BAN_COLOR)
	_add_text_piece(
		_moderation_title, " " + PlayerName.display(display_name, _display_language),
		str(_player_meta.get("system_name", "")),
		int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_NORMAL))


func _on_duration_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		_custom_duration.accept_event()


func _on_duration_selected(index: int) -> void:
	var metadata := _duration_options.get_item_metadata(index) as Dictionary
	_custom_row.visible = str(metadata.get("mode", "finite")) == "custom"
	if _custom_row.visible and _moderation_popup.visible and not _custom_duration.has_meta("android_native_input"):
		_custom_duration.grab_focus()


func _select_record_duration(record: Dictionary) -> void:
	if record.is_empty():
		return
	if str(record.get("duration_mode", "finite")) == "permanent":
		_duration_options.select(9)
		_on_duration_selected(9)
		return
	var now_unix := int(Time.get_unix_time_from_system())
	if (is_instance_valid(_mp_connection)
			and _mp_connection.has_method("get_estimated_server_unix_msec")):
		now_unix = int(_mp_connection.get_estimated_server_unix_msec() / 1000)
	var remaining := maxi(60, int(record.get("expires_at", 0)) - now_unix)
	_duration_options.select(10)
	_custom_unit.select(0)
	_update_custom_duration_limit()
	_custom_duration.value = mini(
		int(_custom_duration.max_value), ceili(float(remaining) / 60.0))
	_on_duration_selected(10)


func _on_custom_unit_selected(_index: int) -> void:
	_update_custom_duration_limit()


func _update_custom_duration_limit() -> void:
	if not is_instance_valid(_custom_duration) or not is_instance_valid(_custom_unit):
		return
	var maximum_seconds := 604800 if _pending_kind == "mute" else 2592000
	var multiplier := int(_custom_unit.get_item_metadata(_custom_unit.selected))
	_custom_duration.max_value = maxi(1, int(maximum_seconds / maxi(1, multiplier)))


func _configure_network_scope(kind: String, record: Dictionary, initialize: bool = true) -> void:
	var scope := str(record.get("scope", "installation"))
	var network_active := scope in ["installation_network", "network"]
	var network_forced := scope == "network"
	var state := {"available": false, "reason": "管理员认证已失效"}
	if is_instance_valid(_mp_connection):
		state = _mp_connection.get_admin_network_scope_state(_player_meta, record)
	var can_add_network := bool(state.get("available", false))
	var previous_reason := _network_unavailable_reason
	_network_unavailable_reason = str(state.get("reason", ""))
	if not initialize and not previous_reason.is_empty() and _moderation_status.text == previous_reason:
		_set_moderation_status(_network_unavailable_reason)
	_network_checkbox.text = "同时%s该ip" % ("禁言" if kind == "mute" else "封禁")
	if initialize:
		_network_checkbox.button_pressed = network_active
	elif not network_active and not can_add_network and _network_checkbox.button_pressed:
		_network_checkbox.button_pressed = false
		_set_moderation_status(_network_unavailable_reason)
	_network_checkbox.disabled = network_forced or (not network_active and not can_add_network)
	var explanation := (
		"该玩家无法验证客户端身份，因此必须在ip层面处罚"
		if network_forced else "一般情况不建议勾选，可能误杀同一校园网下的全部玩家")
	if not can_add_network:
		explanation = _network_unavailable_reason + (
			"；已有IP处罚仍可缩短或解除" if network_active else "")
	WebpageThemeTooltipRuntime.set_control_tooltip(
		_network_help, explanation)
	_refresh_network_row_style()


func _refresh_network_row_style() -> void:
	if not is_instance_valid(_network_checkbox):
		return
	var color := _ui_muted_color if _network_checkbox.disabled else _ui_strong_color
	_network_icon.modulate = color
	var text_color := _ui_muted_color if _network_checkbox.disabled else _ui_normal_color
	_network_checkbox.add_theme_color_override("font_color", text_color)
	_network_checkbox.add_theme_color_override("font_disabled_color", text_color)
	_network_help.add_theme_color_override("font_color", text_color)
	if is_instance_valid(_theme_text_runtime):
		var role := int(
			_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_MUTED
			if _network_checkbox.disabled
			else _WEBPAGE_THEME_TEXT_RUNTIME.ROLE_NORMAL)
		_theme_text_runtime.style_control(_network_checkbox, _theme_source(), "", role)
		_theme_text_runtime.style_control(_network_help, _theme_source(), "", role)
	_refresh_network_checkbox_visual()


func _refresh_network_checkbox_visual() -> void:
	if not is_instance_valid(_network_checkbox) or not is_instance_valid(_network_square):
		return
	var side := maxi(1, UiScale.physical_int(32.0))
	var transparent_image := Image.create(side, side, false, Image.FORMAT_RGBA8)
	transparent_image.fill(Color.TRANSPARENT)
	var transparent_icon := ImageTexture.create_from_image(transparent_image)
	for icon_name: StringName in [
			&"checked", &"unchecked", &"checked_disabled", &"unchecked_disabled",
			&"radio_checked", &"radio_unchecked", &"radio_checked_disabled",
			&"radio_unchecked_disabled"]:
		_network_checkbox.add_theme_icon_override(icon_name, transparent_icon)
	_network_square.custom_minimum_size = Vector2(side, side)
	_network_square.size = Vector2(side, side)
	_network_checkbox.mouse_default_cursor_shape = (
		Control.CURSOR_ARROW
		if _network_checkbox.disabled
		else Control.CURSOR_POINTING_HAND)
	_network_square.modulate = (
		Color(1.0, 1.0, 1.0, 0.55)
		if _network_checkbox.disabled
		else Color.WHITE)
	if is_instance_valid(_theme_source()):
		SystemUISkin.install(_network_square, _theme_source(), "", -1)
	var scale := UiScale.physical_value(1)
	if not is_equal_approx(_network_icon_scale, scale):
		_network_icon_scale = scale
		for state: String in ["checked", "unchecked", "checked_disabled", "unchecked_disabled"]:
			# Resolve original built-in icons, never the transparent layout placeholders.
			var original := ThemeDB.get_default_theme().get_icon(state, "CheckBox")
			var pixels := original.get_image()
			pixels.resize(maxi(1, roundi(original.get_width() * scale)),
				maxi(1, roundi(original.get_height() * scale)), Image.INTERPOLATE_NEAREST)
			_network_checkbox_icons[state] = ImageTexture.create_from_image(pixels)
	_update_network_checkmark()
	_layout_network_checkbox_square()


func _update_network_checkmark() -> void:
	var state := "checked" if _network_checkbox.button_pressed else "unchecked"
	if _network_checkbox.disabled:
		state += "_disabled"
	if _network_checkbox_icons.has(state):
		_network_checkmark.texture = _network_checkbox_icons[state]
		_network_checkmark.size = _network_checkmark.texture.get_size()


func _layout_network_checkbox_square() -> void:
	if not is_instance_valid(_network_checkbox) or not is_instance_valid(_network_square):
		return
	var side := _network_square.custom_minimum_size.x
	_network_square.position = Vector2(
		maxf(0.0, _network_checkbox.size.x - side),
		maxf(0.0, (_network_checkbox.size.y - side) * 0.5))
	_network_checkmark.position = _network_square.position + (Vector2.ONE * side - _network_checkmark.size) * 0.5


func _on_network_checkbox_toggled(_pressed: bool) -> void:
	if is_instance_valid(_network_checkmark):
		_update_network_checkmark()
		_layout_network_checkbox_square()


func _set_moderation_status(message: String) -> void:
	_moderation_status.text = message
	_moderation_status.visible = not message.is_empty()
	_queue_popup_geometry_refresh()


func _selected_duration() -> Dictionary:
	var metadata := _duration_options.get_item_metadata(
		_duration_options.selected) as Dictionary
	var mode := str(metadata.get("mode", "finite"))
	if mode == "permanent":
		return {"mode": "permanent", "seconds": 0}
	if mode == "custom":
		var multiplier := int(_custom_unit.get_item_metadata(_custom_unit.selected))
		return {
			"mode": "finite",
			"seconds": int(_custom_duration.value) * multiplier,
		}
	return {"mode": "finite", "seconds": int(metadata.get("seconds", 60))}


func _on_moderation_confirmed() -> void:
	if _pending_request_id > 0 or _pending_kind.is_empty():
		return
	if (not is_instance_valid(_mp_connection)
			or not _mp_connection.is_admin_authenticated()):
		_set_moderation_status("管理员认证已失效")
		return
	var duration := _selected_duration()
	_pending_duration_seconds = int(duration.get("seconds", 0))
	_pending_duration_mode = str(duration.get("mode", "finite"))
	_pending_include_network = _network_checkbox.button_pressed
	var target_pid := _resolve_target_pid()
	var active := _editing_record
	if active.is_empty():
		active = _active_punishment(_pending_kind)
	var network_error := _network_submission_error(active)
	if not network_error.is_empty():
		_set_moderation_status(network_error)
		return
	if not active.is_empty():
		_pending_action = "punishment_update"
		_pending_request_id = _mp_connection.admin_update_punishment(
			str(active.get("ban_id", "")), _pending_duration_seconds,
			_pending_duration_mode, _pending_include_network)
	elif target_pid > 0 and _pending_kind == "mute":
		_pending_action = "set_mute"
		_pending_request_id = _mp_connection.admin_set_mute(
			target_pid, _pending_duration_seconds, _pending_duration_mode,
			_pending_include_network)
	elif target_pid > 0:
		_pending_action = "set_ban"
		_pending_request_id = _mp_connection.admin_set_ban(
			target_pid, _pending_duration_seconds, _pending_duration_mode,
			_pending_include_network)
	else:
		_pending_action = ""
		_pending_request_id = 0
		_set_moderation_status("玩家当前不在线")
		return
	if _pending_request_id <= 0:
		_set_moderation_status("请求未发送")
	else:
		_set_moderation_status("处理中…")


func _network_submission_error(record: Dictionary) -> String:
	var scope := str(record.get("scope", "installation"))
	if not _pending_include_network and scope != "network":
		return ""
	var has_network := scope in ["installation_network", "network"]
	if has_network:
		if str(record.get("duration_mode", "finite")) == "permanent":
			return ""
		var now := int(_mp_connection.get_estimated_server_unix_msec() / 1000)
		if (_pending_duration_mode != "permanent"
				and now + _pending_duration_seconds <= int(record.get("expires_at", 0))):
			return ""
	var state := _mp_connection.get_admin_network_scope_state(_player_meta, record)
	return "" if bool(state.get("available", false)) else str(state.get("reason", ""))


func _refresh_network_scope() -> void:
	if not _moderation_popup.visible or _pending_kind.is_empty():
		return
	if is_instance_valid(_mp_connection) and not _editing_record.is_empty():
		for value in _mp_connection.get_admin_punishments_snapshot():
			var record := value as Dictionary
			if str(record.get("ban_id", "")) == str(_editing_record.get("ban_id", "")):
				_editing_record = record.duplicate(true)
				break
	_configure_network_scope(_pending_kind, _editing_record, false)


func _on_admin_authentication_changed(
		_authenticated: bool, _admin_id: String, _error: String) -> void:
	_refresh_player_actions()
	if not _authenticated:
		_pending_request_id = 0
		_pending_action = ""
	_refresh_network_scope()


func _on_admin_snapshot_changed(_items: Array) -> void:
	_refresh_player_actions()
	_refresh_network_scope()


func _on_admin_action_result(
		request_id: int, action: String, success: bool, code: String, detail: String) -> void:
	if request_id != _pending_request_id or action != _pending_action:
		if success and is_instance_valid(_mp_connection):
			_mp_connection.request_admin_context_snapshot()
		return
	_pending_request_id = 0
	if success:
		_moderation_popup.hide()
		_mp_connection.request_admin_context_snapshot()
	elif action == "punishment_update" and code == "already_expired":
		if (not _moderation_popup.visible or not is_instance_valid(_mp_connection)
				or not _mp_connection.is_admin_authenticated()):
			return
		var network_error := _network_submission_error({})
		if not network_error.is_empty():
			_set_moderation_status(network_error)
			return
		var target_pid := _resolve_target_pid()
		if target_pid <= 0:
			_set_moderation_status("玩家当前不在线")
			return
		_editing_record.clear()
		_pending_action = "set_mute" if _pending_kind == "mute" else "set_ban"
		_pending_request_id = (
			_mp_connection.admin_set_mute(
				target_pid, _pending_duration_seconds, _pending_duration_mode,
				_pending_include_network)
			if _pending_kind == "mute"
			else _mp_connection.admin_set_ban(
				target_pid, _pending_duration_seconds, _pending_duration_mode,
				_pending_include_network))
		_set_moderation_status("处理中…" if _pending_request_id > 0 else "请求未发送")
	else:
		_set_moderation_status(detail if not detail.is_empty() else "操作失败")


func _unhandled_key_input(event: InputEvent) -> void:
	if not is_instance_valid(_moderation_popup) or not _moderation_popup.visible:
		return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.is_action_pressed("ui_cancel"):
		_moderation_popup.hide()
		get_viewport().set_input_as_handled()
	elif key.is_action_pressed("ui_accept"):
		_on_moderation_confirmed()
		get_viewport().set_input_as_handled()


func _on_copy_pressed() -> void:
	if not is_instance_valid(_chat_selection):
		return
	var selected_text := str(_chat_selection.call("get_selected_text"))
	if not selected_text.is_empty():
		DisplayServer.clipboard_set(selected_text)
	_context_popup.hide()


func _on_select_all_pressed() -> void:
	if is_instance_valid(_chat_selection):
		_chat_selection.call("select_all")
	_context_popup.hide()


func has_touch_modal() -> bool:
	return _context_popup.visible or _moderation_popup.visible


func handle_touch_back() -> bool:
	for option in [_custom_unit, _duration_options]:
		if option.get_popup().visible:
			option.get_popup().hide()
			return true
	if _moderation_popup.visible:
		_moderation_popup.hide()
		return true
	if _context_popup.visible:
		dismiss_context_menu()
		return true
	return false

func _style_moderation_actions() -> void:
	var skin := _moderation_popup.get_node_or_null("__SystemUISkin") as SystemUISkin
	if skin == null or not is_instance_valid(_moderation_footer): return
	var border: StyleBox = skin.get("_border_panel").get_theme_stylebox("panel")
	for button: Button in _moderation_footer.get("_row").get_children():
		# Text styling intentionally clears regular game buttons. Only this
		# dialog's footer restores the current local System border afterwards.
		if button.has_meta(&"moderation_border_source") and button.get_meta(&"moderation_border_source") == border and not button.get_theme_stylebox("normal") is StyleBoxEmpty:
			continue
		button.set_meta(&"moderation_border_source", border)
		for state: String in preload("res://cogs/dialog_footer.gd").STATES:
			var style := border.duplicate() as StyleBox
			if state in ["hover", "pressed", "hover_pressed", "disabled"]:
				if style is StyleBoxTexture: style.modulate_color = Color(0.56, 0.56, 0.56, 1)
				elif style is StyleBoxFlat: style.border_color *= Color(0.56, 0.56, 0.56, 1)
			button.add_theme_stylebox_override(state, style)
		button.remove_meta(&"dialog_footer_metrics")
	_moderation_footer._refresh()


func _style_duration_option(button: OptionButton) -> void:
	var skin := _moderation_popup.get_node_or_null("__SystemUISkin") as SystemUISkin
	if skin == null: return
	var frame := preload("res://cogs/launcher_popup_frame.gd").new()
	frame.background = skin.get("_background_panel").get_theme_stylebox("panel")
	frame.border = skin.get("_border_panel").get_theme_stylebox("panel")
	var vertical := UiScale.physical_int(4)
	var horizontal := maxf(vertical, ceilf(button.get_theme_font("font").get_string_size("汉", HORIZONTAL_ALIGNMENT_LEFT, -1, button.get_theme_font_size("font_size")).x * 0.5))
	frame.set_content_margin_all(vertical)
	frame.set_content_margin(SIDE_LEFT, horizontal)
	frame.set_content_margin(SIDE_RIGHT, horizontal)
	for state: String in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		var style := preload("res://cogs/launcher_popup_style.gd").copy_frame(frame)
		if state == "focus": style.background = null
		if state in ["hover", "pressed", "hover_pressed", "disabled"]:
			style.border = frame.border.duplicate()
			if style.border is StyleBoxTexture:
				style.border.modulate_color = Color(0.56, 0.56, 0.56, 1)
			elif style.border is StyleBoxFlat:
				style.border.border_color *= Color(0.56, 0.56, 0.56, 1)
		button.add_theme_stylebox_override(state, style)
	preload("res://cogs/launcher_popup_style.gd").install(button)
	if button == _custom_unit:
		# This option shares a horizontal row with an expanding SpinBox.
		button.custom_minimum_size.x = ceili(preload("res://cogs/launcher_popup_style.gd").option_width(button))
