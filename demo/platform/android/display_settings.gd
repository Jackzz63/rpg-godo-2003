extends Node

signal geometry_changed()
signal preferences_changed()

const CONFIG_PATH := "user://android_display.cfg"
const LAUNCHER_MULTIPLIER := 1.20
const GAME_MULTIPLIER := 1.50
# Values are Activity orientation requests, distinct from the actual rotation.
const ORIENTATION_NAMES := ["横屏", "反向横屏", "竖屏", "反向竖屏", "自动（重力感应）"]

var plugin: Object
var config_path := CONFIG_PATH
var preferences := defaults()
var actual_rotation := 0
var in_game := false
var _snapshot: Dictionary = {}
var _display: Dictionary = {}
var view_rect := Rect2() # The editor stays fixed while the user moves UI margins.
var _layout_queued := false
var _last_requested := -1
var _orientation_preview := -1


static func defaults() -> Dictionary:
	return {"orientation": 0, "ui_scale": 1.0,
		"left": [-1.0, -1.0, -1.0, -1.0], "right": [-1.0, -1.0, -1.0, -1.0],
		"top": [-1.0, -1.0, -1.0, -1.0], "bottom": [-1.0, -1.0, -1.0, -1.0]}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	UiScale.set_orientation_independent(true)
	var config := ConfigFile.new()
	if config.load(config_path) == OK:
		preferences.orientation = clampi(int(config.get_value("display", "orientation", 0)), 0, 4)
		preferences.ui_scale = clampf(float(config.get_value("display", "ui_scale", 1.0)), 0.60, 1.50)
		for side in ["left", "right", "top", "bottom"]:
			var values: Variant = config.get_value("display", side, [])
			if values is Array and values.size() == 4:
				for index in 4:
					var value := float(values[index])
					preferences[side][index] = -1.0 if value < 0 else clampf(value, 0.0, 0.20)
	get_tree().root.size_changed.connect(queue_geometry)
	if plugin != null and plugin.has_signal("display_changed"):
		plugin.connect("display_changed", _receive_display, CONNECT_DEFERRED)
	_apply_preferences()
	request_display()
	queue_geometry()


func _exit_tree() -> void:
	if plugin != null and plugin.has_signal("display_changed") and plugin.is_connected("display_changed", _receive_display):
		plugin.disconnect("display_changed", _receive_display)
	UiScale.set_safe_area(Rect2())
	UiScale.set_corner_top_insets(Vector2.ZERO)
	UiScale.set_interface_multiplier(1.0)
	UiScale.set_orientation_independent(false)


func request_display() -> void:
	if _has_plugin_method("requestDisplayState"):
		plugin.call("requestDisplayState")


func _has_plugin_method(method: String) -> bool:
	if plugin == null:
		return false
	if plugin.has_method("has_java_method"):
		return bool(plugin.call("has_java_method", method))
	return plugin.has_method(method)


func _receive_display(json: String) -> void:
	var value: Variant = JSON.parse_string(json)
	if value is Dictionary:
		_display = value
		queue_geometry()


func begin_edit() -> void:
	_snapshot = preferences.duplicate(true)


func cancel_edit() -> void:
	if _snapshot.is_empty():
		return
	preferences = _snapshot
	_snapshot = {}
	_apply_preferences()


func save_edit() -> Error:
	var config := ConfigFile.new()
	for key: String in preferences:
		config.set_value("display", key, preferences[key])
	var error := config.save(config_path)
	if error == OK:
		_snapshot = {}
	return error


func restore_defaults() -> void:
	preferences = defaults()
	_apply_preferences()


func set_game_active(value: bool) -> void:
	in_game = value
	_apply_preferences()


func set_orientation(value: int) -> void:
	preferences.orientation = clampi(value, 0, 4)
	_apply_preferences()


func preview_orientation(value: int) -> void:
	# Layout editing borrows the display request, never the saved preference.
	_orientation_preview = clampi(value, 0, 4)
	_apply_preferences()


func end_orientation_preview() -> void:
	_orientation_preview = -1
	_apply_preferences()


func set_ui_scale(value: float) -> void:
	preferences.ui_scale = clampf(value, 0.60, 1.50)
	_apply_preferences()


func set_margin(side: String, fraction: float) -> void:
	preferences[side][actual_rotation] = clampf(fraction, 0.0, 0.20)
	queue_geometry()


func margin_fraction(side: String) -> float:
	var saved := float(preferences[side][actual_rotation])
	if saved >= 0:
		return saved
	# Half the 20-unit HUD icon at the default game scale. User text scaling
	# cannot reduce the protection needed for the screen's physical corners.
	var viewport_size := get_tree().root.size
	var extent := viewport_size.y if side in ["top", "bottom"] else viewport_size.x
	return 10.0 * GAME_MULTIPLIER * UiScale.scale_for_size(viewport_size) / maxf(1.0, extent)


func margin_sides() -> PackedStringArray:
	var viewport_size := get_tree().root.size
	return PackedStringArray(["top", "bottom"] if viewport_size.y > viewport_size.x else ["left", "right"])


func _apply_preferences() -> void:
	UiScale.set_interface_multiplier(GAME_MULTIPLIER * float(preferences.ui_scale) if in_game else LAUNCHER_MULTIPLIER)
	var mode := _orientation_preview if _orientation_preview >= 0 else int(preferences.orientation)
	if _last_requested != mode:
		_last_requested = mode
		if _has_plugin_method("setDisplayOrientation"):
			plugin.call("setDisplayOrientation", mode)
	preferences_changed.emit()
	queue_geometry()


func queue_geometry() -> void:
	if _layout_queued:
		return
	_layout_queued = true
	_update_geometry.call_deferred()


func _update_geometry() -> void:
	_layout_queued = false
	var viewport_size := Vector2(get_tree().root.size)
	view_rect = Rect2(Vector2.ZERO, viewport_size)
	if not _display.is_empty():
		var reported := Vector2(float(_display.get("width", 0)), float(_display.get("height", 0)))
		# A rotation request and the render viewport resize arrive separately.
		# Never relabel old geometry with a new portrait/landscape calibration.
		if reported.x > 0 and reported.y > 0 and (reported.x > reported.y) == (viewport_size.x > viewport_size.y):
			actual_rotation = clampi(int(_display.get("rotation", 0)), 0, 3)
	var calibrated: Rect2
	if viewport_size.y > viewport_size.x:
		var top := viewport_size.y * margin_fraction("top")
		var bottom := viewport_size.y * margin_fraction("bottom")
		# Portrait already clears the top through the safe rectangle.
		UiScale.set_corner_top_insets(Vector2.ZERO)
		calibrated = Rect2(Vector2(0, top), Vector2(viewport_size.x, viewport_size.y - top - bottom))
	else:
		var left := viewport_size.x * margin_fraction("left")
		var right := viewport_size.x * margin_fraction("right")
		UiScale.set_corner_top_insets(Vector2(
			left if float(preferences.left[actual_rotation]) < 0 else 0.0,
			right if float(preferences.right[actual_rotation]) < 0 else 0.0))
		calibrated = Rect2(Vector2(left, 0), Vector2(viewport_size.x - left - right, viewport_size.y))
	UiScale.set_safe_area(calibrated)
	# Emit even at identical dimensions: a 180-degree turn changes the profile
	# and must release held touches before accepting new coordinates.
	geometry_changed.emit()
