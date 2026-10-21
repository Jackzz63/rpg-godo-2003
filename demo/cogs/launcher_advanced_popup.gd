extends Window

signal save_requested(game_key: String, directory: String)
signal editing_started()
signal editing_finished()

const ConfigLoader := preload("res://cogs/locations/location_config_loader.gd")
const Geometry := preload("res://cogs/popup_geometry.gd")

@onready var source_options: OptionButton = %LocationSourceOptions
@onready var save_error: Label = %SaveError
@onready var error_dialog: AcceptDialog = %ImportError

var game_key := ""
var draft_directory := ""
var _edit_serial := 0
var _editing := false
var _picker: Window = null
var directory_picker_factory: Callable
var launcher_menu: Control
var _focus_keyboard := false
var _layout_pending := false
var _option_width := 0.0


func _ready() -> void:
	preload("res://cogs/popup_title_spacing.gd").install($Margin, $Margin/Content/Title)
	preload("res://cogs/dialog_footer.gd").install_shared($Margin/Content/Actions)
	preload("res://cogs/dialog_error_layout.gd").install(error_dialog, 420)
	UiScale.safe_area_changed.connect(_queue_layout)
	source_options.set_meta(&"plain_option_text", true)
	preload("res://cogs/launcher_popup_style.gd").install(source_options)
	source_options.item_selected.connect(_on_source_selected)
	window_input.connect(_track_focus_input)
	source_options.get_popup().window_input.connect(_track_focus_input)
	error_dialog.window_input.connect(_track_focus_input)
	error_dialog.visibility_changed.connect(func():
		if not error_dialog.visible: _restore_source_focus.call_deferred())
	%Confirm.pressed.connect(_on_confirm)
	%Cancel.pressed.connect(dismiss)
	close_requested.connect(dismiss)
	get_tree().root.size_changed.connect(_queue_layout)
	UiScale.scale_changed.connect(_on_scale_changed)
	$Margin/Content.minimum_size_changed.connect(_queue_layout)
	preload("res://cogs/ui_text_baseline.gd").install_caption_peer(
		$Margin/Content/SourceRow, $Margin/Content/SourceRow/Label, source_options)


func _exit_tree() -> void:
	_edit_serial += 1
	if UiScale.scale_changed.is_connected(_on_scale_changed):
		UiScale.scale_changed.disconnect(_on_scale_changed)
	if get_tree().root.size_changed.is_connected(_queue_layout):
		get_tree().root.size_changed.disconnect(_queue_layout)


func open_for_game(key: String, directory: String, keyboard := false) -> void:
	dismiss()
	_focus_keyboard = keyboard
	game_key = key
	draft_directory = directory
	_editing = true
	editing_started.emit()
	save_error.hide()
	_refresh_options()
	_show_after_layout(_edit_serial)


func is_open_or_opening() -> bool:
	return _editing


func dismiss() -> void:
	var was_editing := _editing
	_edit_serial += 1
	_editing = false
	_layout_pending = false
	game_key = ""
	draft_directory = ""
	if is_instance_valid(_picker):
		_release_picker(_picker)
	if is_instance_valid(error_dialog):
		error_dialog.hide()
	hide()
	if was_editing:
		editing_finished.emit()


func show_save_error(message: String) -> void:
	save_error.text = message
	save_error.show()
	_queue_layout()


func _refresh_options() -> void:
	source_options.clear()
	source_options.add_item("Collective Unconscious(默认)")
	source_options.add_item("自定义选择目录")
	if not draft_directory.is_empty():
		var label := draft_directory
		if label.length() > 42:
			label = "…" + label.right(42)
		source_options.add_item(label)
		source_options.set_item_tooltip(2, draft_directory)
		source_options.select(2)
	else:
		source_options.select(0)
	WebpageThemeTooltipRuntime.set_control_tooltip(source_options, draft_directory)
	$Margin/Content/SourceRow.queue_sort()
	_queue_layout()


func _on_source_selected(index: int) -> void:
	if not _editing:
		return
	save_error.hide()
	if index == 0:
		draft_directory = ""
		_refresh_options()
	elif index == 1:
		_refresh_options()
		if game_key.is_empty():
			show_save_error("请先在主界面选择游戏目录。")
			return
		# The OptionButton's popup must finish closing before opening a native dialog.
		_open_directory_browser.call_deferred(_edit_serial)


func _open_directory_browser(serial: int) -> void:
	if not _editing or serial != _edit_serial or is_instance_valid(_picker):
		return
	var picker: Window
	if directory_picker_factory.is_valid():
		picker = directory_picker_factory.call()
	else:
		var dialog := FileDialog.new()
		dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		dialog.access = FileDialog.ACCESS_FILESYSTEM
		dialog.use_native_dialog = true
		dialog.mode_overrides_title = false
		dialog.title = "选择世界名配置目录（内含 config.json）"
		dialog.transient = true
		dialog.exclusive = true
		if not draft_directory.is_empty():
			dialog.current_dir = draft_directory
		picker = dialog
	_picker = picker
	# Native system dialogs do not expose their final input source to Godot.
	_focus_keyboard = false
	add_child(picker)
	picker.window_input.connect(_track_focus_input)
	picker.connect("dir_selected", _on_directory_selected.bind(serial, picker))
	picker.connect("canceled", _on_picker_canceled.bind(serial, picker))
	if directory_picker_factory.is_valid():
		picker.call("browse", draft_directory)
	else:
		picker.popup_centered_ratio(0.75)


func _release_picker(picker: Window) -> void:
	if _picker == picker:
		_picker = null
	if is_instance_valid(picker):
		if picker.has_method("stop_pending_read"):
			picker.call("stop_pending_read")
		picker.hide()
		picker.queue_free()


func _on_directory_selected(directory: String, serial: int, picker: Window) -> void:
	_release_picker(picker)
	if not _editing or serial != _edit_serial:
		return
	var loaded := ConfigLoader.load_directory(directory)
	if not loaded.ok:
		_show_import_error(loaded)
		return
	draft_directory = loaded.data.directory
	_refresh_options()
	_restore_source_focus()


func _on_picker_canceled(serial: int, picker: Window) -> void:
	_release_picker(picker)
	if _editing and serial == _edit_serial:
		_restore_source_focus()


func _show_import_error(result: Dictionary) -> void:
	error_dialog.dialog_text = "%s\n问题文件：%s" % [result.error, result.file]
	error_dialog.popup_centered(Vector2i(UiScale.physical_int(420), 1))


func _on_confirm() -> void:
	if not _editing or is_instance_valid(_picker) or error_dialog.visible:
		return
	if game_key.is_empty():
		show_save_error("请先在主界面选择游戏目录。")
		return
	if not draft_directory.is_empty():
		var loaded := ConfigLoader.load_directory(draft_directory)
		if not loaded.ok:
			_show_import_error(loaded)
			return
	save_requested.emit(game_key, draft_directory)


func _show_after_layout(serial: int) -> void:
	var adapter := preload("res://cogs/option_popup_layout.gd").install(source_options)
	adapter.prepare_content_metrics()
	await get_tree().process_frame
	await get_tree().process_frame
	if not _editing or serial != _edit_serial:
		return
	_option_width = adapter.prepared_content_width()
	popup(_window_rect())
	_queue_layout()
	_restore_source_focus()


func _track_focus_input(event: InputEvent) -> void:
	if (event is InputEventKey or event is InputEventJoypadButton) and event.pressed:
		_focus_keyboard = true
	elif event is InputEventJoypadMotion and absf(event.axis_value) > 0.5:
		_focus_keyboard = true
	elif (event is InputEventMouseButton or event is InputEventScreenTouch) and event.pressed:
		_focus_keyboard = false


func _restore_source_focus() -> void:
	if _editing and visible and not is_instance_valid(_picker) and not error_dialog.visible \
			and not source_options.get_popup().visible:
		preload("res://cogs/button_pointer_feedback.gd").restore_focus(source_options, _focus_keyboard)


func _window_rect() -> Rect2i:
	var bounds := Geometry.bounds_for(self)
	var width := preload("res://cogs/launcher_popup_style.gd").content_width($Margin, {source_options: _option_width})
	var desired := Vector2i(ceili(width), ceili($Margin.get_combined_minimum_size().y))
	return Geometry.centered_rect_in_bounds(bounds, desired, Vector2i.ONE, UiScale.physical_int(12))


func _queue_layout() -> void:
	if visible and not _layout_pending:
		_layout_pending = true
		_reflow.call_deferred(_edit_serial)


func _reflow(serial: int) -> void:
	if serial != _edit_serial: return
	var adapter := preload("res://cogs/option_popup_layout.gd").install(source_options)
	adapter.prepare_content_metrics()
	await get_tree().process_frame
	if serial != _edit_serial: return
	_layout_pending = false
	if not visible: return
	_option_width = adapter.prepared_content_width()
	var rect := _window_rect()
	min_size = Vector2i.ZERO
	if size != rect.size: size = rect.size
	if position != rect.position: position = rect.position
	preload("res://cogs/option_popup_layout.gd").refresh(source_options)


func _on_scale_changed(_scale: float) -> void:
	_queue_layout()


func handle_back() -> void:
	if error_dialog.visible:
		error_dialog.hide()
	elif is_instance_valid(_picker):
		if _picker.has_method("handle_back"):
			_picker.call("handle_back")
		else:
			_on_picker_canceled(_edit_serial, _picker)
	else:
		dismiss()


func _unhandled_key_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel") \
			and not is_instance_valid(_picker) and not error_dialog.visible:
		dismiss()
		set_input_as_handled()
