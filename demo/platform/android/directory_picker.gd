extends Window

signal dir_selected(directory: String)
signal canceled()

const StorageAccess := preload("res://platform/android/storage_access.gd")
var storage: Control
var _cancel_pending := false
var directory_reader: Callable


func _init() -> void:
	visible = false


func _ready() -> void:
	title = "选择世界名配置目录（内含 config.json）"
	transient = true
	exclusive = true
	borderless = true
	add_theme_font_override("font", preload("res://resources/launcher_font.tres"))
	# This child Window belongs to the advanced modal's input domain.
	storage = _create_storage()
	storage.directory_reader = directory_reader
	storage.require_writable = false
	add_child(storage)
	storage.browse_completed.connect(_completed)
	storage.modal_changed.connect(_check_cancelled)
	close_requested.connect(func(): storage.cancel_browse())
	get_tree().root.size_changed.connect(_fit_window)


func _create_storage() -> Control:
	return StorageAccess.new()


func _fit_window() -> void:
	size = get_tree().root.size
	position = Vector2i.ZERO


func browse(path: String) -> void:
	_fit_window()
	popup()
	storage.browse(path)


func handle_back() -> void:
	storage.handle_back()


func _completed(path: String) -> void:
	if path.is_empty():
		_cancel_pending = true
		# A permission/open failure may show a message in the same callback stack.
		# Keep this Window alive until that message has actually been dismissed.
		_check_cancelled.call_deferred()
	else:
		dir_selected.emit(path)


func _check_cancelled() -> void:
	if _cancel_pending and not storage.is_modal_open():
		_cancel_pending = false
		canceled.emit()


func stop_pending_read() -> void:
	storage.invalidate_read()
