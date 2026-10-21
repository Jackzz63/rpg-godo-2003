extends Node

const Metrics := preload("res://platform/android/launcher_presentation.gd")
const TouchScroll := preload("res://platform/android/touch_scroll.gd")
var chat: Control
var fields: Node
var native_chat: Node
var _controls: Dictionary = {}
var _refresh_queued := false
var _scroll_gestures: Array[Node] = []


func _ready() -> void:
	get_tree().node_added.connect(_added)
	get_tree().node_removed.connect(_removed)
	get_tree().root.size_changed.connect(refresh)
	UiScale.scale_changed.connect(func(_scale: float): refresh())
	chat.get("chat_selection").set("touch_enabled", true)
	chat.get("chat_selection").touch_context_requested.connect(chat.open_touch_history_menu)
	chat.get("chat_selection").touch_context_requested.connect(_history_hold)
	chat.get("chat_selection").touch_context_dragged.connect(chat.get("_player_context_menu").dismiss_context_menu)
	_visit(chat)
	var close := Button.new()
	close.name = "TouchCloseChat"
	close.text = "收起"
	close.pressed.connect(func(): chat.handle_touch_back())
	chat.get("chat_input_row").add_child(close)
	chat.call("_apply_game_ui_text_rendering", close)
	refresh()


func _belongs(node: Node) -> bool:
	var current := node
	while current != null:
		if current.name in [&"__SystemUISkin", &"CurrentLocationModules"]:
			return false
		if current == chat:
			return true
		current = current.get_parent()
	return false


func _visit(node: Node) -> void:
	_added(node)
	for child in node.get_children():
		_visit(child)


func _added(node: Node) -> void:
	if not _belongs(node):
		return
	if node is SpinBox:
		# SpinBox's internal LineEdit is absent from ordinary get_children().
		node.set_meta("android_native_input", true)
		# A physical hit-area floor only; glyphs retain the shared UI scale.
		node.set_meta(UiScale.META_SPIN_BUTTON_MINIMUM,
			func(): return Vector2(Metrics.dp(20), Metrics.dp(20)))
		_added(node.get_line_edit())
	if node is OptionButton and not node.get_meta(&"compact_option_style", false):
		preload("res://cogs/option_popup_layout.gd").install(node).touch_height = Metrics.dp.bind(48)
	if node is Window:
		if not node.visibility_changed.is_connected(_window_changed):
			node.visibility_changed.connect(_window_changed)
	if node is ScrollContainer and not node.has_meta("p3_scroll_bound"):
		var window := node.get_window()
		var player_list: bool = window == chat.get("_player_list_popup")
		var form: bool = window == chat.get("_nametag_style_popup") or window.name == &"ChatModerationPopup"
		if player_list or form:
			node.set_meta("p3_scroll_bound", true)
			var gesture := TouchScroll.new()
			gesture.scroll = node
			gesture.slop = Metrics.dp(8)
			if player_list: gesture.held = _list_hold
			if form:
				gesture.completed_tap = _form_tap
				gesture.control_tooltip = _form_tooltip
			_scroll_gestures.append(gesture)
			node.add_child.call_deferred(gesture)
	if node is Control:
		_controls[node.get_instance_id()] = weakref(node)
		if not node.has_meta("p3_touch_bound"):
			node.set_meta("p3_touch_bound", true)
			if node is LineEdit and node.get_parent() is SpinBox:
				node.visibility_changed.connect(_register_number.bind(node))
				_register_number(node)
			# Existing player/status labels own live data callbacks. Touch adds only a gesture.
			if node.name in [&"PlayerName", &"PlayerAdminBadge"] or node.get_parent().name == &"PunishmentStatuses":
				node.set_meta("android_context_hold", true)


func _removed(node: Node) -> void:
	_controls.erase(node.get_instance_id())
	_scroll_gestures.erase(node)


func _list_hold(gesture: Node) -> void:
	var players: Node = chat.get("_player_list_popup")
	var status: Window = players.get("_status_menu")
	gesture.hold_window(status if status.visible else players.get("_player_context_menu").get("_context_popup"))


func _history_hold(_point: Vector2) -> void:
	chat.get("chat_selection").hold_window(chat.get("_player_context_menu").get("_context_popup"))


func _form_tap(target: Control, point: Vector2) -> void:
	if not is_instance_valid(target):
		return
	# The hit-test does not enumerate SpinBox's internal LineEdit. Only its
	# text rectangle requests native editing; the arrows keep their own action.
	var field: LineEdit = target.get_line_edit() if target is SpinBox else target as LineEdit
	if field != null and field.get_parent() is SpinBox and field.get_global_rect().has_point(point):
		fields.request(field)


func _form_tooltip(target: Control, point: Vector2, finger: int) -> bool:
	var text := str(target.get_meta(&"webpage_tooltip_text", ""))
	if text.is_empty():
		return false
	chat.get("_theme_tooltip_runtime").show_touch_tooltip(target, text, point, finger)
	return true


func _register_number(field: LineEdit) -> void:
	if field.is_visible_in_tree():
		fields.register_field(field, 6, "时长", func():
			return is_instance_valid(field) and field.is_visible_in_tree() and field.editable \
				and not native_chat.is_modal_open())
	else:
		fields.cancel_field(field)


func _window_changed() -> void:
	# A parent Window visibility change is not guaranteed to emit on every child Control.
	for reference: WeakRef in _controls.values():
		var control: Control = reference.get_ref()
		if is_instance_valid(control) and control is LineEdit and control.get_parent() is SpinBox:
			_register_number(control)
	get_parent().call("_sync_blocking")


func refresh() -> void:
	if _refresh_queued:
		return
	_refresh_queued = true
	_refresh.call_deferred()


func _refresh() -> void:
	_refresh_queued = false
	# Pixel geometry/font/icon scaling belongs to UiScale. Android only adds
	# gesture slop and a minimum hit area for the two SpinBox buttons.
	chat.get("chat_selection").set("touch_slop", float(Metrics.dp(8)))
	for reference: WeakRef in _controls.values():
		var control: Control = reference.get_ref()
		if is_instance_valid(control) and control is SpinBox:
			UiScale.apply_control(control)
	for gesture in _scroll_gestures:
		gesture.slop = Metrics.dp(8)


func _notification(what: int) -> void:
	if is_node_ready() and what == NOTIFICATION_APPLICATION_RESUMED:
		refresh()


func _exit_tree() -> void:
	get_tree().node_added.disconnect(_added)
	get_tree().node_removed.disconnect(_removed)
