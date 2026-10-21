extends Node

signal modal_changed()
signal input_failed()

enum Mode { TEXT, NICKNAME, URL, PASSWORD, MULTILINE, CHAT, NUMBER, CONSOLE }

var plugin: Object
var _fields: Dictionary = {}
var _active: Dictionary = {}
var _pending: Dictionary = {}
var _token := ""
var _serial := 0
var _finishing := false
var _suspended := false


func _ready() -> void:
	# Console pauses the scene. Its owner validity and native close handoff must
	# still settle, without making game controls process while paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	if plugin == null and OS.get_name() == "Android" and Engine.has_singleton("NativeTextInput"):
		plugin = Engine.get_singleton("NativeTextInput")
	if plugin != null:
		# Android emits from its UI thread. All Godot nodes are touched on the main thread.
		plugin.connect("snapshot", _on_snapshot, CONNECT_DEFERRED)
		plugin.connect("closed", _on_closed, CONNECT_DEFERRED)


func register_field(field: Control, mode: Mode, hint: String, available: Callable,
		visibility_changed := Callable(), completed := Callable()) -> void:
	if plugin == null or _fields.has(field):
		return
	_fields[field] = {"field": field, "mode": mode, "hint": hint,
		"available": available, "visibility_changed": visibility_changed, "completed": completed}
	field.set("virtual_keyboard_enabled", false)
	field.focus_entered.connect(_on_focus_entered.bind(field))
	field.gui_input.connect(_on_gui_input.bind(field))
	field.tree_exiting.connect(cancel_field.bind(field))


func _on_focus_entered(field: Control) -> void:
	# SpinBox focuses its LineEdit even for an arrow click. The editor's own
	# gui_input opens native editing for clicks inside the text area; keyboard
	# focus traversal still opens it here.
	if field.get_parent() is SpinBox and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		return
	request(field)


func _on_gui_input(event: InputEvent, field: Control) -> void:
	if (event is InputEventScreenTouch and event.pressed) or \
			(event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed):
		request(field)


func request(field: Control) -> void:
	if _suspended or not _fields.has(field) or not _valid(_fields[field]):
		return
	if _active.get("field") == field and not _finishing:
		return
	_pending = _fields[field]
	modal_changed.emit()
	# Never release Godot focus from inside focus_entered's dispatch stack.
	_advance.call_deferred()


func _valid(entry: Dictionary) -> bool:
	var field: Control = entry.get("field")
	return is_instance_valid(field) and field.is_inside_tree() and field.is_visible_in_tree() \
		and bool(field.get("editable")) and entry.available.is_valid() and bool(entry.available.call())


func _advance() -> void:
	if _suspended or (not _pending.is_empty() and not _valid(_pending)):
		_pending = {}
	if not _token.is_empty():
		if not _pending.is_empty():
			_finish(false)
		return
	if _pending.is_empty():
		modal_changed.emit()
		return
	_active = _pending
	_pending = {}
	_serial += 1
	_token = "launcher:%d" % _serial
	_finishing = false
	var field: Control = _active.field
	var text: String = field.get("text")
	if _active.mode == Mode.NUMBER and field.get_parent() is SpinBox:
		text = str(field.get_parent().value)
	var selection := _selection(field)
	var maximum := int(field.get("max_length")) if field is LineEdit else 0
	var masked := bool(field.get("secret")) if field is LineEdit else false
	field.release_focus()
	plugin.call("openInput", _token, text, _active.hint, maximum, _active.mode,
		selection.x, selection.y, masked)
	modal_changed.emit()


func _process(_delta: float) -> void:
	if not _active.is_empty() and not _valid(_active):
		cancel_field(_active.field)


func cancel_field(field: Control) -> void:
	if _pending.get("field") == field:
		_pending = {}
	if _active.get("field") == field:
		# Cancellation invalidates first; the final native snapshot must not revive a discarded draft.
		_active = {}
		_finish(true)
	modal_changed.emit()


func set_suspended(value: bool) -> void:
	_suspended = value
	if value:
		_pending = {}
		_finish(false)
	modal_changed.emit()


func handle_back() -> bool:
	if not is_modal_open():
		return false
	_pending = {}
	_finish(false)
	modal_changed.emit()
	return true


func _finish(discard: bool) -> void:
	if _token.is_empty() or _finishing:
		return
	_finishing = true
	plugin.call("closeInput", _token, discard)


func is_modal_open() -> bool:
	return not _token.is_empty() or not _pending.is_empty()


func _on_snapshot(token: String, text: String, start: int, end: int, secret: bool) -> void:
	if token == _token and not _active.is_empty() and _valid(_active):
		_apply_snapshot(text, start, end, secret)


func _on_closed(token: String, text: String, start: int, end: int, secret: bool, reason: String) -> void:
	if token != _token:
		return
	var failed := reason in ["error", "unavailable", "destroy"]
	var entry := _active
	var completed: Callable = entry.get("completed", Callable())
	var can_complete := reason == "done" and completed.is_valid() \
		and not _finishing and not _suspended and _pending.is_empty() \
		and not entry.is_empty() and _valid(entry)
	# Natural completion keeps the owner until this last snapshot, including the last IME character.
	if not failed and reason != "discard" and not _active.is_empty() and _valid(_active):
		_apply_snapshot(text, start, end, secret)
	# text_changed may cancel this field or request another native editor.
	can_complete = can_complete and not _finishing and not _suspended \
		and _pending.is_empty() and not _active.is_empty() \
		and _active.get("field") == entry.get("field") and _valid(_active)
	_token = ""
	_active = {}
	_finishing = false
	if failed:
		_pending = {}
		input_failed.emit()
	_advance.call_deferred()
	modal_changed.emit()
	# Retire the native session before a command can close the console/scene.
	if can_complete and completed.is_valid() and not _suspended \
			and _pending.is_empty() and _valid(entry):
		completed.call()


func _apply_snapshot(text: String, start: int, end: int, secret: bool) -> void:
	var field: Control = _active.field
	if _active.mode == Mode.NUMBER and field.get_parent() is SpinBox:
		if text.is_valid_float():
			field.get_parent().value = text.to_float()
		return
	var changed: bool = field.get("text") != text
	if changed:
		var blocked := field.is_blocking_signals()
		field.set_block_signals(true)
		field.set("text", text)
		field.set_block_signals(blocked)
		# Programmatic LineEdit/TextEdit assignment does not notify the launcher's consumers.
		if field is LineEdit:
			field.text_changed.emit(field.text)
		else:
			field.text_changed.emit()
	# A common text_changed handler may sanitize text or invalidate this editing context.
	if _active.is_empty() or not _valid(_active):
		return
	if _active.mode == Mode.PASSWORD and _active.visibility_changed.is_valid():
		_active.visibility_changed.call(not secret)
	_restore_selection(field, start, end)


static func _selection(field: Control) -> Vector2i:
	if field is LineEdit:
		return Vector2i(field.get_selection_from_column(), field.get_selection_to_column()) \
			if field.has_selection() else Vector2i(field.caret_column, field.caret_column)
	var edit := field as TextEdit
	if edit.has_selection():
		return Vector2i(_offset(edit, edit.get_selection_from_line(), edit.get_selection_from_column()),
			_offset(edit, edit.get_selection_to_line(), edit.get_selection_to_column()))
	var caret := _offset(edit, edit.get_caret_line(), edit.get_caret_column())
	return Vector2i(caret, caret)


static func _offset(edit: TextEdit, line: int, column: int) -> int:
	var offset := column
	for i in line:
		offset += edit.get_line(i).length() + 1
	return offset


static func _line_column(text: String, offset: int) -> Vector2i:
	var prefix := text.left(clampi(offset, 0, text.length()))
	return Vector2i(prefix.count("\n"), prefix.length() - prefix.rfind("\n") - 1)


static func _restore_selection(field: Control, start: int, end: int) -> void:
	var text: String = field.get("text")
	start = clampi(start, 0, text.length())
	end = clampi(end, 0, text.length())
	if field is LineEdit:
		field.caret_column = end
		field.deselect()
		if start != end:
			field.select(mini(start, end), maxi(start, end))
	else:
		var from := _line_column(text, mini(start, end))
		var to := _line_column(text, maxi(start, end))
		var caret := _line_column(text, end)
		field.deselect()
		field.set_caret_line(caret.x)
		field.set_caret_column(caret.y)
		if start != end:
			field.select(from.x, from.y, to.x, to.y)


func _exit_tree() -> void:
	if plugin != null:
		if not _token.is_empty():
			plugin.call("closeInput", _token, true)
		plugin.disconnect("snapshot", _on_snapshot)
		plugin.disconnect("closed", _on_closed)
