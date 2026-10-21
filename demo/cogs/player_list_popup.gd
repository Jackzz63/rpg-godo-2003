class_name PlayerListPopup
extends PopupPanel

const PopupGeometryScript := preload("res://cogs/popup_geometry.gd")
const _PLAYER_CONTEXT_MENU := preload("res://cogs/chat_player_context_menu.gd")
const PlayerName := preload("res://cogs/chat_player_name.gd")
const LocationTextLayout := preload("res://cogs/location_text_layout.gd")
const SelectionBorder := preload("res://cogs/ui_selection_border.gd")

const _GAME_UI_FONT := preload("res://resources/webpage_game_ui_font.tres")
const _WEBPAGE_THEME_TEXT_RUNTIME := preload("res://cogs/webpage_theme_text_runtime.gd")
const _ADMIN_ICON := preload("res://resources/icons/usershield.svg")
const _IP_ICON := preload("res://resources/icons/ip.svg")
const _NORMAL_COLOR := Color(0.25, 0.92, 0.38, 1.0)
const _MUTED_COLOR := Color(1.0, 0.62, 0.18, 1.0)
const _BANNED_COLOR := Color(1.0, 0.24, 0.18, 1.0)
const _SHADOW_COLOR := Color(0.0, 0.0, 0.0, 1.0)
const _COUNTDOWN_REFRESH_SECONDS := 0.25
const _PLAYER_LIST_REFRESH_SECONDS := 6.0
const _ADMIN_REFRESH_SECONDS := 2.0

var _connection: EasyMultiplayer = null
var _chat_overlay: Node = null
var _location_runtime: Node = null
var _display_language := "en"
var _tab_buttons: Array[Button] = []
var _tab_bar: BoxContainer = null
var _tab_rows: Array[HBoxContainer] = []
var _tab_frames: Array[Panel] = []
var _tab_layout_pending := false
var _tab_scrolls: Array[ScrollContainer] = []
var _current_tab := 0
var _lists: Array[VBoxContainer] = []
var _online_players: Array = []
var _punishments: Array = []
var _player_list_refresh_timer: Timer
var _admin_refresh_timer: Timer
var _countdown_timer: Timer
var _status_labels: Array[Dictionary] = []
var _status_menu: PopupPanel
var _status_menu_content: MarginContainer
var _status_anchor_ratio := Vector2.ZERO
var _status_anchor_control: WeakRef = null
var _status_anchor_local := Vector2.ZERO
var _status_menu_record: Dictionary = {}
var _status_change_button: Button
var _status_change_row: HBoxContainer
var _status_revoke_button: Button
var _status_revoke_row: HBoxContainer
var _player_context_menu: Node = null
var _ui_normal_color := Color.WHITE
var _ui_strong_color := Color.GOLD
var _ui_muted_color := Color.GRAY
var _local_text_controls: Array[Control] = []
var _theme_text_runtime: Node = null
var _query_errors: Dictionary = {}
var _punishments_loading := false
var _player_list_loading := false
var _player_list_unavailable := false
var _recenter_after_resize_pending := false
var _status_reflow_pending := false
var _status_reflow_serial := 0
var _status_open_serial := 0
var _status_requested := false
var _list_cards: Array[Dictionary] = [{}, {}, {}]
var _list_signatures: Array[Dictionary] = [{}, {}, {}]
var _list_dirty: Array[bool] = [true, true, true]
var _list_force: Array[bool] = [true, true, true]


func _ready() -> void:
	UiScale.safe_area_changed.connect(_queue_recenter_after_resize)
	_theme_text_runtime = _WEBPAGE_THEME_TEXT_RUNTIME.new()
	add_child(_theme_text_runtime)
	_build_ui()
	_player_list_refresh_timer = Timer.new()
	_player_list_refresh_timer.wait_time = _PLAYER_LIST_REFRESH_SECONDS
	_player_list_refresh_timer.timeout.connect(_request_player_snapshot)
	add_child(_player_list_refresh_timer)
	_admin_refresh_timer = Timer.new()
	_admin_refresh_timer.wait_time = _ADMIN_REFRESH_SECONDS
	_admin_refresh_timer.timeout.connect(_request_admin_snapshot)
	add_child(_admin_refresh_timer)
	_countdown_timer = Timer.new()
	_countdown_timer.wait_time = _COUNTDOWN_REFRESH_SECONDS
	_countdown_timer.timeout.connect(_update_countdowns)
	add_child(_countdown_timer)
	_build_status_menu()
	_player_context_menu = _PLAYER_CONTEXT_MENU.new()
	add_child(_player_context_menu)
	_player_context_menu.setup(_connection, null)
	_player_context_menu.set_display_language(_display_language)
	_player_context_menu.mention_requested.connect(_on_player_mention_requested)
	_player_context_menu.right_click_released.connect(_open_right_click_at)
	_player_context_menu.right_click_started.connect(_dismiss_status_menu)
	_player_context_menu.other_context_requested = func() -> bool: return _status_requested
	_player_context_menu.watch_right_click_popup(_status_menu)
	popup_hide.connect(_on_popup_hidden)
	var root_viewport := get_tree().root
	if not root_viewport.size_changed.is_connected(_queue_recenter_after_resize):
		root_viewport.size_changed.connect(_queue_recenter_after_resize)
	if not UiScale.scale_changed.is_connected(_on_ui_scale_changed):
		UiScale.scale_changed.connect(_on_ui_scale_changed)


func setup(connection: EasyMultiplayer, chat_overlay: Node) -> void:
	_chat_overlay = chat_overlay
	set_multiplayer_connection(connection)


func set_multiplayer_connection(connection: EasyMultiplayer) -> void:
	if _connection == connection:
		return
	_unbind_connection()
	_connection = connection
	_online_players.clear()
	_punishments.clear()
	_query_errors.clear()
	_punishments_loading = false
	dismiss()
	_bind_connection()
	if is_instance_valid(_player_context_menu):
		_player_context_menu.set_multiplayer_connection(connection)
	refresh_access()


func set_location_runtime(runtime: Node) -> void:
	if _location_runtime == runtime:
		return
	if (is_instance_valid(_location_runtime) and _location_runtime.has_signal("language_changed")
			and _location_runtime.is_connected("language_changed", _on_location_language_changed)):
		_location_runtime.disconnect("language_changed", _on_location_language_changed)
	_location_runtime = runtime
	if is_instance_valid(runtime) and runtime.has_signal("language_changed"):
		runtime.connect("language_changed", _on_location_language_changed)
	_on_location_language_changed(str(runtime.call("get_language_code")) if is_instance_valid(runtime) and runtime.has_method("get_language_code") else "en")


func _on_location_language_changed(language: String) -> void:
	_display_language = language
	if is_instance_valid(_player_context_menu):
		_player_context_menu.set_display_language(language)
	_rebuild_lists(true)


var _theme_source_override: Node


func set_theme_source(source: Node) -> void:
	_theme_source_override = source
	if is_instance_valid(_player_context_menu):
		_player_context_menu.set_theme_source(source)


func _theme_source() -> Node:
	return _theme_source_override if is_instance_valid(_theme_source_override) else _connection


func set_ui_theme_colors(normal: Color, strong: Color, muted: Color) -> void:
	_ui_normal_color = normal
	_ui_strong_color = strong
	_ui_muted_color = muted
	if is_instance_valid(_theme_text_runtime):
		_theme_text_runtime.clear_caches()
	if is_instance_valid(_player_context_menu):
		_player_context_menu.set_ui_theme_colors(normal, strong, muted)
	_refresh_tab_buttons()
	for control in _local_text_controls:
		if is_instance_valid(control):
			_apply_text_style(control, _ui_normal_color)
	if visible:
		call_deferred("_apply_popup_skin", self, "", -1)
	_rebuild_lists(true)


func open_player_list() -> void:
	if visible or not is_instance_valid(_connection):
		return
	refresh_access()
	var viewport_size := Vector2i(
		_chat_overlay.get_viewport().get_visible_rect().size
		if is_instance_valid(_chat_overlay)
		else get_tree().root.get_visible_rect().size)
	var maximum_size := UiScale.physical_size(Vector2i(467, 350))
	var minimum_size := UiScale.physical_size(Vector2i(200, 150))
	var viewport_margin := UiScale.physical_int(24.0)
	var popup_size := Vector2i(
		mini(maximum_size.x, maxi(minimum_size.x, viewport_size.x - viewport_margin)),
		mini(maximum_size.y, maxi(minimum_size.y, viewport_size.y - viewport_margin))
	)
	min_size = Vector2i.ZERO
	popup(_player_list_rect())
	_rebuild_lists()
	call_deferred("_apply_popup_skin", self, "", -1)
	_player_list_refresh_timer.start()
	_admin_refresh_timer.start()
	_countdown_timer.start()
	_request_snapshots()


func dismiss() -> void:
	if is_instance_valid(_player_context_menu):
		_player_context_menu.dismiss()
	if visible:
		hide()
	_on_popup_hidden()


func _on_popup_hidden() -> void:
	_dismiss_status_menu()
	_status_reflow_serial += 1
	if is_instance_valid(_player_list_refresh_timer):
		_player_list_refresh_timer.stop()
	if is_instance_valid(_admin_refresh_timer):
		_admin_refresh_timer.stop()
	if is_instance_valid(_countdown_timer):
		_countdown_timer.stop()
	if is_instance_valid(_status_menu):
		_status_menu.hide()
	if is_instance_valid(_player_context_menu):
		_player_context_menu.dismiss()


func _queue_recenter_after_resize() -> void:
	if not visible:
		return
	if not _recenter_after_resize_pending:
		_recenter_after_resize_pending = true
		call_deferred("_recenter_after_resize")
	_queue_status_menu_reflow()


func _recenter_after_resize() -> void:
	_recenter_after_resize_pending = false
	if visible:
		PopupGeometryScript.apply_rect(self, _player_list_rect())


func _player_list_rect() -> Rect2i:
	_fit_list_width()
	var target := UiScale.physical_size(Vector2i(467, 350))
	var minimum := PopupGeometryScript.content_minimum_size(self)
	# The list viewport may scroll vertically; only its visible cards' required
	# width can enlarge the frame. Never use the sum of all card heights here.
	if _current_tab < _lists.size():
		minimum.x = maxi(minimum.x, ceili(_lists[_current_tab].get_combined_minimum_size().x)
			+ UiScale.physical_int(28.0))
	return PopupGeometryScript.centered_rect(
		self,
		target.max(minimum),
		UiScale.physical_size(Vector2i(200, 150)).max(minimum),
		UiScale.physical_int(12.0))


func _fit_list_width() -> void:
	var available := float(PopupGeometryScript.bounds_for(self).size.x - UiScale.physical_int(24))
	var tab_width := float(_tab_bar.get_theme_constant("separation") * 2)
	for button in _tab_buttons:
		tab_width += button.get_combined_minimum_size().x
	_tab_bar.vertical = tab_width + UiScale.physical_value(16) > available
	# The viewport can scroll down, but it cannot expose clipped card columns.
	# Wrap only names whose intrinsic card width exceeds the safe width.
	for cards in _list_cards:
		for card: Control in cards.values():
			var name_label := card.find_child("PlayerName", true, false) as Label
			if name_label == null:
				continue
			var row := card.get_meta("content") as BoxContainer
			row.vertical = false
			var natural_width := name_label.get_theme_font("font").get_string_size(
				name_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, name_label.get_theme_font_size("font_size")).x
			var other_width := card.get_combined_minimum_size().x - name_label.get_combined_minimum_size().x
			var wrap := natural_width + other_width + UiScale.physical_value(28) > available
			name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if wrap else TextServer.AUTOWRAP_OFF
			name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL if wrap else Control.SIZE_FILL
			# A punishment status plus avatar can exceed the budget even with a wrapped name.
			row.vertical = card.get_combined_minimum_size().x + UiScale.physical_value(28) > available


func _status_menu_rect() -> Rect2i:
	return PopupGeometryScript.anchored_rect(
		_status_menu,
		_status_menu_size(),
		_resolved_status_anchor(),
		UiScale.physical_int(4.0))


func _status_menu_size() -> Vector2i:
	var content_size := (
		_status_menu_content.get_combined_minimum_size()
		if is_instance_valid(_status_menu_content) else Vector2.ZERO)
	return Vector2i(
		maxi(UiScale.physical_int(16.0), ceili(content_size.x)),
		maxi(UiScale.physical_int(16.0), ceili(content_size.y)))


func refresh_access() -> void:
	if _tab_buttons.size() < 3:
		return
	var admin := is_instance_valid(_connection) and _connection.is_admin_authenticated()
	_tab_buttons[2].visible = admin
	if not admin and _current_tab == 2:
		_select_tab(0)
	_refresh_tab_buttons()
	_rebuild_lists(true)


func _bind_connection() -> void:
	if not is_instance_valid(_connection):
		return
	if not _connection.list_query_failed.is_connected(_on_list_query_failed):
		_connection.list_query_failed.connect(_on_list_query_failed)
	if not _connection.admin_roster_received.is_connected(_on_roster_received):
		_connection.admin_roster_received.connect(_on_roster_received)
	if not _connection.player_list_received.is_connected(_on_player_list_received):
		_connection.player_list_received.connect(_on_player_list_received)
	if not _connection.connection_state_changed.is_connected(_on_connection_state_changed):
		_connection.connection_state_changed.connect(_on_connection_state_changed)
	if not _connection.privacy_state_changed.is_connected(_on_privacy_state_changed):
		_connection.privacy_state_changed.connect(_on_privacy_state_changed)
	if not _connection.admin_bans_received.is_connected(_on_punishments_received):
		_connection.admin_bans_received.connect(_on_punishments_received)
	if not _connection.admin_authentication_changed.is_connected(_on_admin_changed):
		_connection.admin_authentication_changed.connect(_on_admin_changed)
	if not _connection.admin_action_result.is_connected(_on_admin_action_result):
		_connection.admin_action_result.connect(_on_admin_action_result)
	if not _connection.player_profile_sprite_changed.is_connected(
			_on_player_profile_sprite_changed):
		_connection.player_profile_sprite_changed.connect(
			_on_player_profile_sprite_changed)


func _unbind_connection() -> void:
	if not is_instance_valid(_connection):
		return
	var callbacks := {
		"list_query_failed": Callable(self, "_on_list_query_failed"),
		"admin_roster_received": Callable(self, "_on_roster_received"),
		"player_list_received": Callable(self, "_on_player_list_received"),
		"connection_state_changed": Callable(self, "_on_connection_state_changed"),
		"privacy_state_changed": Callable(self, "_on_privacy_state_changed"),
		"admin_bans_received": Callable(self, "_on_punishments_received"),
		"admin_authentication_changed": Callable(self, "_on_admin_changed"),
		"admin_action_result": Callable(self, "_on_admin_action_result"),
		"player_profile_sprite_changed": Callable(
			self, "_on_player_profile_sprite_changed"),
	}
	for signal_name in callbacks:
		var callback: Callable = callbacks[signal_name]
		if _connection.is_connected(signal_name, callback):
			_connection.disconnect(signal_name, callback)


func _build_ui() -> void:
	add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	add_child(margin)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var layout := VBoxContainer.new()
	layout.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layout.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_theme_constant_override("separation", 2)
	margin.add_child(layout)
	_tab_bar = BoxContainer.new()
	_tab_bar.add_theme_constant_override(
		"separation", UiScale.physical_int(4.0))
	layout.add_child(_tab_bar)
	for index in 3:
		var button := Button.new()
		button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		button.flat = true
		button.toggle_mode = true
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(_select_tab.bind(index))
		_tab_bar.add_child(button)
		_tab_buttons.append(button)
	var content := Control.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(content)
	for title in ["当前世界", "全服务器", "禁言/封禁"]:
		var scroll := ScrollContainer.new()
		scroll.name = title
		scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroll.visible = _tab_scrolls.is_empty()
		var list := VBoxContainer.new()
		list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		list.size_flags_vertical = Control.SIZE_EXPAND_FILL
		list.add_theme_constant_override("separation", 4)
		list.minimum_size_changed.connect(_queue_recenter_after_resize)
		scroll.add_child(list)
		content.add_child(scroll)
		_tab_scrolls.append(scroll)
		_lists.append(list)
		scroll.get_v_scroll_bar().visibility_changed.connect(_layout_scrollbars)
	_layout_scrollbars()
	_refresh_tab_buttons()


func _layout_scrollbars() -> void:
	for scroll in _tab_scrolls:
		var bar := scroll.get_v_scroll_bar()
		# The outer margin is 8. Extend only the scrolling area by 4 when needed.
		UiScale.mark_geometry_physical(scroll)
		# Never push the bar beyond the popup when the frame is already clamped.
		var extra := UiScale.physical_value(4.0) if bar.visible else 0.0
		scroll.offset_right = minf(extra, maxf(0.0, size.x - scroll.get_global_rect().end.x + scroll.offset_right))
		scroll.add_theme_constant_override("scrollbar_h_separation", UiScale.physical_int(4.0))
		UiScale.mark_styles_physical(bar)
		for state: String in ["scroll", "scroll_focus", "grabber", "grabber_highlight", "grabber_pressed"]:
			var style := ThemeDB.get_default_theme().get_stylebox(state, "VScrollBar").duplicate() as StyleBox
			style.set_content_margin(SIDE_LEFT, 6.0)
			style.set_content_margin(SIDE_RIGHT, 6.0)
			UiScale.apply_physical_stylebox(bar, state, style)


func _select_tab(index: int) -> void:
	if index < 0 or index >= _tab_scrolls.size():
		return
	if index != _current_tab:
		_dismiss_status_menu()
		if is_instance_valid(_player_context_menu):
			_player_context_menu.dismiss_context_menu()
	_current_tab = index
	for tab_index in _tab_scrolls.size():
		_tab_scrolls[tab_index].visible = tab_index == index
	_refresh_tab_buttons()
	_rebuild_lists()


func _refresh_tab_buttons() -> void:
	if _tab_buttons.size() < 3:
		return
	if is_instance_valid(_tab_bar):
		_tab_bar.add_theme_constant_override(
			"separation", UiScale.physical_int(4.0))
	var titles := ["当前世界", "全服务器", "禁言/封禁"]
	_tab_rows.clear()
	_tab_frames.clear()
	for index in _tab_buttons.size():
		var button := _tab_buttons[index]
		for child in button.get_children():
			button.remove_child(child)
			child.queue_free()
		button.button_pressed = index == _current_tab
		if is_instance_valid(_theme_text_runtime):
			_theme_text_runtime.style_button(button)
		var row := HBoxContainer.new()
		UiScale.mark_geometry_physical(button)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		preload("res://cogs/ui_text_baseline.gd").install(row)
		row.add_theme_constant_override("separation", 2)
		button.add_child(row)
		row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var title_label := Label.new()
		title_label.text = titles[index]
		title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		title_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var title_role := (
			int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG) if index == _current_tab
			else int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_NORMAL))
		_apply_text_style(
			title_label,
			_ui_strong_color if index == _current_tab else _ui_normal_color,
			title_role)
		row.add_child(title_label)
		if index == 2:
			var icon := TextureRect.new()
			icon.texture = _ADMIN_ICON
			icon.custom_minimum_size = Vector2(14, 14)
			icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
			if is_instance_valid(_theme_text_runtime):
				_theme_text_runtime.style_icon(
					icon, _theme_source(), "",
					int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG) if index == _current_tab
					else int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_NORMAL),
					false, 14.0)
			row.add_child(icon)
		var row_minimum := row.get_combined_minimum_size()
		button.custom_minimum_size = Vector2(
			maxf(
				UiScale.physical_value(82.0),
				ceilf(row_minimum.x) + UiScale.physical_value(16.0)),
			maxf(
				UiScale.physical_value(22.0),
				ceilf(row_minimum.y) + UiScale.physical_value(4.0)))
		_tab_rows.append(row)
		_tab_frames.append(SelectionBorder.add_to(button))
		row.sort_children.connect(_queue_tab_layout)
	_queue_tab_layout()


func _queue_tab_layout() -> void:
	if _tab_layout_pending:
		return
	_tab_layout_pending = true
	_layout_tab_frames.call_deferred()


func _tab_ink(row: HBoxContainer) -> Rect2:
	var ink := Rect2()
	for child in row.get_children():
		var bounds: Rect2 = SelectionBorder.label_ink(child) if child is Label else Rect2(Vector2.ZERO, child.size)
		if child is TextureRect and child.texture != null:
			var texture_size: Vector2 = child.texture.get_size()
			var drawn_size := texture_size * minf(child.size.x / texture_size.x, child.size.y / texture_size.y)
			bounds = Rect2((child.size - drawn_size) * 0.5, drawn_size)
		bounds.position += child.position
		ink = bounds if not ink.has_area() else ink.merge(bounds)
	return ink


func _layout_tab_frames() -> void:
	_tab_layout_pending = false
	var skin := get_node_or_null("__SystemUISkin") as SystemUISkin
	if skin == null or _tab_rows.size() != 3:
		return
	var edges := skin.selection_border_insets() * UiScale.get_ui_scale()
	var ink: Array[Rect2] = []
	var old_widths: Array[float] = []
	var old_lefts: Array[float] = []
	var old_rights: Array[float] = []
	for row in _tab_rows:
		var bounds := _tab_ink(row)
		var content := row.get_combined_minimum_size()
		var old_width := maxf(UiScale.physical_value(82.0), ceilf(content.x) + UiScale.physical_value(16.0))
		ink.append(bounds)
		old_widths.append(old_width)
		# Reconstruct the original centered row from its intrinsic sizes. Using
		# today's framed width here feeds integer centering back into the padding.
		var first: Label = row.get_child(0)
		var last: Control = row.get_child(row.get_child_count() - 1)
		var left_ink := SelectionBorder.label_ink(first, first.get_combined_minimum_size()).position.x
		var right_bearing := 0.0
		if last is Label:
			right_bearing = last.get_combined_minimum_size().x - SelectionBorder.label_ink(last, last.get_combined_minimum_size()).end.x
		var old_start := floorf((old_width - content.x) * 0.5)
		old_lefts.append(old_start + left_ink)
		old_rights.append(old_width - old_start - content.x + right_bearing)
	var gap := INF
	for index in 2:
		gap = minf(gap, old_rights[index] + UiScale.physical_value(4.0) + old_lefts[index + 1])
	for index in 3:
		var content := _tab_rows[index].get_combined_minimum_size()
		# Compact buttons leave the font's own line bearing inside the frame.
		var padding := Vector2(ceilf(maxf(0.0, gap) / 3.0), maxf(0.0, (content.y - ink[index].size.y) * 0.5))
		_tab_buttons[index].custom_minimum_size = Vector2(
			maxf(old_widths[index], ceilf(ink[index].size.x + 2.0 * padding.x + edges.x + edges.z)),
			ceilf(content.y + edges.y + edges.w))
		_tab_frames[index].fit(ink[index], padding, skin, index == _current_tab)
	_queue_recenter_after_resize()


func _request_snapshots() -> void:
	_request_player_snapshot()
	_request_admin_snapshot()


func _request_player_snapshot() -> void:
	if not visible or not is_instance_valid(_connection):
		return
	var request_id := _connection.request_player_list()
	_player_list_unavailable = request_id == 0
	_player_list_loading = request_id > 0 and _online_players.is_empty()
	if _online_players.is_empty():
		_rebuild_lists()


func _request_admin_snapshot() -> void:
	if (not visible or not is_instance_valid(_connection)
			or not _connection.is_admin_authenticated()):
		return
	_punishments_loading = _punishments.is_empty()
	_connection.request_admin_context_snapshot()


func _on_player_list_received(players: Array) -> void:
	var perf_start := ClientPerformance.begin()
	_on_player_list_received_measured(players)
	ClientPerformance.end(&"ui.player_list_inclusive", perf_start)


func _on_player_list_received_measured(players: Array) -> void:
	_query_errors.erase("plist")
	_player_list_loading = false
	_player_list_unavailable = false
	_online_players = players.duplicate(true)
	if is_instance_valid(_connection):
		for player_value in _online_players:
			var player := player_value as Dictionary
			var canonical := _connection.get_player_sprite_snapshot(
				int(player.get("pid", 0)))
			if not canonical.is_empty():
				player["sprite_name"] = str(canonical.get("sprite_name", ""))
				player["sprite_index"] = int(canonical.get("sprite_index", 0))
	_rebuild_lists()


func _on_player_profile_sprite_changed(
		pid: int, sprite_name: String, sprite_index: int) -> void:
	if pid <= 0:
		return
	var changed := false
	for player_value in _online_players:
		var player := player_value as Dictionary
		if int(player.get("pid", 0)) != pid:
			continue
		if (str(player.get("sprite_name", "")) != sprite_name
				or int(player.get("sprite_index", 0)) != sprite_index):
			player["sprite_name"] = sprite_name
			player["sprite_index"] = sprite_index
			changed = true
	if changed:
		_rebuild_lists()


func _on_list_query_failed(kind: String, _request_id: int, code: String) -> void:
	_query_errors[kind] = code
	if kind == "plist":
		_player_list_loading = false
		_player_list_unavailable = _online_players.is_empty()
	elif kind == "bans":
		_punishments_loading = false
	_rebuild_lists()


func _on_roster_received(_roster: Array) -> void:
	_query_errors.erase("roster")
	_rebuild_lists()


func _on_punishments_received(punishments: Array) -> void:
	_query_errors.erase("bans")
	_punishments_loading = false
	_punishments = punishments.duplicate(true)
	_rebuild_lists()


func _on_admin_changed(_authenticated: bool, _admin_id: String, _error: String) -> void:
	_query_errors.clear()
	if not _authenticated:
		_punishments_loading = false
		_punishments.clear()
		_dismiss_status_menu()
		_player_context_menu.dismiss()
	refresh_access()
	_request_snapshots()


func _on_admin_action_result(
		_request_id: int, _action: String, success: bool, _code: String, _detail: String) -> void:
	if success:
		_request_snapshots()


func _rebuild_lists(force: bool = false) -> void:
	if _lists.size() < 3:
		return
	for index in 3:
		_list_dirty[index] = true
		_list_force[index] = _list_force[index] or force
	if not visible:
		ClientPerformance.count_event(&"ui.list_hidden_updates")
		return
	_render_active_list()


func _render_active_list() -> void:
	var index := _current_tab
	if not _list_dirty[index]:
		return
	var perf_start := ClientPerformance.begin()
	var force := _list_force[index]
	_list_dirty[index] = false
	_list_force[index] = false
	if index < 2:
		var current_map := _connection.get_current_map_id() if is_instance_valid(_connection) else -1
		var players: Array = []
		for value in _online_players:
			var player := (value as Dictionary).duplicate(true)
			if index == 0 and int(player.get("room_id", -1)) != current_map:
				continue
			if is_instance_valid(_connection):
				var canonical := _connection.get_player_sprite_snapshot(int(player.get("pid", 0)))
				if not canonical.is_empty():
					player["sprite_name"] = str(canonical.get("sprite_name", ""))
					player["sprite_index"] = int(canonical.get("sprite_index", 0))
			if index == 1:
				player["_display_location"] = _resolve_card_location(player)
			players.append(player)
		_sort_players(players)
		_reconcile_player_list(index, players, index == 1, force)
	else:
		var active: Array = []
		if is_instance_valid(_connection) and _connection.is_admin_authenticated():
			active = _group_punishments(_punishments)
			active.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				var comparison := str(a.get("display_name", "")).naturalnocasecmp_to(
					str(b.get("display_name", "")))
				return comparison < 0 if comparison != 0 else (
					str(a.get("group_key", "")) < str(b.get("group_key", ""))))
		_reconcile_punishment_list(active, force)
	_update_empty_state(index)
	_update_countdowns()
	if is_instance_valid(_player_context_menu):
		_player_context_menu.notify_player_list_changed()
	ClientPerformance.end(&"ui.list_render", perf_start)


func _on_connection_state_changed(state: int) -> void:
	if state == EasyMultiplayer.ConnectionState.CONNECTED:
		return
	_query_errors.clear()
	_punishments_loading = false
	_online_players.clear()
	_punishments.clear()
	dismiss()
	_rebuild_lists(true)


func _on_privacy_state_changed(desired: bool, authoritative: bool, pending: bool) -> void:
	if desired or authoritative or pending:
		_query_errors.clear()
		_punishments_loading = false
		_online_players.clear()
		_punishments.clear()
		dismiss()
		_rebuild_lists(true)


func _reconcile_player_list(
		index: int, players: Array, show_location: bool, force: bool) -> void:
	_remove_empty_state(index)
	var list := _lists[index]
	var cards := _list_cards[index]
	var signatures := _list_signatures[index]
	var desired: Dictionary = {}
	var order: Array[String] = []
	for player_value in players:
		var player := player_value as Dictionary
		var key := "pid:%d" % int(player.get("pid", 0))
		var signature := _player_card_signature(player, show_location)
		var card := cards.get(key) as Control
		if (force or not is_instance_valid(card)
				or str(signatures.get(key, "")) != signature):
			_discard_cached_card(index, key)
			card = _make_player_card(player, show_location)
			ClientPerformance.count_event(&"ui.player_cards_created")
			cards[key] = card
			signatures[key] = signature
		if card.get_parent() == null:
			list.add_child(card)
		var name_label := card.find_child("PlayerName", true, false)
		if name_label != null:
			name_label.set_meta("player_current_data", player.duplicate(true))
			name_label.set_meta("player_list_key", key)
		desired[key] = true
		order.append(key)
	for key_value in cards.keys():
		var key := str(key_value)
		if not desired.has(key):
			_discard_cached_card(index, key)
	for position in order.size():
		var card := cards.get(order[position]) as Control
		if is_instance_valid(card) and card.get_parent() == list:
			list.move_child(card, position)


func _reconcile_punishment_list(punishments: Array, force: bool) -> void:
	var index := 2
	_remove_empty_state(index)
	var list := _lists[index]
	var cards := _list_cards[index]
	var signatures := _list_signatures[index]
	var desired: Dictionary = {}
	var order: Array[String] = []
	for punishment_value in punishments:
		var punishment := punishment_value as Dictionary
		var key := "punishment:%s" % str(punishment.get("group_key", ""))
		var signature := JSON.stringify(punishment)
		var card := cards.get(key) as Control
		if (force or not is_instance_valid(card)
				or str(signatures.get(key, "")) != signature):
			_discard_cached_card(index, key)
			card = _make_punishment_card(punishment)
			cards[key] = card
			signatures[key] = signature
		if card.get_parent() == null:
			list.add_child(card)
		var name_label := card.find_child("PlayerName", true, false)
		if name_label != null:
			name_label.set_meta("player_list_key", key)
		desired[key] = true
		order.append(key)
	for key_value in cards.keys():
		var key := str(key_value)
		if not desired.has(key):
			_discard_cached_card(index, key)
	for position in order.size():
		var card := cards.get(order[position]) as Control
		if is_instance_valid(card) and card.get_parent() == list:
			list.move_child(card, position)


func _group_punishments(records: Array) -> Array:
	var grouped: Dictionary = {}
	for value in records:
		var record := (value as Dictionary).duplicate(true)
		var subject_group_id := str(record.get("subject_group_id", ""))
		var key := (
			"subject:" + subject_group_id
			if not subject_group_id.is_empty()
			else "record:" + str(record.get("ban_id", "")))
		if grouped.has(key):
			var existing_records := grouped[key] as Array
			for existing_value in existing_records:
				var existing := existing_value as Dictionary
				if str(existing.get("kind", "")) == str(record.get("kind", "")):
					key += ":" + str(record.get("ban_id", ""))
					break
		if not grouped.has(key):
			grouped[key] = []
		(grouped[key] as Array).append(record)
	var result: Array = []
	for key_value in grouped:
		var key := str(key_value)
		var group_records := (grouped[key] as Array).duplicate(true)
		group_records.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var a_order := 0 if str(a.get("kind", "")) == "mute" else 1
			var b_order := 0 if str(b.get("kind", "")) == "mute" else 1
			return a_order < b_order)
		var canonical := _canonical_punishment_record(group_records)
		var group := canonical.duplicate(true)
		group["group_key"] = key
		group["punishments"] = group_records
		group["display_name"] = str(canonical.get("last_name", ""))
		result.append(group)
	return result


func _canonical_punishment_record(records: Array) -> Dictionary:
	var best: Dictionary = {}
	for value in records:
		var candidate := value as Dictionary
		if best.is_empty():
			best = candidate
			continue
		var candidate_online := int(candidate.get("online_pid", 0)) > 0
		var best_online := int(best.get("online_pid", 0)) > 0
		if candidate_online != best_online:
			if candidate_online:
				best = candidate
			continue
		var candidate_created := int(candidate.get("created_at", 0))
		var best_created := int(best.get("created_at", 0))
		if (candidate_created > best_created
				or (candidate_created == best_created
					and str(candidate.get("ban_id", "")) > str(best.get("ban_id", "")))):
			best = candidate
	return best.duplicate(true)


func _player_card_signature(player: Dictionary, show_location: bool) -> String:
	var visible_data := player.duplicate(true)
	visible_data.erase("server_unix")
	for key in ["facing", "hidden", "transparency"]:
		visible_data.erase(key)
	for key in ["room_id", "previous_map_id", "x", "y"]:
		visible_data.erase(key)
	if not show_location:
		visible_data.erase("_display_location")
	return JSON.stringify(visible_data)


func _discard_cached_card(index: int, key: String) -> void:
	var cards := _list_cards[index]
	var card := cards.get(key) as Control
	if is_instance_valid(card):
		_forget_status_labels_in(card)
		if card.get_parent() != null:
			card.get_parent().remove_child(card)
		card.queue_free()
	cards.erase(key)
	_list_signatures[index].erase(key)


func _forget_status_labels_in(root: Node) -> void:
	var retained: Array[Dictionary] = []
	for item in _status_labels:
		var label := item.get("label") as Label
		if is_instance_valid(label) and not root.is_ancestor_of(label):
			retained.append(item)
	_status_labels = retained


func _remove_empty_state(index: int) -> void:
	for child in _lists[index].get_children():
		if child.has_meta("player_list_empty_state"):
			_lists[index].remove_child(child)
			child.queue_free()


func _update_empty_state(index: int) -> void:
	_remove_empty_state(index)
	var failure := ("处罚列表刷新失败" if index == 2 and _query_errors.has("bans") else "")
	if index < 2:
		failure = ("玩家列表刷新失败" if _query_errors.has("plist") else
			("管理员信息刷新失败" if _query_errors.has("roster") else ""))
	if _lists[index].get_child_count() > 0 and failure.is_empty():
		return
	var empty_text := ""
	if not failure.is_empty():
		empty_text = failure
	elif index == 2 and _punishments_loading:
		empty_text = "正在加载..."
	elif index < 2 and _player_list_unavailable:
		empty_text = "玩家列表当前不可用"
	elif index < 2 and _player_list_loading:
		empty_text = "正在加载..."
	else:
		empty_text = "暂无玩家" if index < 2 else "暂无生效中的禁言或封禁"
	var empty := CenterContainer.new()
	empty.set_meta("player_list_empty_state", true)
	empty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	empty.size_flags_vertical = Control.SIZE_EXPAND_FILL
	if index == 2 and failure.is_empty() and not _punishments_loading:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 0)
		preload("res://cogs/ui_text_baseline.gd").install(row)
		_add_local_piece(row, "暂无生效中的", int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_NORMAL))
		_add_fixed_piece(row, "禁言", _MUTED_COLOR)
		_add_local_piece(row, "或", int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_NORMAL))
		_add_fixed_piece(row, "封禁", _BANNED_COLOR)
		empty.add_child(row)
	else:
		var empty_label := Label.new()
		empty_label.text = empty_text
		empty_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_apply_text_style(empty_label, _ui_normal_color)
		empty.add_child(empty_label)
	_lists[index].add_child(empty)
	if not failure.is_empty():
		_lists[index].move_child(empty, 0)


func _sort_players(players: Array) -> void:
	var my_pid := _connection.get_my_pid() if is_instance_valid(_connection) else 0
	players.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_self := int(a.get("pid", 0)) == my_pid
		var b_self := int(b.get("pid", 0)) == my_pid
		if a_self != b_self:
			return a_self
		return str(a.get("display_name", "")).naturalnocasecmp_to(
			str(b.get("display_name", ""))) < 0)


func _make_player_card(player: Dictionary, show_location: bool) -> Control:
	var card := _make_card_shell(player)
	var row := card.get_meta("content") as BoxContainer
	row.add_child(_make_avatar(player))
	var middle := VBoxContainer.new()
	middle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	middle.alignment = BoxContainer.ALIGNMENT_CENTER
	# Compact the font's visible whitespace without changing the card padding.
	middle.add_theme_constant_override("separation", -2)
	row.add_child(middle)
	middle.add_child(_make_name_row(player))
	if show_location:
		var location := _make_location_label(player)
		if location != null:
			middle.add_child(location)
	if is_instance_valid(_connection) and _connection.is_admin_authenticated():
		var expires := int(player.get("muted_until", 0))
		var duration_mode := str(player.get("muted_duration_mode", "finite"))
		var status := _make_status_label(
			"mute" if duration_mode == "permanent" or _remaining_seconds(expires) > 0 else "normal",
			expires, true, duration_mode,
			bool(player.get("muted_network_scope", false)))
		row.add_child(status)
	return card


func _make_punishment_card(record: Dictionary) -> Control:
	var player := {
		"pid": int(record.get("online_pid", 0)),
		"display_name": str(record.get("last_name", "")),
		"room_id": int(record.get("room_id", -1)),
		"previous_map_id": int(record.get("previous_map_id", 0)),
		"x": int(record.get("x", -1)), "y": int(record.get("y", -1)),
		"system_name": str(record.get("system_name", "")),
		"system_stretch": int(record.get("system_stretch", 1)),
		"sprite_name": str(record.get("sprite_name", "")),
		"sprite_index": int(record.get("sprite_index", 0)),
		"facing": int(record.get("facing", 2)),
		"is_admin": bool(record.get("is_admin", false)),
		"subject_group_id": str(record.get("subject_group_id", "")),
	}
	var card := _make_card_shell(player)
	var row := card.get_meta("content") as BoxContainer
	row.add_child(_make_avatar(player))
	var middle := VBoxContainer.new()
	middle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	middle.alignment = BoxContainer.ALIGNMENT_CENTER
	middle.add_theme_constant_override("separation", -2)
	row.add_child(middle)
	middle.add_child(_make_name_row(player))
	if int(player.get("pid", 0)) > 0 and int(player.get("room_id", -1)) >= 0:
		var location := _make_location_label(player)
		if location != null:
			middle.add_child(location)
	var statuses := VBoxContainer.new()
	statuses.name = "PunishmentStatuses"
	statuses.alignment = BoxContainer.ALIGNMENT_CENTER
	statuses.size_flags_vertical = Control.SIZE_EXPAND_FILL
	statuses.add_theme_constant_override("separation", -2)
	for punishment_value in record.get("punishments", []):
		var punishment := punishment_value as Dictionary
		var status := _make_status_label(
			str(punishment.get("kind", "ban")),
			int(punishment.get("expires_at", 0)), false,
			str(punishment.get("duration_mode", "finite")),
			str(punishment.get("scope", "installation")) in [
				"installation_network", "network"])
		# Center the compact group; do not distribute spare card height per row.
		status.size_flags_vertical = Control.SIZE_FILL
		status.mouse_filter = Control.MOUSE_FILTER_STOP
		status.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		status.set_meta("player_punishment_record", punishment.duplicate(true))
		status.gui_input.connect(
			_on_punishment_status_input.bind(punishment.duplicate(true)))
		statuses.add_child(status)
	row.add_child(statuses)
	card.set_meta("punishment_group_size", statuses.get_child_count())
	return card


func _make_card_shell(player: Dictionary) -> PanelContainer:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(0, 54)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	card.add_child(margin)
	var row := BoxContainer.new()
	row.add_theme_constant_override("separation", 7)
	margin.add_child(row)
	card.set_meta("content", row)
	call_deferred("_apply_popup_skin", card,
		str(player.get("system_name", "")), int(player.get("system_stretch", 1)))
	return card


func _make_avatar(player: Dictionary) -> Control:
	var sprite_name := str(player.get("sprite_name", ""))
	var sprite_index := int(player.get("sprite_index", 0))
	var holder := CenterContainer.new()
	holder.custom_minimum_size = Vector2(42, 42)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var avatar := TextureRect.new()
	avatar.name = "PlayerProfile"
	avatar.custom_minimum_size = Vector2(40, 32)
	avatar.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	avatar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(avatar)
	if is_instance_valid(_connection) and not sprite_name.is_empty():
		avatar.texture = _connection.render_player_profile(sprite_name, sprite_index)
	return holder


func _make_name_row(player: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	var name_label := Label.new()
	name_label.name = "PlayerName"
	name_label.set_meta("player_current_data", player.duplicate(true))
	name_label.text = PlayerName.display(str(player.get("display_name", "")), _display_language)
	name_label.mouse_filter = Control.MOUSE_FILTER_STOP
	name_label.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	name_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	name_label.gui_input.connect(_on_current_player_name_input.bind(name_label))
	var system_name := str(player.get("system_name", ""))
	var colors := _connection.get_menu_theme_colors(system_name) \
		if is_instance_valid(_connection) else {}
	_apply_text_style(name_label, colors.get("normal", Color.WHITE))
	if is_instance_valid(_theme_text_runtime):
		_theme_text_runtime.style_control(
			name_label, _theme_source(), system_name,
			int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_NORMAL))
	row.add_child(name_label)
	if bool(player.get("is_admin", false)):
		if is_instance_valid(_theme_text_runtime):
			var badge := _theme_text_runtime.make_text_glyph_icon(
				_ADMIN_ICON,
				_theme_source(),
				system_name,
				int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_NORMAL),
				12,
				16) as Control
			badge.name = "PlayerAdminBadge"
			badge.set_meta("player_name_label", name_label)
			badge.mouse_filter = Control.MOUSE_FILTER_STOP
			badge.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			badge.gui_input.connect(_on_current_player_name_input.bind(name_label))
			WebpageThemeTooltipRuntime.set_control_tooltip(badge, "管理员")
			row.add_child(badge)
	return row


func _on_current_player_name_input(event: InputEvent, label: Label) -> void:
	_on_player_name_input(event, label.get_meta("player_current_data", {}),
		str(label.get_meta("player_list_key", "")))


func _on_player_name_input(event: InputEvent, player: Dictionary, list_key: String = "") -> void:
	var mouse := event as InputEventMouseButton
	if (mouse == null
			or mouse.button_index != MOUSE_BUTTON_RIGHT
			or not is_instance_valid(_player_context_menu)):
		return
	set_input_as_handled()
	if _player_context_menu.handle_right_click(mouse):
		_open_player_context(player, mouse.global_position, list_key)


func _player_menu_meta(player: Dictionary) -> Dictionary:
	var player_meta := player.duplicate(true)
	var pid := int(player_meta.get("pid", 0))
	player_meta["sender_id"] = pid
	if (str(player_meta.get("subject_group_id", "")).is_empty()
			and is_instance_valid(_connection) and pid > 0):
		player_meta["subject_group_id"] = (
			_connection.get_admin_subject_group_for_pid(pid))
	return player_meta


func _open_player_context(player: Dictionary, position: Vector2, list_key: String) -> void:
	var resolver := Callable()
	if not list_key.is_empty():
		resolver = _resolve_menu_player.bind(list_key, _current_tab, _connection)
	_player_context_menu.open_player_menu(_player_menu_meta(player), position, resolver)


func _resolve_menu_player(key: String, tab: int, connection: EasyMultiplayer) -> Dictionary:
	if not visible or tab != _current_tab or connection != _connection:
		return {}
	var card := _list_cards[tab].get(key) as Control
	if not is_instance_valid(card):
		return {}
	var label := card.find_child("PlayerName", true, false)
	return _player_menu_meta(label.get_meta("player_current_data", {})) if label != null else {}


func _open_right_click_at(position: Vector2) -> void:
	if not visible or not _tab_scrolls[_current_tab].get_global_rect().has_point(position):
		return
	# Re-hit the current controls on release: the card under the pointer may
	# have been replaced between press and release by a normal list refresh.
	for card in _lists[_current_tab].get_children():
		for node in card.find_children("*", "Control", true, false):
			var control := node as Control
			if not control.is_visible_in_tree() or not control.get_global_rect().has_point(position):
				continue
			if control.has_meta("player_punishment_record"):
				_open_status_menu(control.get_meta("player_punishment_record"), position)
				return
			var label := control.get_meta("player_name_label", control) as Control
			if is_instance_valid(label) and label.has_meta("player_current_data"):
				_open_player_context(label.get_meta("player_current_data"), position,
					str(label.get_meta("player_list_key", "")))
				return


func _on_player_mention_requested(player_meta: Dictionary) -> void:
	if is_instance_valid(_chat_overlay) and _chat_overlay.has_method("mention_player"):
		if bool(_chat_overlay.call("mention_player", player_meta)):
			dismiss()


func _resolve_card_location(player: Dictionary) -> Dictionary:
	if not is_instance_valid(_location_runtime) or not _location_runtime.has_method("resolve_location"):
		return {}
	var resolved: Dictionary = _location_runtime.call(
		"resolve_location", int(player.get("room_id", 0)),
		int(player.get("previous_map_id", 0)), int(player.get("x", -1)),
		int(player.get("y", -1)))
	# Keep only what the card renders; resolver diagnostics/raw coordinates do not
	# change its appearance. Link targets remain part of the signature.
	if bool(resolved.get("hidden", false)):
		return {"hidden": true}
	return {"localized_entries": _location_entries(resolved, "localized"),
		"english_entries": _location_entries(resolved, "english")}


func _make_location_label(player: Dictionary) -> Control:
	var location: Dictionary = player.get("_display_location", {})
	if not player.has("_display_location"):
		location = _resolve_card_location(player)
	if bool(location.get("hidden", false)):
		return null
	var localized := _location_entries(location, "localized")
	var english := _location_entries(location, "english")
	if localized.is_empty() and english.is_empty():
		return null
	var label := RichTextLabel.new()
	label.name = "PlayerLocation"
	# Latin descenders already leave little space between wrapped lines. Keep
	# this tighter than default without overlapping glyphs or link underlines.
	label.add_theme_constant_override("line_separation", -1)
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_override("normal_font", _GAME_UI_FONT)
	var colors := _connection.get_menu_theme_colors(str(player.get("system_name", ""))) \
		if is_instance_valid(_connection) else {}
	label.add_theme_color_override("default_color", colors.get("strong", Color.GOLD))
	var system_name := str(player.get("system_name", ""))
	if is_instance_valid(_theme_text_runtime):
		_theme_text_runtime.style_control(
			label, _theme_source(), system_name, _WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG)
	_append_location_entries(label, localized if not localized.is_empty() else english, system_name)
	if not localized.is_empty() and not english.is_empty():
		label.add_text(" (")
		_append_location_entries(label, english, system_name)
		label.add_text(")")
	label.meta_clicked.connect(_on_location_clicked)
	var bounds := LocationTextLayout.new()
	bounds.name = "PlayerLocationBounds"
	bounds.label = label
	bounds.add_child(label)
	return bounds


func _location_entries(location: Dictionary, prefix: String) -> Array:
	var available_key := prefix + "_available"
	var entries_key := prefix + "_entries"
	if location.has(available_key) and not bool(location.get(available_key, false)):
		return []
	return (location.get(entries_key, []) as Array).duplicate(true)


func _append_location_entries(
		label: RichTextLabel, entries: Array, _system_name: String) -> void:
	for index in entries.size():
		if index > 0:
			label.add_text(" | ")
		var entry: Dictionary = entries[index]
		var title := str(entry.get("title", "")).strip_edges()
		var url := str(entry.get("url", "")).strip_edges()
		var allowed := (
			is_instance_valid(_location_runtime)
			and _location_runtime.has_method("is_url_allowed")
			and bool(_location_runtime.call("is_url_allowed", url)))
		if allowed:
			label.push_meta(url, RichTextLabel.META_UNDERLINE_ALWAYS, url)
			label.add_text(title)
			label.pop()
		else:
			label.add_text(title)

func _on_location_clicked(meta: Variant) -> void:
	var url := str(meta)
	if (is_instance_valid(_location_runtime) and _location_runtime.has_method("is_url_allowed")
			and bool(_location_runtime.call("is_url_allowed", url))):
		OS.shell_open(url)


func _make_status_label(
		kind: String, expires_at: int, normal_when_expired: bool = false,
		duration_mode: String = "finite", network_scope: bool = false) -> Control:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 3)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	if network_scope:
		var icon := TextureRect.new()
		icon.texture = _IP_ICON
		icon.custom_minimum_size = Vector2(14, 14)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.modulate = _MUTED_COLOR if kind == "mute" else _BANNED_COLOR
		row.add_child(icon)
	var label := Label.new()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_text_style(label, _NORMAL_COLOR)
	row.add_child(label)
	_status_labels.append({
		"label": label,
		"kind": kind,
		"expires_at": expires_at,
		"duration_mode": duration_mode,
		"normal_when_expired": normal_when_expired,
		"last_display_key": "",
	})
	_update_status_label(_status_labels.back())
	return row


func _update_countdowns() -> void:
	for item in _status_labels:
		_update_status_label(item)


func _update_status_label(item: Dictionary) -> void:
	var label := item.get("label") as Label
	if not is_instance_valid(label):
		return
	var kind := str(item.get("kind", "normal"))
	var permanent := str(item.get("duration_mode", "finite")) == "permanent"
	var remaining := _remaining_seconds(int(item.get("expires_at", 0)))
	var display_kind := (
		"normal" if (bool(item.get("normal_when_expired", false))
			and not permanent and remaining <= 0)
		else kind)
	var display_key := "%s:%s:%d" % [display_kind, "p" if permanent else "f", remaining]
	if str(item.get("last_display_key", "")) == display_key:
		return
	item["last_display_key"] = display_key
	match display_kind:
		"mute":
			label.text = "禁言中 %s" % ("永久" if permanent else _format_remaining(remaining))
			label.add_theme_color_override("font_color", _MUTED_COLOR)
		"ban":
			label.text = "封禁中 %s" % ("永久" if permanent else _format_remaining(remaining))
			label.add_theme_color_override("font_color", _BANNED_COLOR)
		_:
			label.text = "正常"
			label.add_theme_color_override("font_color", _NORMAL_COLOR)


func _format_remaining(seconds_total: int) -> String:
	var seconds := maxi(0, seconds_total)
	var days := int(seconds / 86400)
	var hours := int((seconds % 86400) / 3600)
	var minutes := int((seconds % 3600) / 60)
	var secs := seconds % 60
	if days > 0:
		return "%d天 %02d:%02d:%02d" % [days, hours, minutes, secs]
	return "%02d:%02d:%02d" % [hours, minutes, secs]


func _remaining_seconds(expires_at: int) -> int:
	if expires_at <= 0:
		return 0
	var remaining_msec := (expires_at * 1000) - _estimated_server_unix_msec()
	return maxi(0, ceili(float(remaining_msec) / 1000.0))


func _estimated_server_unix_msec() -> int:
	if (is_instance_valid(_connection)
			and _connection.has_method("get_estimated_server_unix_msec")):
		return int(_connection.call("get_estimated_server_unix_msec"))
	return roundi(Time.get_unix_time_from_system() * 1000.0)


func _apply_text_style(control: Control, color: Color, explicit_role: int = -1) -> void:
	control.add_theme_font_override("font", _GAME_UI_FONT)
	control.add_theme_color_override("font_color", color)
	control.add_theme_color_override("font_hover_color", color)
	control.add_theme_color_override("font_pressed_color", color)
	control.add_theme_color_override("font_focus_color", color)
	control.add_theme_color_override("font_hover_pressed_color", color)
	control.add_theme_color_override("font_disabled_color", _ui_muted_color)
	control.add_theme_color_override("font_placeholder_color", _ui_muted_color)
	control.add_theme_color_override("font_uneditable_color", _ui_muted_color)
	control.add_theme_color_override("font_shadow_color", _SHADOW_COLOR)
	control.add_theme_constant_override("shadow_offset_x", 1)
	control.add_theme_constant_override("shadow_offset_y", 1)
	if is_instance_valid(_theme_text_runtime):
		var role: int = (
			explicit_role if explicit_role >= 0
			else int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_NORMAL))
		var is_theme_role := explicit_role >= 0
		if explicit_role < 0:
			is_theme_role = true
			if color.is_equal_approx(_ui_strong_color):
				role = int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG)
			elif color.is_equal_approx(_ui_muted_color):
				role = int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_MUTED)
			elif not color.is_equal_approx(_ui_normal_color):
				is_theme_role = false
		if (_theme_text_runtime.style_control(control, _theme_source(), "", role)
				and not is_theme_role):
			control.add_theme_color_override("font_color", color)


func _register_local_text_control(control: Control) -> void:
	if not _local_text_controls.has(control):
		_local_text_controls.append(control)
	_apply_text_style(control, _ui_normal_color)


func _apply_popup_skin(panel, system_name: String, stretch_mode: int) -> void:
	if not is_instance_valid(panel) or not is_instance_valid(_connection):
		return
	SystemUISkin.install(panel, _theme_source(), system_name, stretch_mode)
	if panel == self:
		_queue_tab_layout()


func _on_punishment_status_input(event: InputEvent, record: Dictionary) -> void:
	var mouse := event as InputEventMouseButton
	if mouse == null or mouse.button_index != MOUSE_BUTTON_RIGHT:
		return
	set_input_as_handled()
	if _player_context_menu.handle_right_click(mouse):
		_open_status_menu(record, mouse.global_position)


func _dismiss_status_menu() -> void:
	_cancel_status_request()
	if is_instance_valid(_status_menu):
		_status_menu.hide()


func _cancel_status_request() -> void:
	_status_requested = false
	_status_open_serial += 1
	_status_reflow_serial += 1


func _open_status_menu(record: Dictionary, point: Vector2) -> void:
	_status_menu_record = record
	_fill_status_menu_actions()
	var position := Vector2i(point)
	_capture_status_anchor(position)
	_status_requested = true
	_status_open_serial += 1
	var serial := _status_open_serial
	_status_menu.min_size = Vector2i.ZERO
	_apply_popup_skin(_status_menu, "", -1)
	_show_status_menu_after_layout(serial)


func _on_ui_scale_changed(_ui_scale: float) -> void:
	_layout_scrollbars()
	_refresh_tab_buttons()
	if visible:
		_queue_recenter_after_resize()


func _build_status_menu() -> void:
	_status_menu = PopupPanel.new()
	_status_menu.transparent_bg = true
	_status_menu.wrap_controls = true
	_status_menu.popup_hide.connect(_cancel_status_request)
	add_child(_status_menu)
	_status_menu_content = MarginContainer.new()
	_status_menu_content.add_theme_constant_override("margin_left", 8)
	_status_menu_content.add_theme_constant_override("margin_top", 8)
	_status_menu_content.add_theme_constant_override("margin_right", 8)
	_status_menu_content.add_theme_constant_override("margin_bottom", 8)
	_status_menu.add_child(_status_menu_content)
	var buttons := VBoxContainer.new()
	buttons.add_theme_constant_override("separation", 0)
	_status_menu_content.add_child(buttons)
	_status_change_button = _new_status_action(buttons, "change")
	_status_change_row = (
		_status_change_button.get_meta("texture_row") as HBoxContainer)
	_status_revoke_button = _new_status_action(buttons, "revoke")
	_status_revoke_row = (
		_status_revoke_button.get_meta("texture_row") as HBoxContainer)


func _new_status_action(parent: VBoxContainer, action: String) -> Button:
	var button := Button.new()
	UiScale.mark_geometry_physical(button)
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.flat = true
	button.focus_mode = Control.FOCUS_NONE
	for style_name in ["normal", "hover", "pressed", "focus", "disabled"]:
		button.add_theme_stylebox_override(style_name, StyleBoxEmpty.new())
	button.pressed.connect(_on_status_menu_action.bind(action))
	parent.add_child(button)
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 1
	row.offset_right = -1
	row.add_theme_constant_override("separation", 0)
	button.add_child(row)
	button.set_meta("texture_row", row)
	return button


func _capture_status_anchor(requested_position: Vector2i) -> void:
	_status_anchor_ratio = PopupGeometryScript.anchor_ratio(
		_status_menu, Vector2i(PopupGeometryScript.viewport_point(
			_status_menu, get_viewport(), Vector2(requested_position))))
	_status_anchor_control = null
	var hovered := get_viewport().gui_get_hovered_control()
	if not is_instance_valid(hovered):
		return
	_status_anchor_control = weakref(hovered)
	_status_anchor_local = (
		hovered.get_global_transform_with_canvas().affine_inverse()
		* Vector2(requested_position))


func _resolved_status_anchor() -> Vector2i:
	if _status_anchor_control != null:
		var control := _status_anchor_control.get_ref() as Control
		if is_instance_valid(control) and control.is_visible_in_tree():
			return Vector2i(
				PopupGeometryScript.control_point(_status_menu, control, _status_anchor_local))
	return PopupGeometryScript.anchor_from_ratio(
		_status_menu, _status_anchor_ratio)


func _show_status_menu_after_layout(serial: int) -> void:
	await get_tree().process_frame
	if serial != _status_open_serial:
		return
	_fit_status_button(_status_change_button, _status_change_row)
	_fit_status_button(_status_revoke_button, _status_revoke_row)
	await get_tree().process_frame
	if serial != _status_open_serial:
		return
	var popup_rect := _status_menu_rect()
	if _status_menu.visible:
		PopupGeometryScript.apply_rect(_status_menu, popup_rect)
	else:
		_status_menu.popup(popup_rect)
		await get_tree().process_frame
		if serial == _status_open_serial and _status_menu.visible:
			PopupGeometryScript.apply_rect(
				_status_menu,
				PopupGeometryScript.anchored_rect(
					_status_menu,
					_status_menu.size,
					_resolved_status_anchor(),
					UiScale.physical_int(4.0)))


func _queue_status_menu_reflow() -> void:
	_status_reflow_serial += 1
	if _status_reflow_pending or not is_instance_valid(_status_menu):
		return
	_status_reflow_pending = true
	_reflow_status_menu_after_layout()


func _reflow_status_menu_after_layout() -> void:
	while true:
		var serial := _status_reflow_serial
		await get_tree().process_frame
		if serial != _status_reflow_serial:
			continue
		if _status_menu.visible:
			_fit_status_button(_status_change_button, _status_change_row)
			_fit_status_button(_status_revoke_button, _status_revoke_row)
		await get_tree().process_frame
		if serial != _status_reflow_serial:
			continue
		break
	_status_reflow_pending = false
	if _status_menu.visible:
		PopupGeometryScript.apply_rect(_status_menu, _status_menu_rect())


func _fill_status_menu_actions() -> void:
	var kind := str(_status_menu_record.get("kind", "ban"))
	_clear_text_row(_status_change_row)
	_add_local_piece(
		_status_change_row, "更改", int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG))
	_add_fixed_piece(
		_status_change_row, "禁言" if kind == "mute" else "封禁",
		_MUTED_COLOR if kind == "mute" else _BANNED_COLOR)
	_add_local_piece(
		_status_change_row, "时长", int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG))
	_fit_status_button(_status_change_button, _status_change_row)
	_clear_text_row(_status_revoke_row)
	_add_local_piece(
		_status_revoke_row, "立即解除", int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG))
	_add_fixed_piece(
		_status_revoke_row, "禁言" if kind == "mute" else "封禁",
		_MUTED_COLOR if kind == "mute" else _BANNED_COLOR)
	_fit_status_button(_status_revoke_button, _status_revoke_row)


func _clear_text_row(row: HBoxContainer) -> void:
	for child in row.get_children():
		row.remove_child(child)
		child.queue_free()


func _add_local_piece(row: HBoxContainer, text: String, role: int) -> void:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var color := _ui_strong_color if role == int(
		_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG) else _ui_normal_color
	_apply_text_style(label, color, role)
	row.add_child(label)


func _add_fixed_piece(row: HBoxContainer, text: String, color: Color) -> void:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_apply_text_style(label, color)
	label.add_theme_color_override("font_color", color)
	row.add_child(label)


func _fit_status_button(button: Button, row: HBoxContainer) -> void:
	preload("res://cogs/ui_text_baseline.gd").install(row)
	var minimum := row.get_combined_minimum_size()
	button.custom_minimum_size = Vector2(
		ceilf(minimum.x) + UiScale.physical_value(2.0), ceilf(minimum.y))


func _on_status_menu_action(action: String) -> void:
	_status_menu.hide()
	if action == "revoke":
		if (is_instance_valid(_connection)
				and (str(_status_menu_record.get("duration_mode", "finite")) == "permanent"
					or _remaining_seconds(
						int(_status_menu_record.get("expires_at", 0))) > 0)):
			_connection.admin_revoke_punishment(str(_status_menu_record.get("ban_id", "")))
		return
	if is_instance_valid(_player_context_menu):
		_player_context_menu.open_punishment_editor(_status_menu_record)


func handle_touch_back() -> bool:
	if _player_context_menu.handle_touch_back():
		return true
	if _status_menu.visible:
		_status_menu.hide()
		return true
	dismiss()
	return true
