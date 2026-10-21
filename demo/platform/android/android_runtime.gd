extends CanvasLayer

const StorageAccess := preload("res://platform/android/storage_access.gd")
const DirectoryRead := preload("res://platform/android/directory_read.gd")
const TouchControls := preload("res://platform/android/touch_controls.gd")
const NativeTextSession := preload("res://platform/android/native_text_session.gd")
const DirectoryPicker := preload("res://platform/android/directory_picker.gd")
const Presentation := preload("res://platform/android/launcher_presentation.gd")
const NativeChat := preload("res://platform/android/native_chat_session.gd")
const ChatPresentation := preload("res://platform/android/chat_presentation.gd")
const DisplaySettings := preload("res://platform/android/display_settings.gd")
const DisplayPanel := preload("res://platform/android/display_settings_panel.gd")
const ConsoleAdapter := preload("res://platform/android/console_adapter.gd")
const UiTheme := preload("res://platform/android/ui_theme.gd")
const ThemedDialog := preload("res://platform/android/themed_dialog.gd")

var launcher: Control
var engine: Node
var storage: Control
var touch: Control
var native_input: Node
var native_chat: Node
var _escape_owned := false
var chat_presentation: Node
var display_settings: Node
var display_panel: Control
var console: Node
var _layout_editing := false
# Tests inject the native boundary while exercising the real launcher callers.
var input_plugin: Object
var _menu: Control
var _menu_label: Label
var _return_button: Button
var _return_confirm: ThemedDialog
var _paused := false
var _was_running := false
var _menu_content: VBoxContainer
var _menu_frame: VBoxContainer
var _menu_shade: ColorRect
var _menu_scroll: ScrollContainer
var _menu_pointer: Node
var _game_buttons: Array[Button] = []
var _visibility_button: Button
var _menu_key_serial := 0
var _directory_jobs: Array[RefCounted] = []


func _enter_tree() -> void:
	UiScale.set_interface_multiplier(DisplaySettings.LAUNCHER_MULTIPLIER)
	preload("res://cogs/popup_title_spacing.gd").common_padding_ratio = 0.8


func _exit_tree() -> void:
	_finish_directory_reads()
	_cancel_menu_key()
	if is_instance_valid(touch) and touch.is_editor_open(): touch.on_game_stopped()
	UiScale.set_interface_multiplier(1.0)
	preload("res://cogs/popup_title_spacing.gd").common_padding_ratio = 1.0


func _ready() -> void:
	layer = 10
	preload("res://cogs/button_pointer_feedback.gd").install_tree(launcher)
	get_tree().quit_on_go_back = false
	var surface := Control.new()
	surface.add_theme_font_override("font", preload("res://resources/launcher_font.tres"))
	surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	surface.set_meta(UiScale.META_ROOT, true)
	add_child(surface)
	surface.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	UiScale.mark_geometry_physical(surface)
	storage = StorageAccess.new()
	storage.directory_reader = _submit_directory_read
	storage.game_probe = engine.inspect_game_directory
	storage.browse_completed.connect(_browse_completed)
	storage.modal_changed.connect(_sync_blocking)
	touch = TouchControls.new()
	touch.engine = engine
	touch.chat_requested.connect(func(): launcher.get("chat_ctrl").reveal_chat())
	touch.console_requested.connect(_open_console)
	touch.editor_changed.connect(_layout_editor_changed)
	touch.editor_fields_invalidated.connect(_cancel_layout_fields)
	touch.preview_orientation_requested.connect(_preview_layout_orientation)
	surface.add_child(touch)
	_menu_shade = ColorRect.new()
	_menu_shade.color = Color(0, 0, 0, 0.58)
	_menu_shade.mouse_filter = Control.MOUSE_FILTER_STOP
	_menu_shade.mouse_force_pass_scroll_events = false
	surface.add_child(_menu_shade)
	_menu_shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	UiScale.mark_geometry_physical(_menu_shade)
	_menu_shade.hide()
	_menu = PanelContainer.new()
	surface.add_child(_menu)
	Presentation.take_ownership(_menu)
	_menu.theme = UiTheme.theme(true)
	var margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, UiTheme.px(4))
	_menu.add_child(margin)
	_menu_frame = VBoxContainer.new()
	_menu_frame.add_theme_constant_override("separation", UiTheme.px(4))
	margin.add_child(_menu_frame)
	_menu_label = Label.new()
	_menu_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_menu_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_menu_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_menu_label.set_meta(&"android_font_design", 24.0)
	_menu_frame.add_child(_menu_label)
	var divider := HSeparator.new()
	divider.name = "HeaderDivider"
	_menu_frame.add_child(divider)
	_menu_scroll = ScrollContainer.new()
	_menu_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_menu_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_menu_frame.add_child(_menu_scroll)
	_menu_content = VBoxContainer.new()
	_menu_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_menu_scroll.add_child(_menu_content)
	_menu_content.minimum_size_changed.connect(_layout_android_surfaces, CONNECT_DEFERRED)
	var menu_scroll := preload("res://platform/android/touch_scroll.gd").new()
	menu_scroll.scroll = _menu_scroll
	menu_scroll.slop = Presentation.dp(12)
	_menu_scroll.add_child(menu_scroll)
	_game_buttons.append(_menu_button("控制台 (`)", _open_console))
	_game_buttons.append(_menu_button("游戏引擎设置 (F1)", _send_menu_key.bind(85)))
	_menu_button("UI与屏幕边距设置", _open_display_settings)
	_game_buttons.append(_menu_button("编辑虚拟按钮布局", _open_layout_editor))
	_game_buttons.append(_menu_button("开启/关闭FPS显示 (F2)", _send_menu_key.bind(86)))
	_visibility_button = _menu_button("隐藏虚拟按钮", _toggle_controls)
	_game_buttons.append(_visibility_button)
	_return_button = _menu_button("返回初始界面", _request_return)
	_return_confirm = ThemedDialog.new()
	_return_confirm.in_game = true
	_return_confirm.title = "返回初始界面"
	_return_confirm.dialog_text = "是否确认返回启动器初始界面？\n这将结束游戏并丢失未保存的进度。"
	surface.add_child(_return_confirm)
	_return_confirm.confirmed.connect(_confirm_game_return)
	_return_confirm.canceled.connect(_dismiss_return_confirm)
	_menu_pointer = preload("res://platform/android/menu_pointer_guard.gd").new()
	_menu_pointer.drawer = _menu
	_menu_pointer.scroll_gesture = menu_scroll
	_menu_pointer.dismiss = _close_menu
	_menu_pointer.slop = Presentation.dp(12)
	# Later siblings get raw input before the scrolling helper and touch keys.
	surface.add_child(_menu_pointer)
	_menu.visibility_changed.connect(func():
		_menu_shade.visible = _menu.visible
		_menu_pointer.cancel())
	_menu.hide()
	surface.add_child(storage)
	var launcher_actions := launcher.get_node("WindowActions")
	WebpageThemeTooltipRuntime.set_control_theme_override(storage, launcher_actions,
		launcher_actions.get("_text_runtime"), launcher_actions.SYSTEM_NAME, true, 0)
	touch.hide()
	native_input = NativeTextSession.new()
	native_input.plugin = input_plugin
	add_child(native_input)
	native_input.modal_changed.connect(_sync_blocking)
	native_input.input_failed.connect(_show_input_error)
	display_settings = DisplaySettings.new()
	display_settings.plugin = native_input.plugin
	add_child(display_settings)
	display_settings.geometry_changed.connect(_display_geometry_changed)
	display_panel = DisplayPanel.new()
	display_panel.settings = display_settings
	surface.add_child(display_panel)
	display_panel.closed.connect(_display_settings_closed)
	UiScale.scale_changed.connect(_layout_android_surfaces)
	launcher.get_node("VBoxContainer").resized.connect(_fit_launcher)
	UiScale.mark_geometry_physical(launcher.get("chat_ctrl"))
	_register_input_fields()
	for field: Control in touch.input_fields():
		native_input.register_field(field, NativeTextSession.Mode.TEXT,
			"按键标签" if field == touch.get("_label_override") else "搜索按键", touch.field_available.bind(field))
	native_chat = NativeChat.new()
	native_chat.plugin = native_input.plugin
	native_chat.chat = launcher.get("chat_ctrl")
	native_chat.can_open = _chat_input_available
	native_chat.chat.touch_input_available = _chat_input_available
	add_child(native_chat)
	native_chat.modal_changed.connect(_sync_blocking)
	native_chat.input_failed.connect(_show_input_error)
	chat_presentation = ChatPresentation.new()
	chat_presentation.chat = launcher.get("chat_ctrl")
	chat_presentation.fields = native_input
	chat_presentation.native_chat = native_chat
	add_child(chat_presentation)
	console = ConsoleAdapter.new()
	console.fields = native_input
	console.engine = engine
	console.can_open = _can_open_console
	console.before_open = _prepare_console
	add_child(console)
	console.modal_changed.connect(_sync_blocking)
	launcher.get("advanced_options_popup").set("directory_picker_factory", _create_directory_picker)
	var advanced: Window = launcher.get("advanced_options_popup")
	var options: OptionButton = advanced.get("source_options")
	UiTheme.configure_option(options)
	Presentation.install_error(advanced.get("error_dialog"))
	if OS.get_name() == "Android" and native_input.get("plugin") == null:
		storage.call("show_message", "原生输入插件未加载，请重新安装完整 APK。")
	_sync_blocking()


func _register_input_fields() -> void:
	for item: Array in [["game_path", NativeTextSession.Mode.TEXT, "游戏目录"],
			["mp_name", NativeTextSession.Mode.NICKNAME, "昵称"],
			["mp_url", NativeTextSession.Mode.URL, "服务器地址"]]:
		native_input.register_field(launcher.get(item[0]), item[1], item[2], _launcher_field_available)
	var admin: Window = launcher.get("admin_credential_popup")
	var host: Window = launcher.get("host_advanced_popup")
	native_input.register_field(launcher.get("admin_credential"), NativeTextSession.Mode.PASSWORD,
		"管理员密码", admin.is_open_or_opening, _password_visibility_changed)
	native_input.register_field(host.get("parameters"), NativeTextSession.Mode.MULTILINE,
		"Host 参数", host.is_open_or_opening)
	admin.editing_finished.connect(native_input.cancel_field.bind(launcher.get("admin_credential")))
	host.editing_finished.connect(native_input.cancel_field.bind(host.get("parameters")))


func _launcher_field_available() -> bool:
	if engine.is_running() or not launcher.get("godot_menu_layer").visible or _menu.visible \
			or storage.call("is_modal_open"):
		return false
	for field: String in ["host_advanced_popup", "advanced_options_popup", "admin_credential_popup"]:
		if launcher.get(field).call("is_open_or_opening"):
			return false
	return true


func _password_visibility_changed(value: bool) -> void:
	launcher.get("admin_credential_visibility").set_pressed_no_signal(value)
	launcher.call("_on_admin_credential_visibility_toggled", value)


func _show_input_error() -> void:
	var message := "无法打开输入框。请重新点击输入框重试。"
	# An exclusive popup owns input; a root CanvasLayer message would be behind
	# that modal and could not receive its dismiss button's touch.
	for field: String in ["admin_credential_popup", "host_advanced_popup"]:
		var popup: Window = launcher.get(field)
		if popup.call("is_open_or_opening"):
			var label: Label = popup.get("error_label")
			label.text = message
			label.show()
			popup.call("_queue_layout")
			return
	storage.call("show_message", message, "提示", engine.is_running())


func _create_directory_picker() -> Window:
	var picker := DirectoryPicker.new()
	picker.directory_reader = _submit_directory_read
	return picker


func _submit_directory_read(path: String, initial_root: String) -> RefCounted:
	var job := DirectoryRead.new(path, initial_root)
	_directory_jobs.append(job)
	_poll_directory_reads()
	return job


func _poll_directory_reads() -> void:
	# One active OS enumeration. Cancelled queued requests are completed without
	# entering the worker pool, so rapid close/reopen cannot pile up scans.
	for index in range(_directory_jobs.size() - 1, -1, -1):
		var job := _directory_jobs[index]
		if job.task_id < 0 and job.is_cancelled():
			_directory_jobs.remove_at(index)
			job.completed.emit({"ok": false, "cancelled": true})
	if _directory_jobs.is_empty(): return
	var job := _directory_jobs[0]
	if job.task_id < 0:
		job.measure = ClientPerformance.enabled
		job.task_id = WorkerThreadPool.add_task(job.run, false, "Android directory read")
		return
	if not WorkerThreadPool.is_task_completed(job.task_id): return
	WorkerThreadPool.wait_for_task_completion(job.task_id)
	_directory_jobs.pop_front()
	var result: Dictionary = {"ok": false, "cancelled": true} if job.is_cancelled() else job.result
	if result.has("scan_usec"):
		ClientPerformance.record(&"android.directory_scan", int(result.scan_usec))
		ClientPerformance.count_event(&"android.directory_entries", int(result.get("entries", 0)))
	job.completed.emit(result)


func _finish_directory_reads() -> void:
	for job in _directory_jobs:
		job.cancel()
	for job in _directory_jobs:
		if job.task_id >= 0:
			WorkerThreadPool.wait_for_task_completion(job.task_id)
	_directory_jobs.clear()


func browse_game_directory(path: String) -> void:
	storage.call("browse", path)


func _browse_completed(path: String) -> void:
	launcher.call("_on_android_browse_completed", path)


func prepare_launch(path: String) -> bool:
	return bool(storage.call("ensure_game_access", path))


func show_location_error(message: String) -> void:
	storage.call("show_message", message, "地点配置错误", true)
	_sync_blocking()


func show_launch_error() -> void:
	storage.call("show_message", "游戏未能启动。\n请确认所选目录包含完整且受支持的游戏文件，然后重试。")


func game_started() -> void:
	display_settings.set_game_active(true)
	# The desktop launcher opens chat on start. Mobile P1 starts with game input.
	launcher.get("chat_ctrl").call("close_chat_input")
	_was_running = true
	touch.on_game_started()
	_sync_blocking()


func game_stopped() -> void:
	_cancel_menu_key()
	if is_instance_valid(console): console.close()
	touch.on_game_stopped()
	if display_panel.visible:
		display_panel.cancel()
	display_settings.set_game_active(false)
	launcher.get("chat_ctrl").call("dismiss_chat_popups")
	if is_instance_valid(native_chat):
		native_chat.cancel()
	touch.call("release_touches")
	_menu.hide()
	_dismiss_return_confirm()
	_was_running = false
	_sync_blocking()


func _process(_delta: float) -> void:
	if not _directory_jobs.is_empty(): _poll_directory_reads()
	if _was_running and not engine.is_running():
		game_stopped()
	var can_touch: bool = not _paused and ((touch.is_editor_open()) or \
		(engine.is_running() and touch.controls_enabled and not _menu.visible \
		and not is_modal_open() and not launcher.get("chat_ctrl").call("is_chat_open")))
	if touch.visible != can_touch:
		touch.call("release_touches")
		touch.visible = can_touch


func _notification(what: int) -> void:
	if not is_node_ready():
		return
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		handle_back()
	elif what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_paused = true
		_escape_owned = false
		_menu_pointer.cancel()
		_cancel_menu_key()
		native_input.call("set_suspended", true)
		native_chat.set_suspended(true)
		touch.call("release_touches")
		_sync_blocking()
	elif what == NOTIFICATION_APPLICATION_RESUMED or what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_paused = false
		native_input.call("set_suspended", false)
		native_chat.set_suspended(false)
		display_settings.request_display()
		_sync_blocking()


func _sync_blocking() -> void:
	if not is_instance_valid(_menu) or not is_instance_valid(storage):
		return
	var blocked := _paused or is_modal_open()
	if blocked and not touch.is_editor_open():
		touch.call("release_touches")
		touch.hide()
	touch.set_interaction_blocked(_paused or (is_instance_valid(native_input) and native_input.is_modal_open()) \
		or (is_instance_valid(console) and console.shown))
	engine.call("set_game_input_blocked", blocked)
	# Android overlays live outside the launcher's SubViewport.
	launcher.call("_sync_launcher_modal_input")


func is_modal_open() -> bool:
	return is_instance_valid(_menu) and (_menu.visible or _return_confirm.is_open_or_opening() or (is_instance_valid(display_panel) and display_panel.visible) or storage.call("is_modal_open") \
		or touch.is_editor_open() or (is_instance_valid(console) and console.shown) \
		or (is_instance_valid(native_input) and native_input.call("is_modal_open")) \
		or (is_instance_valid(native_chat) and native_chat.is_modal_open()) \
		or launcher.get("chat_ctrl").has_touch_modal())


func _chat_input_available() -> bool:
	# Exclude the chat editor's own token: deferred open rechecks this gate.
	if _paused or _menu.visible or _return_confirm.is_open_or_opening(): return false
	if touch.is_editor_open() or (is_instance_valid(console) and console.shown): return false
	if display_panel.visible or storage.is_modal_open() or native_input.is_modal_open(): return false
	if launcher.get("chat_ctrl").has_touch_modal(): return false
	for field in ["host_advanced_popup", "advanced_options_popup", "admin_credential_popup"]:
		if launcher.get(field).is_open_or_opening(): return false
	return not launcher.get("location_config_error").visible and not launcher.get("game_path_file_dialog").visible


func _input(event: InputEvent) -> void:
	if not event is InputEventKey or event.keycode != KEY_ESCAPE:
		return
	if event.pressed and not event.echo and not _paused:
		_escape_owned = is_modal_open()
	if not _escape_owned:
		return
	get_viewport().set_input_as_handled()
	# Keep the modal through release so Escape cannot leak to the game.
	if not event.pressed:
		_escape_owned = false
		if not _paused:
			handle_back()


func handle_back() -> void:
	if _return_confirm.is_open_or_opening():
		_dismiss_return_confirm()
		return
	if is_instance_valid(native_chat) and native_chat.handle_back():
		return
	if is_instance_valid(native_input) and native_input.call("handle_back"):
		return
	if is_instance_valid(console) and console.handle_back(): return
	if touch.handle_back_request(): return
	if display_panel.visible:
		display_panel.handle_back()
		return
	if storage.call("handle_back"):
		return
	var error_dialog: Window = launcher.get("location_config_error")
	if error_dialog.visible:
		error_dialog.hide()
		return
	for field: String in ["host_advanced_popup", "advanced_options_popup", "admin_credential_popup"]:
		var popup: Window = launcher.get(field)
		if popup.call("is_open_or_opening"):
			if field == "advanced_options_popup":
				var menu: PopupMenu = popup.get("source_options").get_popup()
				if menu.visible:
					menu.hide()
					return
				popup.call("handle_back")
			else:
				popup.call("dismiss")
			return
	var picker: FileDialog = launcher.get("game_path_file_dialog")
	if picker.visible:
		picker.hide()
		launcher.call("_on_game_path_browse_finished")
		return
	var chat: Control = launcher.get("chat_ctrl")
	if chat.handle_touch_back():
		return
	if not engine.is_running():
		engine.call_deferred("_on_window_close_requested")
	elif _menu.visible:
		_close_menu()
	else:
		_open_menu()


func _open_menu() -> void:
	if not engine.is_running() or _paused or _menu.visible or _other_modal_open():
		return
	_cancel_menu_key()
	_menu_label.text = "菜单"
	_visibility_button.text = "隐藏虚拟按钮" if touch.controls_enabled else "显示虚拟按钮"
	_menu.show()
	_layout_android_surfaces()
	_sync_blocking()


func _other_modal_open() -> bool:
	if _return_confirm.is_open_or_opening(): return true
	if touch.is_editor_open() or (is_instance_valid(console) and console.shown): return true
	if display_panel.visible or storage.is_modal_open() or native_input.is_modal_open() or native_chat.is_modal_open():
		return true
	if launcher.get("chat_ctrl").has_touch_modal() or launcher.get("chat_ctrl").is_chat_open():
		return true
	for field in ["host_advanced_popup", "advanced_options_popup", "admin_credential_popup"]:
		if launcher.get(field).is_open_or_opening():
			return true
	return launcher.get("location_config_error").visible or launcher.get("game_path_file_dialog").visible


func _close_menu() -> void:
	_menu.hide()
	_dismiss_return_confirm()
	_sync_blocking()


func _request_return() -> void:
	if not engine.is_running():
		return
	_menu_pointer.cancel()
	_menu_pointer.set_process_input(false)
	_menu_pointer.set_process_unhandled_input(false)
	_return_confirm.open()
	_sync_blocking()


func _dismiss_return_confirm() -> void:
	_return_confirm.dismiss()
	_menu_pointer.cancel()
	_menu_pointer.set_process_input(true)
	_menu_pointer.set_process_unhandled_input(true)
	_sync_blocking()


func _confirm_game_return() -> void:
	_dismiss_return_confirm()
	if not engine.is_running(): return
	_return_button.disabled = true
	_stop_game.call_deferred()


func _stop_game() -> void:
	# Never stop inside the input dispatch callback. Current native cleanup and
	# the launcher's existing watcher own the actual shutdown and return.
	engine.call("stop_game")
	_return_button.disabled = false
	game_stopped()


func _menu_button(text: String, action: Callable, parent: VBoxContainer = null) -> Button:
	var button := Button.new()
	button.text = text
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.set_meta(&"android_row_height", 1.5)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UiScale.mark_geometry_physical(button)
	button.pressed.connect(action)
	(parent if parent != null else _menu_content).add_child(button)
	return button


func _open_display_settings() -> void:
	if not engine.is_running(): return
	_menu.hide()
	display_panel.open()
	_sync_blocking()


func _display_settings_closed() -> void:
	_open_menu()


func _toggle_controls() -> void:
	if touch.set_controls_enabled(not touch.controls_enabled) != OK:
		_menu_label.text = "按键显示设置保存失败，请重试。"
		return
	_visibility_button.text = "隐藏虚拟按钮" if touch.controls_enabled else "显示虚拟按钮"


func _send_menu_key(key: int) -> void:
	launcher.get("chat_ctrl").close_chat_input()
	_close_menu()
	_cancel_menu_key()
	var serial := _menu_key_serial
	engine.set_menu_input(key, true)
	await get_tree().create_timer(0.08).timeout
	if serial == _menu_key_serial and is_instance_valid(engine):
		engine.set_menu_input(key, false)


func _cancel_menu_key() -> void:
	_menu_key_serial += 1
	if is_instance_valid(engine):
		engine.set_menu_input(0, false)


func _display_geometry_changed() -> void:
	_menu_pointer.cancel()
	touch.release_touches()
	_cancel_menu_key()
	touch.call("_layout")
	_layout_android_surfaces()
	if is_instance_valid(console): console.queue_layout()


func _open_layout_editor() -> void:
	_close_menu()
	_cancel_menu_key()
	touch.open_editor()


func _layout_editor_changed() -> void:
	var editing: bool = touch.is_editor_open()
	if _layout_editing and not editing:
		display_settings.end_orientation_preview()
	_layout_editing = editing
	_sync_blocking()


func _preview_layout_orientation(portrait: bool) -> void:
	_cancel_menu_key()
	display_settings.preview_orientation(2 if portrait else 0)


func _cancel_layout_fields() -> void:
	if not is_instance_valid(native_input): return
	for field: Control in touch.input_fields(): native_input.cancel_field(field)


func _can_open_console() -> bool:
	return engine.is_running() and not _paused and not _other_modal_open()


func _prepare_console() -> void:
	_close_menu()
	_cancel_menu_key()
	touch.release_touches()
	touch.hide()
	engine.set_game_input_blocked(true)


func _open_console() -> void:
	if is_instance_valid(console): console.toggle()


func _layout_android_surfaces(_scale: float = 0.0) -> void:
	var chat: Control = launcher.get("chat_ctrl")
	var safe := UiScale.safe_rect_for(chat.get_viewport())
	chat.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	chat.position = safe.position
	chat.size = safe.size
	_fit_launcher.call_deferred()
	if _menu.visible:
		_menu.theme = UiTheme.theme(true)
		UiTheme.apply_tree(_menu, true)
		var frame := UiTheme.frame(4)
		frame.border = null
		var edge := StyleBoxTexture.new()
		edge.texture = UiTheme.SYSTEM
		edge.region_rect = Rect2(56, 8, 8, 16)
		edge.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
		frame.right_edge = UiScale.physical_texture_stylebox(edge, UiTheme.factor())
		frame.edge_width = UiTheme.px(8)
		_menu.add_theme_stylebox_override("panel", frame)
		var original_line := TextLine.new()
		original_line.add_string(_menu_label.text, UiTheme.FONT, UiTheme.px(24))
		var original_height := maxf(Presentation.dp(32), maxf(int(UiTheme.FONT.get_height(UiTheme.px(24))), original_line.get_size().y))
		_menu_label.custom_minimum_size.y = ceilf(original_height * 1.5)
		var bounds := get_viewport().get_visible_rect()
		_menu.size = Vector2(bounds.size.x * (2.0 / 3.0 if bounds.size.y > bounds.size.x else 1.0 / 3.0), bounds.size.y)
		_menu.position = bounds.position
		UiTheme.scrollbar(_menu_scroll, true, UiTheme.px(4))


func _fit_launcher() -> void:
	if not is_instance_valid(launcher):
		return
	var menu := launcher.get_node("VBoxContainer") as Control
	var safe := UiScale.safe_rect_for(launcher.get_viewport())
	# Keep the launcher's own width and scaling; move its real hit rectangle.
	var center := safe.get_center() / launcher.get_viewport_rect().size
	menu.anchor_left = center.x
	menu.anchor_right = center.x
	menu.anchor_top = center.y
	menu.anchor_bottom = center.y
