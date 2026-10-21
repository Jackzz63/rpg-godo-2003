extends Control

signal browse_completed(path: String)
signal modal_changed()

const Presentation := preload("res://platform/android/launcher_presentation.gd")
const UiTheme := preload("res://platform/android/ui_theme.gd")
const ThemedDialog := preload("res://platform/android/themed_dialog.gd")
const Footer := preload("res://cogs/dialog_footer.gd")
var require_writable := true
var game_probe: Callable
var directory_reader: Callable
var _pending_path := ""
var _browsing := false
var _awaiting_permission := false
var _initial_path := ""
var _current_path := ""
var _display_path := ""
var _initial_root := ""
var _browser: PanelContainer
var _path_label: Label
var _directories: ItemList
var _list_touch: Node
var _message: ThemedDialog
var _message_text: Label
var _title: Label
var _actions: BoxContainer
var _footer_wrap: MarginContainer
var _browser_background: TextureRect
var _title_wrap: MarginContainer
var _content: VBoxContainer
var _loading := false
var _read_serial := 0
var _read_job: RefCounted
var _loading_label: Label
var _list_region: Control
var _layout_serial := 0
const ROW_BATCH := 64


func _enter_tree() -> void:
	Presentation.take_ownership(self)


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	theme = UiTheme.theme()
	var shade := ColorRect.new()
	shade.color = Color(0.02, 0.03, 0.05, 0.92)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_browser_background = TextureRect.new()
	var background := AtlasTexture.new()
	background.atlas = UiTheme.SYSTEM
	background.region = Rect2(0, 32, 16, 16)
	_browser_background.texture = background
	_browser_background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_browser_background)
	_browser_background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_browser = _panel()
	_browser.name = "DirectoryBrowser"
	var content := VBoxContainer.new()
	_content = content
	_browser.add_child(content)
	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_wrap = MarginContainer.new()
	content.add_child(_title_wrap)
	_title_wrap.add_child(_title)
	_path_label = Label.new()
	_path_label.name = "CurrentPath"
	_path_label.set_meta(&"android_plain_text", true)
	_path_label.mouse_filter = Control.MOUSE_FILTER_PASS
	_path_label.clip_text = true
	_path_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	content.add_child(_path_label)
	_list_region = Control.new()
	_list_region.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(_list_region)
	_directories = ItemList.new()
	_directories.name = "DirectoryList"
	_directories.set_meta(&"android_plain_text", true)
	_directories.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_directories.item_activated.connect(_activate_directory)
	_list_region.add_child(_directories)
	_directories.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_loading_label = Label.new()
	_loading_label.set_meta(&"android_plain_text", true)
	_loading_label.text = "正在读取目录…"
	_loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_loading_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_list_region.add_child(_loading_label)
	_loading_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_loading_label.hide()
	_list_touch = preload("res://platform/android/item_list_touch.gd").new()
	_list_touch.list = _directories
	_list_touch.activate_on_tap = true
	_directories.add_child(_list_touch)
	_actions = BoxContainer.new()
	content.add_child(_actions)
	var up := _button("上一级")
	up.name = "UpDirectory"
	up.pressed.connect(func(): _open_directory(_current_path.get_base_dir()))
	_actions.add_child(up)
	var select := _button("选择当前目录")
	select.name = "SelectDirectory"
	select.pressed.connect(_select_directory)
	_actions.add_child(select)
	var cancel := _button("取消")
	cancel.name = "CancelDirectory"
	cancel.pressed.connect(func(): _finish_browse(""))
	_actions.add_child(cancel)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_actions.add_child(spacer)
	var help := _button("?")
	help.name = "DirectoryHelp"
	help.set_meta(&"dialog_footer_square", true)
	help.pressed.connect(_show_help)
	_actions.add_child(help)
	_footer_wrap = Footer.wrap_row(_actions)
	_message = ThemedDialog.new()
	_message.name = "DirectoryMessage"
	_message.with_cancel = false
	add_child(_message)
	_message_text = _message.get_label()
	_message_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_message_text.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_message.confirmed.connect(_dismiss_message)
	_message.canceled.connect(_dismiss_message)
	_browser.hide()
	_message.dismiss()
	hide()
	resized.connect(_refresh_layout)
	UiScale.safe_area_changed.connect(_refresh_layout)
	UiScale.scale_changed.connect(_on_scale_changed)
	_refresh_layout.call_deferred()


func _on_scale_changed(_scale: float) -> void:
	_refresh_layout()


func _refresh_layout() -> void:
	theme = UiTheme.theme()
	UiTheme.apply_tree(_browser)
	var frame := UiTheme.titled_frame(_title)
	frame.set_content_margin(SIDE_BOTTOM, UiTheme.px(8))
	_browser.add_theme_stylebox_override("panel", frame)
	Footer.apply_buttons(_actions, UiTheme.px(4), theme)
	Footer.set_gap(_footer_wrap, UiTheme.px(12))
	UiTheme.title_gap(_title, _content, _title_wrap)
	_title.text = "选择游戏文件目录" if require_writable else "选择世界名配置目录"
	var bounds := UiScale.safe_rect_for(get_viewport()).grow(-Presentation.dp(12))
	var target := Vector2(Presentation.dp(550), Presentation.dp(410)).min(bounds.size)
	target.x *= 2.0 / 3.0
	UiTheme.fit_actions(_actions, target.x - UiTheme.px(32))
	_browser.size = target
	_browser.position = bounds.position + (bounds.size - _browser.size) / 2.0
	_directories.fixed_icon_size = Vector2i(Presentation.dp(16), Presentation.dp(16))
	_directories.add_theme_constant_override("v_separation", Presentation.dp(8))
	_loading_label.add_theme_stylebox_override("normal", _directories.get_theme_stylebox("panel"))
	UiTheme.style_bar(_directories.get_v_scroll_bar(), false, Presentation.dp(12))
	_list_touch.slop = Presentation.dp(12)
	_refresh_path.call_deferred()
	_fit_directory_list()


func _fit_directory_list() -> void:
	_layout_serial += 1
	var serial := _layout_serial
	# Theme metrics and BoxContainer orientation settle on the next layout pass.
	await get_tree().process_frame
	await get_tree().process_frame
	if serial != _layout_serial:
		return
	var padding := _directories.get_theme_stylebox("panel").get_minimum_size().y
	var row_height := maxf(_directories.get_theme_font("font").get_height(
		_directories.get_theme_font_size("font_size")), _directories.fixed_icon_size.y)
	row_height += _directories.get_theme_constant("v_separation")
	var required_height := row_height + padding
	if not _loading and _directories.item_count > 0:
		var row := _directories.get_item_rect(0)
		# Keep the loading row budget after enumeration so a later reflow is stable.
		row_height = maxf(row_height, row.size.y)
		required_height = maxf(required_height, row.end.y + _directories.get_theme_stylebox("panel").get_margin(SIDE_BOTTOM))
	# Keep the original geometry whenever one complete touchable row already fits.
	# Reserve space even before enumeration, so loading and empty directories work.
	# The region rect can still be zero while its parent is sorting. Measure the
	# fixed content minimum instead, or an already-fitting phone would grow too.
	var fixed_height := _browser.get_combined_minimum_size().y
	if _browser.size.y - fixed_height + 0.5 < required_height:
		var bounds := UiScale.safe_rect_for(get_viewport()).grow(-Presentation.dp(12))
		_browser.size.y = minf(bounds.size.y, fixed_height + row_height * 3.0 + padding)
		_browser.position = bounds.position + (bounds.size - _browser.size) / 2.0


func _refresh_path() -> void:
	var font := _path_label.get_theme_font("font")
	var font_size := _path_label.get_theme_font_size("font_size")
	var shown := _display_path
	var available := _path_label.size.x
	if font.get_string_size(shown, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x > available:
		var parts := _display_path.split("/", false)
		while parts.size() > 1:
			parts.remove_at(0)
			shown = "…/" + "/".join(parts)
			if font.get_string_size(shown, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= available:
				break
		# A single unusually long final component still displays its tail.
		while shown.length() > 3 and font.get_string_size(shown, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x > available:
			shown = "…/" + shown.substr(3)
	_path_label.text = shown
	WebpageThemeTooltipRuntime.set_control_tooltip(_path_label, _display_path)


func _show_help() -> void:
	show_message("选择到游戏目录内RPG_RT.ldb、RPG_RT.lmt的位置，\n该位置一般也存放有存档Save01.lsd和Map0001.lmu等文件。" \
		if require_writable else "选择含 config.json 的世界名配置目录。这里只需读取；\n选中后还需在其他设置中保存。", "目录选择说明")


func _panel() -> PanelContainer:
	var panel := PanelContainer.new()
	add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	return panel


func _button(label: String) -> Button:
	var button := Button.new()
	button.text = label
	return button


func is_modal_open() -> bool:
	return visible or _awaiting_permission


func browse(path: String) -> void:
	if _browsing:
		return
	_browsing = true
	_initial_path = path
	if not _has_permission():
		_request_permission()
		return
	_open_initial_directory()


func _open_initial_directory() -> void:
	_initial_root = _storage_root()
	_open_directory(_initial_path)


func _open_directory(path: String) -> void:
	if not _browsing:
		return
	invalidate_read()
	var serial := _read_serial
	_loading = true
	_display_path = path if path.is_absolute_path() else _initial_root
	_refresh_path()
	_loading_label.show()
	_directories.hide()
	_set_loading_controls(true)
	_browser.show()
	_fit_directory_list()
	_sync_visibility()
	_load_directory(path, serial)


func _request_current(serial: int) -> bool:
	return serial == _read_serial and _browsing and is_inside_tree() and not is_queued_for_deletion()


# Silent invalidation is also used when a picker is released by its owner.
# It must not emit another completion and re-enter the owner's release callback.
func invalidate_read() -> void:
	_read_serial += 1
	_loading = false
	if _read_job != null:
		_read_job.cancel()
		_read_job = null


func _exit_tree() -> void:
	invalidate_read()


func _set_loading_controls(loading: bool) -> void:
	for name in ["UpDirectory", "SelectDirectory"]:
		_actions.get_node(name).disabled = loading
	_directories.mouse_filter = Control.MOUSE_FILTER_IGNORE if loading else Control.MOUSE_FILTER_STOP
	_list_touch.set_process_input(not loading)
	_list_touch.cancel()
	for index in _directories.item_count:
		_directories.set_item_disabled(index, loading)


func _load_directory(path: String, serial: int) -> void:
	var first_frame := ClientPerformance.begin()
	# Deferred calls alone still run before drawing. Give the loading panel a
	# visible frame before opening/enumerating the directory.
	await get_tree().process_frame
	if not _request_current(serial):
		return
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		if not _request_current(serial):
			return
	ClientPerformance.end(&"android.directory_first_frame", first_frame)
	var result: Dictionary = await _read_directory(path, serial)
	if not _request_current(serial):
		return
	if not result.ok:
		_loading = false
		_loading_label.hide()
		_directories.show()
		_display_path = _current_path
		_refresh_path()
		_set_loading_controls(false)
		show_message("无法打开此目录。请确认所有文件访问权限，并选择共享存储中的真实目录。")
		if _current_path.is_empty():
			_finish_browse("")
		return
	var names: PackedStringArray = result.names
	var started := ClientPerformance.begin()
	_directories.clear()
	var target := str(result.get("path", path)).simplify_path()
	_display_path = target
	_refresh_path()
	var batch_start := Time.get_ticks_usec()
	for index in names.size():
		var entry := names[index]
		_directories.add_item("📁 " + entry)
		_directories.set_item_metadata(index, target.path_join(entry))
		_directories.set_item_disabled(index, true)
		if (index + 1) % ROW_BATCH == 0 or Time.get_ticks_usec() - batch_start >= 2000:
			await get_tree().process_frame
			if not _request_current(serial):
				return
			batch_start = Time.get_ticks_usec()
	_current_path = target
	_display_path = target
	_refresh_path()
	_directories.get_v_scroll_bar().value = 0
	_loading = false
	_loading_label.hide()
	_directories.show()
	_set_loading_controls(false)
	_fit_directory_list()
	ClientPerformance.end(&"android.directory_rows", started)


# A narrow fixture seam: production and tests share result acceptance, modal
# ownership, row construction and cancellation. Only enumeration is replaceable.
func _read_directory(path: String, serial: int) -> Dictionary:
	var fallback := _initial_root
	_initial_root = ""
	if not directory_reader.is_valid(): return {"ok": false}
	var job: RefCounted = directory_reader.call(path, fallback)
	_read_job = job
	var result: Dictionary = await job.completed
	if _request_current(serial): _read_job = null
	return result


func _select_directory() -> void:
	if _loading or not _browsing:
		return
	var error := inspect_readable_directory(_current_path)
	if not error.is_empty():
		show_message(error)
		return
	if not require_writable:
		_finish_browse(_current_path)
		return
	var result: Dictionary = game_probe.call(_current_path) if game_probe.is_valid() else {"ok": false, "error": "游戏识别接口不可用。"}
	if not result.get("ok", false):
		show_message(str(result.get("error", "")) + "\n\n注意，本启动器仅兼容基于RPG Maker 2003和RPG Maker 2000的游戏。\n\n请尝试重新选择。", "未识别到游戏文件")
		return
	error = inspect_directory(_current_path)
	if not error.is_empty():
		show_message(error)
		return
	_pending_path = _current_path
	show_message("已成功识别[%s]。\n\n游戏与存档目录：%s\n\n请确认启动器参数后点击保存并运行。" % \
		[_read_game_title(str(result.get("ini_path", ""))), _current_path], "游戏文件识别成功")


func _activate_directory(index: int) -> void:
	if not _loading and _browsing and not _message.is_open_or_opening():
		_open_directory(str(_directories.get_item_metadata(index)))


static func _read_game_title(ini_path: String) -> String:
	var ini := FileAccess.open(ini_path, FileAccess.READ) if not ini_path.is_empty() else null
	if ini == null or ini.get_length() > 65536: return "未知游戏"
	var text := ini.get_as_text()
	ini.close()
	var section := false
	for raw_line in text.split("\n"):
		var line := raw_line.trim_prefix("\uFEFF").strip_edges()
		if line.begins_with("[") and line.ends_with("]"):
			section = line.to_lower() == "[rpg_rt]"
			continue
		var separator := line.find("=")
		if not section or separator < 0 or line.substr(0, separator).strip_edges().to_lower() != "gametitle": continue
		var title := line.substr(separator + 1).strip_edges()
		if title.length() >= 2 and ((title.begins_with('"') and title.ends_with('"')) or (title.begins_with("'") and title.ends_with("'"))):
			title = title.substr(1, title.length() - 2).strip_edges()
		if title.is_empty() or title.length() > 128 or title.contains("\uFFFD"): return "未知游戏"
		for index in title.length():
			if title.unicode_at(index) < 0x20 or title.unicode_at(index) == 0x7f: return "未知游戏"
		return title
	return "未知游戏"


func _finish_browse(path: String) -> void:
	if not _browsing:
		return
	invalidate_read()
	_browsing = false
	_awaiting_permission = false
	_browser.hide()
	_current_path = ""
	_display_path = ""
	_initial_root = ""
	_sync_visibility()
	browse_completed.emit(path)


func ensure_game_access(path: String) -> bool:
	if not _has_permission():
		_request_permission()
		return false
	var error := inspect_readable_directory(path)
	if error.is_empty():
		var result: Dictionary = game_probe.call(path) if game_probe.is_valid() else {"ok": false, "error": "游戏识别接口不可用。"}
		if not result.get("ok", false): error = str(result.get("error", "未识别到游戏文件。"))
	if error.is_empty(): error = inspect_directory(path)
	if not error.is_empty():
		show_message(error)
		return false
	return true


static func inspect_directory(path: String) -> String:
	# Game format recognition remains owned by the current native player.
	var read_error := inspect_readable_directory(path)
	if not read_error.is_empty():
		return read_error
	var probe := path.path_join(".rpggodo-write-test-%d-%d" % [Time.get_ticks_usec(), randi()])
	if FileAccess.file_exists(probe):
		return "写入检查文件已存在，请重试。"
	var output := FileAccess.open(probe, FileAccess.WRITE)
	if output == null:
		return "无法在游戏目录创建存档文件。请选择可写目录。"
	var token := "rpggodo-write-check"
	output.store_string(token)
	output.flush()
	var write_error := output.get_error()
	output.close()
	var input := FileAccess.open(probe, FileAccess.READ)
	var matches := input != null and input.get_as_text() == token
	if input != null:
		input.close()
	var remove_error := DirAccess.remove_absolute(probe)
	if write_error != OK or not matches or remove_error != OK:
		return "游戏目录写入检查失败，请检查存储空间和读写权限。\n检查文件：%s" % probe
	return ""


static func inspect_readable_directory(path: String) -> String:
	if not path.is_absolute_path() or path.contains("://") or path.begins_with("//"):
		return "请选择共享存储中的真实目录。此入口不接受 content:// 或资源路径。"
	if DirAccess.open(path) == null:
		return "无法读取目录。请重新选择目录并检查访问权限。"
	return ""


func cancel_browse() -> void:
	_awaiting_permission = false
	_pending_path = ""
	_message.dismiss()
	_finish_browse("")
	_sync_visibility()


func _has_permission() -> bool:
	var environment = JavaClassWrapper.wrap("android.os.Environment")
	var granted = environment.isExternalStorageManager()
	return JavaClassWrapper.get_exception() == null and bool(granted)


func _storage_root() -> String:
	var environment = JavaClassWrapper.wrap("android.os.Environment")
	var directory = environment.getExternalStorageDirectory()
	if JavaClassWrapper.get_exception() != null or directory == null:
		return ""
	var path = directory.getAbsolutePath()
	return str(path) if JavaClassWrapper.get_exception() == null else ""


func _open_permission_settings() -> bool:
	var runtime = Engine.get_singleton("AndroidRuntime")
	if runtime == null:
		return false
	var activity = runtime.getActivity()
	if activity == null:
		return false
	var intent_class = JavaClassWrapper.wrap("android.content.Intent")
	var settings = JavaClassWrapper.wrap("android.provider.Settings")
	var uri_class = JavaClassWrapper.wrap("android.net.Uri")
	var intent = intent_class.Intent()
	intent.setAction(settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
	intent.setData(uri_class.parse("package:" + str(activity.getPackageName())))
	activity.startActivity(intent)
	if JavaClassWrapper.get_exception() == null:
		return true
	var fallback = intent_class.Intent()
	fallback.setAction(settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
	activity.startActivity(fallback)
	return JavaClassWrapper.get_exception() == null


func _request_permission() -> void:
	if _awaiting_permission:
		return
	_awaiting_permission = true
	modal_changed.emit()
	if not _open_permission_settings():
		_awaiting_permission = false
		_finish_browse("")
		show_message("无法打开所有文件访问设置。\n请在系统设置中为本应用授权，然后重试。")


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_RESUMED and is_node_ready():
		_refresh_layout.call_deferred()
	if what == NOTIFICATION_APPLICATION_RESUMED and _awaiting_permission:
		call_deferred("_permission_returned")


func _permission_returned() -> void:
	if not _awaiting_permission:
		return
	_awaiting_permission = false
	if not _has_permission():
		_finish_browse("")
		show_message("尚未取得所有文件访问权限。\n授权后可浏览共享存储中的真实目录。")
	elif _browsing:
		_open_initial_directory()
	else:
		show_message("已取得权限。请重新点击保存并运行。")
	modal_changed.emit()


func show_message(message: String, title := "提示", in_game := false) -> void:
	_message.in_game = in_game
	_message.title = title
	_message.dialog_text = message
	_message.open()
	_sync_visibility()


func _dismiss_message() -> void:
	_message.dismiss()
	var selected := _pending_path
	_pending_path = ""
	if not selected.is_empty(): _finish_browse(selected)
	_sync_visibility()


func _sync_visibility() -> void:
	visible = _browser.visible or _message.is_open_or_opening()
	_browser_background.visible = _browser.visible
	modal_changed.emit()


func handle_back() -> bool:
	if _message.is_open_or_opening():
		_dismiss_message()
		return true
	if _browsing and not _awaiting_permission:
		_finish_browse("")
		return true
	return _awaiting_permission
