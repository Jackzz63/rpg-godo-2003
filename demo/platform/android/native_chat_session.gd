extends Node

signal modal_changed()
signal input_failed()

const Reconciler := preload("res://platform/android/chat_edit_reconciler.gd")
var plugin: Object
var chat: Control
var field: LineEdit
var can_open: Callable
var _token := ""
var _serial := 0
var _sequence := -1
var _expected_revision := 0
var _baselines: Dictionary = {}
var _close_chat := false
var _suspended := false
var _finishing := false


func _ready() -> void:
	field = chat.get("chat_text_field")
	chat.set("touch_chat", true)
	field.virtual_keyboard_enabled = false
	field.gui_input.connect(_field_input)
	field.focus_entered.connect(_field_focused)
	chat.native_focus_requested.connect(request)
	chat.native_close_requested.connect(_close_requested)
	if plugin != null and plugin.has_signal("chat_checkpoint") and plugin.has_signal("closed"):
		plugin.connect("chat_checkpoint", _checkpoint, CONNECT_DEFERRED)
		plugin.connect("closed", _closed, CONNECT_DEFERRED)


func _field_input(event: InputEvent) -> void:
	if (event is InputEventScreenTouch and event.pressed) or \
			(event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		request()


func _field_focused() -> void:
	# Leave Godot's focus notification before handing ownership to Java.
	_request_focused.call_deferred()


func _request_focused() -> void:
	if field.has_focus():
		request()


func _available() -> bool:
	return not _suspended and field.editable and field.is_visible_in_tree() \
		and (not can_open.is_valid() or can_open.call())


func _has_plugin_method(method: String) -> bool:
	if plugin == null:
		return false
	# Android's JNISingleton stores @UsedByGodot methods in its Java method map,
	# not Object/ClassDB. Keep the ordinary-object path for desktop fixtures.
	if plugin.has_method("has_java_method"):
		return bool(plugin.call("has_java_method", method))
	return plugin.has_method(method)


func request() -> void:
	if not _token.is_empty() or not _available():
		return
	if not _has_plugin_method("openInput") or not _has_plugin_method("acceptChat") \
			or not _has_plugin_method("closeInput") or not plugin.has_signal("chat_checkpoint") \
			or not plugin.has_signal("closed"):
		push_warning("[AndroidChat] Native plugin is missing the chat session API or signals.")
		input_failed.emit()
		return
	_serial += 1
	_token = "chat:%d" % _serial
	_sequence = -1
	_close_chat = false
	_finishing = false
	# Claim the draft before Java is scheduled. ACKs must already see new ownership.
	field.set("external_editing", true)
	field.set("content_revision", int(field.get("content_revision")) + 1)
	_expected_revision = int(field.get("revision"))
	_baselines = {0: field.edit_checkpoint()}
	_open.call_deferred(_token)
	modal_changed.emit()


func _open(token: String) -> void:
	if token != _token:
		return
	if _finishing:
		var close_chat := _close_chat
		cancel()
		if close_chat:
			chat.call("close_chat_input")
		return
	if not _available():
		cancel()
		return
	field.release_focus()
	var selection: Vector2i = _baselines[0].state.selection
	plugin.call("openInput", token, field.text, "",
		0, 5, selection.x, selection.y, false)


func _checkpoint(token: String, serialized: String) -> void:
	if token != _token:
		return
	if not field.editable:
		# Release Java's pending command/close too when moderation revokes editing.
		cancel()
		return
	var data: Variant = JSON.parse_string(serialized)
	if not data is Dictionary or not _baselines.has(int(data.get("base", -1))):
		_fail()
		return
	var seq := int(data.get("seq", -1))
	if seq < _sequence:
		return
	if int(field.get("revision")) != _expected_revision:
		# A common action replaced this draft; never resurrect the old native base.
		cancel()
		return
	var base := int(data.base)
	if not Reconciler.apply(field, _baselines[base], data.get("edits", []),
			str(data.get("text", "")), Vector2i(int(data.get("start", 0)), int(data.get("end", 0)))):
		_fail()
		return
	var action := str(data.get("action", "edit"))
	var command_message := ""
	field.set("external_editing", false)
	if action == "undo":
		field.undo_draft()
	elif action == "redo":
		field.redo_draft()
	elif action == "spoiler":
		if not field.wrap_selection_as_spoiler():
			command_message = "无法标记：请选择可用文字，并检查剧透范围和聊天字数。"
	field.set("external_editing", true)
	_sequence = seq
	_expected_revision = int(field.get("revision"))
	var checkpoint: Dictionary = field.edit_checkpoint()
	for old_base: int in _baselines.keys():
		if old_base < base:
			_baselines.erase(old_base)
	_baselines[seq] = checkpoint
	if bool(data.get("final", false)):
		var close_chat := _close_chat
		_release()
		if action == "send":
			chat.call("_on_chat_field_text_submitted", field.text)
		elif close_chat:
			chat.call("close_chat_input")
		return
	var selection: Vector2i = checkpoint.state.selection
	plugin.call("acceptChat", token, JSON.stringify({"base": base, "seq": seq,
		"text": field.text, "start": selection.x, "end": selection.y, "message": command_message}))


func _close_requested(discard: bool) -> void:
	if discard:
		cancel()
	else:
		_close_chat = true
		finish()


func finish() -> void:
	if _token.is_empty() or _finishing:
		return
	_finishing = true
	plugin.call("closeInput", _token, false)


func cancel() -> void:
	var token := _token
	_release()
	if not token.is_empty() and plugin != null:
		plugin.call("closeInput", token, true)


func _release() -> void:
	_token = ""
	_baselines.clear()
	_finishing = false
	field.set("external_editing", false)
	modal_changed.emit()


func _closed(token: String, _text: String, _start: int, _end: int, _secret: bool, reason: String) -> void:
	if token == _token:
		_release()
		if reason in ["error", "unavailable", "destroy"]:
			input_failed.emit()


func _fail() -> void:
	cancel()
	input_failed.emit()


func is_modal_open() -> bool:
	return not _token.is_empty()


func handle_back() -> bool:
	if not is_modal_open():
		return false
	finish()
	return true


func set_suspended(value: bool) -> void:
	_suspended = value
	if value:
		finish()


func _exit_tree() -> void:
	cancel()
	if is_instance_valid(field):
		field.gui_input.disconnect(_field_input)
		field.focus_entered.disconnect(_field_focused)
	if is_instance_valid(chat):
		chat.native_focus_requested.disconnect(request)
		chat.native_close_requested.disconnect(_close_requested)
	if plugin != null and plugin.has_signal("chat_checkpoint") and plugin.is_connected("chat_checkpoint", _checkpoint):
		plugin.disconnect("chat_checkpoint", _checkpoint)
		plugin.disconnect("closed", _closed)
