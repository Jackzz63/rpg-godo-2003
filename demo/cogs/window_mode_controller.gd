class_name WindowModeController
extends Node

const KeyboardMapping := preload("res://cogs/easyrpg_keyboard_mapping.gd")
const ShortcutRelay := preload("res://cogs/window_shortcut_relay.gd")
const TOOLTIP := "全屏"

var _desktop_enabled := false
var _previous_mode := Window.MODE_WINDOWED
# Keep ownership through modifier changes, focus changes and game returns.
# A fresh non-echo press also recovers from a key-up lost outside the app.
var _consumed_sources: Dictionary = {}
var _relays: Array[Node] = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if _desktop_enabled:
		_watch_windows(get_tree().root)
		get_tree().node_added.connect(_on_node_added)


func _exit_tree() -> void:
	if get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)
	for relay in _relays:
		if is_instance_valid(relay):
			relay.queue_free()


func apply_desktop_startup_default() -> void:
	_desktop_enabled = OS.get_name() in ["Windows", "Linux"] \
		and DisplayServer.get_name() != "headless"
	if _desktop_enabled:
		get_tree().root.mode = Window.MODE_WINDOWED


func desktop_controls_enabled() -> bool:
	return _desktop_enabled


func is_fullscreen() -> bool:
	return get_tree().root.mode in [Window.MODE_FULLSCREEN, Window.MODE_EXCLUSIVE_FULLSCREEN]


func toggle_fullscreen() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var window := get_tree().root
	if is_fullscreen():
		window.mode = _previous_mode
	else:
		_previous_mode = Window.MODE_MAXIMIZED if window.mode == Window.MODE_MAXIMIZED \
			else Window.MODE_WINDOWED
		window.mode = Window.MODE_FULLSCREEN


func _input(event: InputEvent) -> void:
	handle_shortcut(event, get_viewport())


func handle_shortcut(event: InputEvent, receiver: Viewport) -> void:
	var key := event as InputEventKey
	if key == null:
		return
	var source := KeyboardMapping.event_source(key)
	if _consumed_sources.has(source):
		if not key.pressed or key.echo:
			receiver.set_input_as_handled()
			if not key.pressed:
				_consumed_sources.erase(source)
			return
		_consumed_sources.erase(source)
	if not _desktop_enabled or not key.pressed or key.echo:
		return
	if key.ctrl_pressed or key.shift_pressed or key.meta_pressed:
		return
	var code := KeyboardMapping.event_keycode(key)
	var requested := (code == KEY_F4 and not key.alt_pressed) \
		or (code in [KEY_ENTER, KEY_KP_ENTER] and key.alt_pressed)
	if not requested:
		return
	_consumed_sources[source] = true
	receiver.set_input_as_handled()
	# PopupMenu handles ui_accept before Node._input. Close the transient menu
	# chain so Enter echoes after releasing Alt cannot confirm a menu item.
	var ancestor: Node = receiver
	while ancestor != null:
		if ancestor is PopupMenu:
			(ancestor as PopupMenu).hide()
		ancestor = ancestor.get_parent()
	toggle_fullscreen()


func _watch_windows(node: Node) -> void:
	if node is Window:
		_install_window_relay(node as Window)
	for child in node.get_children():
		_watch_windows(child)


func _on_node_added(node: Node) -> void:
	if node is Window:
		_install_window_relay.call_deferred(node)


func _install_window_relay(window: Window) -> void:
	if not is_instance_valid(window) or window == get_tree().root \
			or window.is_queued_for_deletion() or window.unfocusable:
		return
	for child in window.get_children():
		if child.get_script() == ShortcutRelay:
			return
	var relay := ShortcutRelay.new()
	relay.name = "WindowFullscreenShortcut"
	relay.controller = self
	window.add_child(relay)
	_relays.append(relay)
