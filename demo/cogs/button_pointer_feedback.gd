extends Node
## Preserve selection/focus, but do not leave a mouse hover/held border behind
## after a finger has lifted. A real mouse or keyboard restores native feedback.
const META := &"button_pointer_feedback"
const STATES := ["hover", "pressed", "hover_pressed", "focus"]
var button: Button
var _touch := false
var _held := false
var _updating := false
var _original: Dictionary = {}
var _resolved: Dictionary = {}
var _applied: Dictionary = {}
var _empty := StyleBoxEmpty.new()


static func install_tree(node: Node) -> void:
	if node is Button:
		install(node)
	for child: Node in node.get_children():
		install_tree(child)


static func install(owner: Button) -> void:
	if owner.has_meta(META):
		return
	var adapter := new()
	adapter.button = owner
	owner.set_meta(META, adapter)
	owner.add_child(adapter)


static func restore_focus(owner: Button, keyboard: bool) -> void:
	# A keyboard activation may have happened in a different child Window.
	# Keep this opt-in: ordinary buttons retain their existing input feedback.
	if keyboard and owner.has_meta(META):
		var adapter: Node = owner.get_meta(META)
		adapter._touch = false
		adapter._held = false
		adapter._refresh()
	owner.grab_focus(not keyboard)


func _ready() -> void:
	button.get_window().window_input.connect(_pointer)
	button.button_down.connect(func():
		_held = true
		_refresh())
	button.button_up.connect(func():
		_held = false
		_refresh())
	button.theme_changed.connect(_theme_changed)


func _pointer(event: InputEvent) -> void:
	if event is InputEventScreenTouch or (event is InputEventMouse and event.device < 0):
		_touch = true
		if (event is InputEventScreenTouch or event is InputEventMouseButton) and not event.pressed:
			_held = false
	elif (event is InputEventMouse and event.device >= 0) or event is InputEventKey:
		_touch = false
	else:
		return
	_refresh()


func _theme_changed() -> void:
	if not _updating:
		for state: String in _applied:
			if button.get_theme_stylebox(state) != _applied[state]:
				_original[state] = button.get_theme_stylebox(state) if button.has_theme_stylebox_override(state) else null
		_restore()
		_refresh()


func _restore() -> void:
	_updating = true
	for state: String in _original:
		if _original[state] == null:
			button.remove_theme_stylebox_override(state)
		else:
			button.add_theme_stylebox_override(state, _original[state])
	_original.clear()
	_resolved.clear()
	_applied.clear()
	_updating = false


func _refresh() -> void:
	if _updating:
		return
	if not _touch:
		if not _original.is_empty(): _restore()
		return
	_updating = true
	var normal := button.get_theme_stylebox("normal")
	for state: String in STATES:
		if not _original.has(state):
			_original[state] = button.get_theme_stylebox(state) if button.has_theme_stylebox_override(state) else null
			_resolved[state] = button.get_theme_stylebox(state)
		var style: StyleBox = normal
		if state == "focus":
			style = _empty
		elif _held and state in ["pressed", "hover_pressed"]:
			style = _resolved[state]
		_applied[state] = style
		if button.get_theme_stylebox(state) != style:
			button.add_theme_stylebox_override(state, style)
	_updating = false
