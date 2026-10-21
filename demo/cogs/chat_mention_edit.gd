extends LineEdit

const Mentions := preload("res://cogs/chat_mentions.gd")
const Marks := preload("res://cogs/chat_mention_marks.gd")
const Spoilers := preload("res://cogs/chat_spoilers.gd")
const MENU_SPOILER := MENU_MAX + 1

var revision := 0
var content_revision := 0
var _display_language := "en"
var _pending_language := ""
var mentions: Array[Dictionary] = []
var _known_text := ""
var _writing := false
var _undo: Array[Dictionary] = []
var _redo: Array[Dictionary] = []
var _anchor := Vector2i.ZERO
var _anchor_caret := 0
var _drop_intent: Dictionary = {}
var _marks: Control
var _handling_native_change := false
var _native_menu_callbacks: Array[Callable] = []
var _menu_revision := -1
var external_editing := false


func _init() -> void:
	# Capture only the native connections, before callers can add observers.
	# Native Callable method names are unavailable in release builds.
	for connection in get_menu().get_signal_connection_list("id_pressed"):
		_native_menu_callbacks.append(connection.callable)


func _ready() -> void:
	max_length = 0 # The semantic wire budget is enforced by replace_range.
	_known_text = text
	text_changed.connect(_native_changed)
	_marks = Marks.new()
	_marks.host = self
	add_child(_marks)
	var menu := get_menu()
	# The native popup's edit commands must share the semantic undo history.
	for callback in _native_menu_callbacks:
		if menu.id_pressed.is_connected(callback):
			menu.id_pressed.disconnect(callback)
	_native_menu_callbacks.clear()
	menu.id_pressed.connect(_menu_action)
	menu.about_to_popup.connect(_update_menu)
	_configure_menu()


func _input(_event: InputEvent) -> void:
	if has_focus():
		remember_selection()


func _process(_delta: float) -> void:
	if not _pending_language.is_empty():
		set_display_language(_pending_language)
	if not has_focus() or has_ime_text():
		return
	if not has_selection() and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		caret_column = _snap(caret_column)
	remember_selection()


func remember_selection() -> void:
	_anchor_caret = caret_column
	_anchor = Vector2i(get_selection_from_column(), get_selection_to_column()) if has_selection() else Vector2i(caret_column, caret_column)


func get_mentions() -> Array[Dictionary]:
	_sync_external()
	return mentions.duplicate(true)


func get_submission() -> Dictionary:
	_sync_external()
	var payload := Mentions.to_wire(text, mentions)
	return {"text": payload.text, "mentions": payload.mentions, "revision": content_revision}


func set_display_language(language: String) -> void:
	var normalized := Mentions.PlayerName.LocationResolver.normalize_language_code(language)
	if normalized == _display_language:
		_pending_language = ""
		return
	if external_editing or has_ime_text() or not _drop_intent.is_empty() or (is_inside_tree() and get_viewport().gui_is_dragging()):
		_pending_language = normalized
		return
	_sync_external()
	var state := _snapshot()
	_display_language = normalized
	_pending_language = ""
	_apply(state, false)


func _wire_range_length(start: int, end: int) -> int:
	var length := end - start
	for span in mentions:
		if bool(span.get("is_unnamed", false)) and int(span.start) >= start and int(span.start) + int(span.length) <= end:
			length += Mentions.UNNAMED_TOKEN.length() - int(span.length)
	return length


func reset_draft() -> void:
	_undo.clear()
	_redo.clear()
	_apply({"text": "", "mentions": [], "caret": 0, "selection": Vector2i.ZERO})


func set_plain_text(value: String) -> void:
	_undo.clear()
	_redo.clear()
	var normalized := Mentions.normalize_text(value)
	_apply({"text": normalized, "mentions": [], "caret": normalized.length(), "selection": Vector2i(normalized.length(), normalized.length())})


func insert_mention(public_id: String, nickname: String) -> bool:
	_sync_external()
	if not editable or not Mentions.valid_id(public_id):
		return false
	if Mentions.InputLimits.sanitize_nickname(nickname) != nickname:
		return false
	var bounds := _expanded(_anchor.x, _anchor.y)
	var unnamed := nickname.is_empty()
	var token := "@" + Mentions.PlayerName.display(nickname, _display_language)
	var wire_length := Mentions.UNNAMED_TOKEN.length() if unnamed else token.length()
	var available := Mentions.MAX_TEXT - _wire_range_length(0, text.length()) + _wire_range_length(bounds.x, bounds.y)
	if wire_length > available:
		return false
	var insertion := token + (" " if wire_length < available else "")
	var span := {"start": 0, "length": token.length(), "public_chat_id": public_id}
	if unnamed:
		span["is_unnamed"] = true
	return replace_range(bounds.x, bounds.y, insertion, [span])


func replace_range(start: int, end: int, insertion: String, added: Array = [], record_undo: bool = true) -> bool:
	_sync_external()
	if not editable:
		return false
	var before := _snapshot()
	var bounds := _expanded(start, end)
	var clean := insertion.replace("\uFFFF", "").replace("\uFFFE", "")
	var capacity := Mentions.MAX_TEXT - _wire_range_length(0, text.length()) + _wire_range_length(bounds.x, bounds.y)
	var wire := Mentions.to_wire(clean, added)
	if not added.is_empty() and str(wire.text).length() > capacity:
		return false
	if added.is_empty():
		clean = clean.left(maxi(0, capacity))
		wire = Mentions.to_wire(clean, added)
	if not Mentions.valid_spans(str(wire.text), wire.mentions):
		return false
	var next_text := text.left(bounds.x) + clean + text.substr(bounds.y)
	var delta := clean.length() - (bounds.y - bounds.x)
	var next: Array[Dictionary] = []
	for value in mentions:
		var span := value.duplicate(true)
		var a := int(span.start)
		var b := a + int(span.length)
		if a < bounds.y and b > bounds.x:
			continue
		if a >= bounds.y:
			span.start = a + delta
		next.append(span)
	for value in added:
		var span: Dictionary = value.duplicate(true)
		span.start = int(span.start) + bounds.x
		next.append(span)
	next.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.start) < int(b.start))
	var caret := bounds.x + clean.length()
	if record_undo:
		_undo.append(before)
		_redo.clear()
	_apply({"text": next_text, "mentions": next, "caret": caret, "selection": Vector2i(caret, caret)})
	return true


func undo_draft() -> void:
	if not editable or _undo.is_empty():
		return
	_redo.append(_snapshot())
	_apply(_undo.pop_back())


func redo_draft() -> void:
	if not editable or _redo.is_empty():
		return
	_undo.append(_snapshot())
	_apply(_redo.pop_back())


func _snapshot() -> Dictionary:
	return {"text": _known_text, "mentions": mentions.duplicate(true), "caret": _anchor_caret, "selection": _anchor}


# Native editing checkpoints include the semantic history, not LineEdit's text-only undo.
# Restoring an unacknowledged checkpoint is internal reconciliation; observers receive
# one final text_changed after all range edits have been applied.
func edit_checkpoint() -> Dictionary:
	_sync_external()
	return {"state": _snapshot(), "undo": _undo.duplicate(true), "redo": _redo.duplicate(true)}


func restore_edit_checkpoint(checkpoint: Dictionary) -> void:
	var state: Dictionary = checkpoint.state
	_writing = true
	text = state.text
	_known_text = text
	mentions.assign(state.mentions.duplicate(true))
	_undo.assign(checkpoint.undo.duplicate(true))
	_redo.assign(checkpoint.redo.duplicate(true))
	set_edit_selection(state.selection.x, state.selection.y)
	_writing = false


func set_edit_selection(start: int, end: int) -> void:
	caret_column = clampi(end, 0, text.length())
	deselect()
	if start != end:
		select(clampi(mini(start, end), 0, text.length()), clampi(maxi(start, end), 0, text.length()))
	else:
		caret_column = _snap(caret_column)
	remember_selection()


func finish_external_reconcile() -> void:
	_refresh_marks()
	text_changed.emit(text)


func _apply(state: Dictionary, content_changed: bool = true) -> void:
	var projected := Mentions.to_display(str(state.text), state.mentions, _display_language)
	_writing = true
	text = str(projected.text)
	_known_text = text
	mentions.clear()
	for span in projected.mentions:
		mentions.append(span.duplicate(true))
	caret_column = Mentions.mapped_offset(projected.mapping, int(state.caret))
	deselect()
	var selection: Vector2i = state.selection
	if selection.x != selection.y:
		select(Mentions.mapped_offset(projected.mapping, selection.x), Mentions.mapped_offset(projected.mapping, selection.y))
	remember_selection()
	revision += 1
	if content_changed:
		content_revision += 1
	_refresh_marks()
	# Native edits already have a text_changed emission in progress. Observers
	# can read the reconciled text/mentions without receiving a nested emission.
	if not _handling_native_change:
		text_changed.emit(text)
	_writing = false


func _sync_external() -> void:
	if not _writing and text != _known_text:
		# External callers replacing the draft do not create semantic mentions.
		_known_text = Mentions.normalize_text(text)
		text = _known_text
		mentions.clear()
		_undo.clear()
		_redo.clear()
		revision += 1
		content_revision += 1
		remember_selection()
		_refresh_marks()


func _native_changed(value: String) -> void:
	if _writing:
		return
	# This is only a native echo, not an explicit replacement transaction.
	# Same-text paste/drop must still remove the replaced semantic tags.
	if _drop_intent.is_empty() and value == _known_text:
		return
	var old := _known_text
	var start := 0
	var end := old.length()
	var insertion := ""
	if not _drop_intent.is_empty():
		start = int(_drop_intent.start)
		end = int(_drop_intent.end)
		insertion = str(_drop_intent.text)
		_drop_intent.clear()
	else:
		while start < mini(old.length(), value.length()) and old[start] == value[start]:
			start += 1
		var suffix := 0
		while suffix < mini(old.length(), value.length()) - start and old[old.length() - 1 - suffix] == value[value.length() - 1 - suffix]:
			suffix += 1
		end = old.length() - suffix
		insertion = value.substr(start, value.length() - start - suffix)
	# Native input and IME produce text; only our explicit insertion creates tags.
	_writing = true
	text = old
	_writing = false
	_handling_native_change = true
	replace_range(start, end, insertion)
	_handling_native_change = false


func _expanded(start: int, end: int) -> Vector2i:
	var a := clampi(mini(start, end), 0, text.length())
	var b := clampi(maxi(start, end), 0, text.length())
	if a == b:
		return Vector2i(_snap(a), _snap(a))
	for span in mentions:
		var s := int(span.start)
		var e := s + int(span.length)
		if s < b and e > a:
			a = mini(a, s)
			b = maxi(b, e)
	return Vector2i(a, b)


func _snap(column: int) -> int:
	for span in mentions:
		var a := int(span.start)
		var b := a + int(span.length)
		if column > a and column < b:
			return a if column - a < b - column else b
	return column


func _refresh_marks() -> void:
	if not is_instance_valid(_marks):
		return
	_marks.ranges.clear()
	for span in mentions:
		_marks.ranges.append(Vector2i(int(span.start), int(span.start) + int(span.length)))


func _menu_action(id: int) -> void:
	if id == MENU_SPOILER:
		_sync_external()
		if revision == _menu_revision:
			wrap_selection_as_spoiler()
		return
	if id == MENU_COPY:
		menu_option(LineEdit.MENU_COPY)
		return
	if id == MENU_SELECT_ALL:
		select_all()
		remember_selection()
		return
	if not editable:
		return
	var bounds := _expanded(_anchor.x, _anchor.y)
	match id:
		MENU_CUT:
			if bounds.x != bounds.y:
				DisplayServer.clipboard_set(text.substr(bounds.x, bounds.y - bounds.x))
				replace_range(bounds.x, bounds.y, "")
		MENU_PASTE:
			_paste_plain(bounds.x, bounds.y, DisplayServer.clipboard_get())
		MENU_CLEAR:
			replace_range(0, text.length(), "")
		MENU_UNDO:
			undo_draft()
		MENU_REDO:
			redo_draft()
		_:
			menu_option(id)


func _update_menu() -> void:
	_sync_external()
	_menu_revision = revision
	var menu := get_menu()
	menu.set_item_disabled(menu.get_item_index(MENU_UNDO), not editable or _undo.is_empty())
	menu.set_item_disabled(menu.get_item_index(MENU_REDO), not editable or _redo.is_empty())
	menu.set_item_disabled(menu.get_item_index(MENU_SPOILER), _spoiler_edit().is_empty())


func _configure_menu() -> void:
	var labels := {
		MENU_CUT: "剪切", MENU_COPY: "复制", MENU_PASTE: "粘贴",
		MENU_SELECT_ALL: "全选", MENU_CLEAR: "清空", MENU_UNDO: "撤销", MENU_REDO: "重做",
	}
	var menu := get_menu()
	for index in range(menu.item_count - 1, -1, -1):
		var id := menu.get_item_id(index)
		if menu.is_item_separator(index) or not labels.has(id):
			menu.remove_item(index)
		else:
			menu.set_item_text(index, str(labels[id]))
	menu.add_separator()
	menu.add_item("作为剧透内容隐藏", MENU_SPOILER)


func _spoiler_edit() -> Dictionary:
	if not editable or has_ime_text():
		return {}
	var bounds := _expanded(_anchor.x, _anchor.y)
	var edit := Spoilers.wrap(text, bounds.x, bounds.y)
	if edit.is_empty() or _wire_range_length(0, text.length()) + str(edit.insertion).length() - (bounds.y - bounds.x) > Mentions.MAX_TEXT:
		return {}
	edit["bounds"] = bounds
	return edit


func wrap_selection_as_spoiler() -> bool:
	_sync_external()
	var edit := _spoiler_edit()
	if edit.is_empty():
		return false
	var bounds: Vector2i = edit.bounds
	var added: Array[Dictionary] = []
	for value in mentions:
		var start := int(value.start)
		var end := start + int(value.length)
		if start < bounds.x or end > bounds.y:
			continue
		var span := value.duplicate(true)
		span.start = int(edit.offsets[start - bounds.x])
		span.length = int(edit.offsets[end - bounds.x]) - int(span.start)
		added.append(span)
	return replace_range(bounds.x, bounds.y, str(edit.insertion), added)


func _paste_plain(start: int, end: int, value: String) -> void:
	var clean := Mentions.normalize_text(value.strip_escapes())
	if clean.is_empty():
		return
	replace_range(start, end, clean)


func _gui_input(event: InputEvent) -> void:
	if not editable or has_ime_text():
		return
	if event is InputEventMouseButton:
		if event.pressed and event.button_index == MOUSE_BUTTON_MIDDLE and middle_mouse_paste_enabled:
			var column := _column_at(event.position.x)
			_paste_plain(column, column, DisplayServer.clipboard_get_primary())
			accept_event()
		return
	if not event is InputEventKey or not event.pressed:
		return
	remember_selection()
	var actions := {"ui_cut": MENU_CUT, "ui_paste": MENU_PASTE, "ui_undo": MENU_UNDO, "ui_redo": MENU_REDO}
	if shortcut_keys_enabled:
		for action in actions:
			if event.is_action(action, true):
				_menu_action(actions[action])
				accept_event()
				return
	# Copy and navigation must not expand a selection as if deleting it.
	var inserts_text: bool = event.unicode >= 32 and not event.ctrl_pressed and not event.meta_pressed
	var deletes_text: bool = event.keycode == KEY_BACKSPACE or event.keycode == KEY_DELETE
	if not inserts_text and not deletes_text:
		return
	if has_selection():
		var bounds := _expanded(_anchor.x, _anchor.y)
		select(bounds.x, bounds.y)
	elif inserts_text:
		caret_column = _snap(caret_column)
	remember_selection()


func _column_at(x: float) -> int:
	var line := TextLine.new()
	line.add_string(text, get_theme_font("font"), get_theme_font_size("font_size"))
	return _snap(TextServerManager.get_primary_interface().shaped_text_hit_test_position(
		line.get_rid(), x - get_theme_stylebox("normal").get_margin(SIDE_LEFT) - get_scroll_offset()))


func _get_drag_data(_position: Vector2) -> Variant:
	if not has_selection():
		return null
	var bounds := _expanded(get_selection_from_column(), get_selection_to_column())
	select(bounds.x, bounds.y)
	remember_selection()
	var spans: Array[Dictionary] = []
	for value in mentions:
		if int(value.start) >= bounds.x and int(value.start) + int(value.length) <= bounds.y:
			var span := value.duplicate(true)
			span.start = int(span.start) - bounds.x
			spans.append(span)
	var preview := Label.new()
	preview.text = text.substr(bounds.x, bounds.y - bounds.x)
	set_drag_preview(preview)
	return {"chat_draft": get_instance_id(), "revision": revision, "from": bounds.x, "to": bounds.y,
		"text": preview.text, "mentions": spans}


func _can_drop_data(_position: Vector2, data: Variant) -> bool:
	return editable and data is Dictionary and int(data.get("chat_draft", 0)) == get_instance_id() and int(data.get("revision", -1)) == revision


func _drop_data(position: Vector2, data: Variant) -> void:
	if not editable:
		return
	var column := _column_at(position.x)
	if data is String:
		# Let native LineEdit accept external text, but remember semantic intent
		# even when replacing a selection by identical clipboard text.
		var inside := has_selection() and column >= get_selection_from_column() and column <= get_selection_to_column()
		_drop_intent = {"start": get_selection_from_column() if inside else column,
			"end": get_selection_to_column() if inside else column, "text": data}
		return
	if not _can_drop_data(position, data):
		return
	var a := int(data.from)
	var b := int(data.to)
	if column >= a and column <= b:
		deselect()
		return
	var copy := Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_META)
	if copy and _wire_range_length(0, text.length()) + str(Mentions.to_wire(str(data.text), data.mentions).text).length() > Mentions.MAX_TEXT:
		deselect()
		return
	var before := _snapshot()
	if not copy:
		replace_range(a, b, "", [], false)
		if column > b:
			column -= b - a
	replace_range(column, column, str(data.text), data.mentions, false)
	_undo.append(before)
	_redo.clear()
	# Prevent native drag-end cleanup from deleting the newly inserted text.
	deselect()
