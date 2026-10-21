extends RPGMakerPlayer

@export var texture_rect: TextureRect
@export var game_sub_viewport: SubViewport
@export var game_output: TextureRect
@export var chat_text_field: LineEdit

const _STICK_PRESS_THRESHOLD := 0.6
const _STICK_RELEASE_THRESHOLD := 0.4
const _SCALING_NEAREST := 0
const _SCALING_INTEGER := 1
const _SCALING_BILINEAR := 2
const _SCALING_SHARP_PIXEL := 3
const KeyboardMapping := preload("res://cogs/easyrpg_keyboard_mapping.gd")
const JoypadMapping := preload("res://cogs/easyrpg_joypad_mapping.gd")
const SharpPixelShader := preload("res://resources/sharp_pixel.gdshader")

# Maps each physical input source to the EasyRPG key it currently holds.  This
# prevents one source (for example a stick, D-pad, keyboard, or second gamepad)
# from releasing a key that another source is still holding.
var _active_input_sources: Dictionary = {}

# Only sources whose release events depend on this window retaining input focus
# belong here.  Keeping this separate from _active_input_sources lets focus loss
# synthesize the missing keyboard releases without cancelling controller input,
# engine-level virtual presses, or future debug/automation sources.
var _focus_bound_input_sources: Dictionary = {}

# Right-stick X/Y values must be retained as a pair so YNO's eight-way numeric
# mapping can be reproduced. Entries remain device-specific for hot-plug safety.
var _joypad_axis_values: Dictionary = {}
var _shutdown_requested := false
var _game_input_blocked := false
var _game_source_size := Vector2i(320, 240)
var _scaling_mode := _SCALING_SHARP_PIXEL
var _stretch_game := false
var _screen_scale := 100
var _sharp_pixel_material: ShaderMaterial

## Note that _process and _ready functions
## were defined inside gdextension and will
## not work here

func _enter_tree() -> void:
	if not Input.joy_connection_changed.is_connected(_on_joy_connection_changed):
		Input.joy_connection_changed.connect(_on_joy_connection_changed)
	var window := get_window()
	if is_instance_valid(window) and not window.focus_exited.is_connected(_on_window_focus_exited):
		window.focus_exited.connect(_on_window_focus_exited)
	if is_instance_valid(window) and not window.close_requested.is_connected(_on_window_close_requested):
		window.close_requested.connect(_on_window_close_requested)
	var viewport := get_viewport()
	if is_instance_valid(viewport) and not viewport.size_changed.is_connected(_refresh_game_scaling):
		viewport.size_changed.connect(_refresh_game_scaling)
	get_tree().auto_accept_quit = false
	call_deferred("_refresh_game_scaling")


func _exit_tree() -> void:
	if Input.joy_connection_changed.is_connected(_on_joy_connection_changed):
		Input.joy_connection_changed.disconnect(_on_joy_connection_changed)
	var window := get_window()
	if is_instance_valid(window) and window.focus_exited.is_connected(_on_window_focus_exited):
		window.focus_exited.disconnect(_on_window_focus_exited)
	if is_instance_valid(window) and window.close_requested.is_connected(_on_window_close_requested):
		window.close_requested.disconnect(_on_window_close_requested)
	var viewport := get_viewport()
	if is_instance_valid(viewport) and viewport.size_changed.is_connected(_refresh_game_scaling):
		viewport.size_changed.disconnect(_refresh_game_scaling)
	_release_all_input_sources()


func _input(event: InputEvent) -> void:
	var allow_new_press := _accepts_new_game_input()
	if event is InputEventKey:
		_handle_keyboard_event(event as InputEventKey, allow_new_press)
	elif event is InputEventJoypadButton:
		_handle_joypad_button_event(event as InputEventJoypadButton, allow_new_press)
	elif event is InputEventJoypadMotion:
		_handle_joypad_motion_event(event as InputEventJoypadMotion, allow_new_press)


func _physics_process(_delta: float) -> void:
	# Opening chat or stopping the embedded game must also release inputs that
	# are still physically held.  Release events continue to be accepted while
	# blocked, so closing chat never revives an old held state.
	if (not _accepts_new_game_input()) and (
			not _active_input_sources.is_empty() or not _joypad_axis_values.is_empty()):
		_release_all_input_sources()


func _is_chat_input_open() -> bool:
	return is_instance_valid(chat_text_field) and chat_text_field.is_visible_in_tree()


func _accepts_new_game_input() -> bool:
	return is_running() and not _is_chat_input_open() and not _game_input_blocked


func set_touch_input(finger: int, easyrpg_key: int, pressed: bool) -> void:
	_set_input_source(StringName("android-touch:%d" % finger), easyrpg_key,
		pressed and easyrpg_key >= 0 and _accepts_new_game_input(), true)


func set_menu_input(easyrpg_key: int, pressed: bool) -> void:
	_set_input_source(&"android-menu", easyrpg_key,
		pressed and _accepts_new_game_input(), true)


func set_game_input_blocked(blocked: bool) -> void:
	_game_input_blocked = blocked
	if blocked:
		_release_all_input_sources()


func _handle_keyboard_event(event: InputEventKey, allow_new_press: bool) -> void:
	var godot_key := KeyboardMapping.event_keycode(event)
	var easyrpg_key := KeyboardMapping.to_easyrpg_key(godot_key, event.location)
	if easyrpg_key < 0:
		return
	# The physical key and its location stay stable across keyboard layout,
	# modifier, and Num Lock changes, so press/release events share one source.
	var source := KeyboardMapping.event_source(event)
	_set_input_source(
		source,
		easyrpg_key,
		event.pressed and allow_new_press,
		true
	)


func _handle_joypad_button_event(event: InputEventJoypadButton, allow_new_press: bool) -> void:
	var easyrpg_key := JoypadMapping.to_easyrpg_key(event.button_index)
	if easyrpg_key < 0:
		return
	var source := StringName("joypad:%d:button:%d" % [event.device, event.button_index])
	_set_input_source(source, easyrpg_key, event.pressed and allow_new_press)


func _handle_joypad_motion_event(event: InputEventJoypadMotion, allow_new_press: bool) -> void:
	match event.axis:
		JOY_AXIS_LEFT_X:
			_update_stick_direction(
				event.device,
				event.axis,
				"negative",
				JoypadMapping.KEY_LEFT,
				event.axis_value,
				-1.0,
				allow_new_press
			)
			_update_stick_direction(
				event.device,
				event.axis,
				"positive",
				JoypadMapping.KEY_RIGHT,
				event.axis_value,
				1.0,
				allow_new_press
			)
		JOY_AXIS_LEFT_Y:
			_update_stick_direction(
				event.device,
				event.axis,
				"negative",
				JoypadMapping.KEY_UP,
				event.axis_value,
				-1.0,
				allow_new_press
			)
			_update_stick_direction(
				event.device,
				event.axis,
				"positive",
				JoypadMapping.KEY_DOWN,
				event.axis_value,
				1.0,
				allow_new_press
			)
		JOY_AXIS_RIGHT_X, JOY_AXIS_RIGHT_Y:
			_update_right_stick(event, allow_new_press)
		JOY_AXIS_TRIGGER_LEFT, JOY_AXIS_TRIGGER_RIGHT:
			_update_trigger(event, allow_new_press)


func _update_stick_direction(
		device: int,
		axis: JoyAxis,
		direction_name: String,
		easyrpg_key: int,
		axis_value: float,
		direction_sign: float,
		allow_new_press: bool) -> void:
	var source := StringName(
		"joypad:%d:axis:%d:%s" % [device, axis, direction_name]
	)
	var signed_value := axis_value * direction_sign
	var threshold := (
		_STICK_RELEASE_THRESHOLD
		if _active_input_sources.has(source)
		else _STICK_PRESS_THRESHOLD
	)
	_set_input_source(
		source,
		easyrpg_key,
		allow_new_press and signed_value >= threshold
	)


func _update_right_stick(event: InputEventJoypadMotion, allow_new_press: bool) -> void:
	var x_source := _joypad_axis_source(event.device, JOY_AXIS_RIGHT_X)
	var y_source := _joypad_axis_source(event.device, JOY_AXIS_RIGHT_Y)
	var stick_source := StringName("joypad:%d:right-stick" % event.device)
	if not allow_new_press:
		_joypad_axis_values.erase(x_source)
		_joypad_axis_values.erase(y_source)
		_release_input_source(stick_source)
		return

	var axis_source := _joypad_axis_source(event.device, event.axis)
	if is_zero_approx(event.axis_value):
		_joypad_axis_values.erase(axis_source)
	else:
		_joypad_axis_values[axis_source] = event.axis_value

	var x := float(_joypad_axis_values.get(x_source, 0.0))
	var y := float(_joypad_axis_values.get(y_source, 0.0))
	var threshold := (
		_STICK_RELEASE_THRESHOLD
		if _active_input_sources.has(stick_source)
		else _STICK_PRESS_THRESHOLD
	)
	var easyrpg_key := JoypadMapping.right_stick_to_easyrpg_key(x, y, threshold)
	if easyrpg_key < 0:
		_release_input_source(stick_source)
		return
	_set_input_source(stick_source, easyrpg_key, true)


func _update_trigger(event: InputEventJoypadMotion, allow_new_press: bool) -> void:
	var value := clampf(event.axis_value, 0.0, 1.0) if allow_new_press else 0.0
	var full_pressed := value > JoypadMapping.TRIGGER_FULL_THRESHOLD
	var soft_pressed := (
		value > JoypadMapping.TRIGGER_SOFT_THRESHOLD and not full_pressed
	)
	var source_prefix := "joypad:%d:axis:%d:" % [event.device, event.axis]
	_set_input_source(
		StringName(source_prefix + "soft"),
		JoypadMapping.trigger_soft_key(event.axis),
		soft_pressed
	)
	_set_input_source(
		StringName(source_prefix + "full"),
		JoypadMapping.trigger_full_key(event.axis),
		full_pressed
	)


func _joypad_axis_source(device: int, axis: JoyAxis) -> StringName:
	return StringName("joypad:%d:axis-value:%d" % [device, axis])


func _set_input_source(
		source: StringName,
		easyrpg_key: int,
		pressed: bool,
		release_on_focus_loss: bool = false) -> void:
	if pressed:
		if _active_input_sources.has(source):
			if int(_active_input_sources[source]) == easyrpg_key:
				_set_input_source_focus_policy(source, release_on_focus_loss)
				return
			_release_input_source(source)
		var key_was_active := _is_easyrpg_key_active(easyrpg_key)
		_active_input_sources[source] = easyrpg_key
		_set_input_source_focus_policy(source, release_on_focus_loss)
		if not key_was_active:
			_apply_easyrpg_key_state(easyrpg_key, true)
		return
	_release_input_source(source)


func _set_input_source_focus_policy(
		source: StringName,
		release_on_focus_loss: bool) -> void:
	if release_on_focus_loss:
		_focus_bound_input_sources[source] = true
	else:
		_focus_bound_input_sources.erase(source)


func _release_input_source(source: StringName) -> void:
	if not _active_input_sources.has(source):
		_focus_bound_input_sources.erase(source)
		return
	var easyrpg_key := int(_active_input_sources[source])
	_active_input_sources.erase(source)
	_focus_bound_input_sources.erase(source)
	if not _is_easyrpg_key_active(easyrpg_key):
		_apply_easyrpg_key_state(easyrpg_key, false)


func _is_easyrpg_key_active(easyrpg_key: int) -> bool:
	for active_key in _active_input_sources.values():
		if int(active_key) == easyrpg_key:
			return true
	return false


func _release_all_input_sources() -> void:
	var keys_to_release: Dictionary = {}
	for active_key in _active_input_sources.values():
		keys_to_release[int(active_key)] = true
	_active_input_sources.clear()
	_focus_bound_input_sources.clear()
	_joypad_axis_values.clear()
	for easyrpg_key in keys_to_release:
		_apply_easyrpg_key_state(int(easyrpg_key), false)


func _on_window_focus_exited() -> void:
	# Windows can transfer focus before sending key-up to this window. Mirror the
	# synthetic-release policy used by common native game input libraries, but
	# only for sources whose lifecycle is actually tied to window focus.
	var sources_to_release: Array[StringName] = []
	for source in _focus_bound_input_sources:
		sources_to_release.append(source)
	for source in sources_to_release:
		_release_input_source(source)


func is_shutdown_requested() -> bool:
	return _shutdown_requested


func _on_window_close_requested() -> void:
	if _shutdown_requested:
		return
	_shutdown_requested = true
	_release_all_input_sources()
	set_process_input(false)
	set_physics_process(false)
	var chat_overlay := get_node_or_null("../ChatOverlayLayer/ChatControl")
	if is_instance_valid(chat_overlay) and chat_overlay.has_method("prepare_for_shutdown"):
		chat_overlay.call("prepare_for_shutdown")
	var audio_output := get_node_or_null("AudioOutput")
	if is_instance_valid(audio_output) and audio_output.has_method("prepare_for_shutdown"):
		audio_output.call("prepare_for_shutdown")
	if is_running():
		stop_game()
	await get_tree().process_frame
	get_tree().quit()


func _on_joy_connection_changed(device: int, connected: bool) -> void:
	if connected:
		return
	var device_prefix := "joypad:%d:" % device
	var sources_to_release: Array[StringName] = []
	for source in _active_input_sources:
		if str(source).begins_with(device_prefix):
			sources_to_release.append(source)
	for source in sources_to_release:
		_release_input_source(source)
	var axis_values_to_forget: Array[StringName] = []
	for source in _joypad_axis_values:
		if str(source).begins_with(device_prefix):
			axis_values_to_forget.append(source)
	for source in axis_values_to_forget:
		_joypad_axis_values.erase(source)


func _apply_easyrpg_key_state(easyrpg_key: int, pressed: bool) -> void:
	inject_key(easyrpg_key, pressed)

func _on_resolution_changed(width: int, height: int) -> void:
	_game_source_size = Vector2i(width, height)
	_refresh_game_scaling()


func _on_video_settings_changed(
		scaling_mode: int,
		stretch: bool,
		screen_scale: int) -> void:
	_scaling_mode = clampi(scaling_mode, _SCALING_NEAREST, _SCALING_SHARP_PIXEL)
	_stretch_game = stretch
	_screen_scale = clampi(screen_scale, 50, 150)
	_refresh_game_scaling()


static func calculate_game_output(
		window_size: Vector2i,
		source_size: Vector2i,
		scaling_mode: int,
		stretch: bool,
		screen_scale: int) -> Dictionary:
	if window_size.x <= 0 or window_size.y <= 0 \
			or source_size.x <= 0 or source_size.y <= 0:
		return {}

	var clamped_screen_scale := clampi(screen_scale, 50, 150)
	var available_size := Vector2i(
		int(float(window_size.x) * clamped_screen_scale / 100.0),
		int(float(window_size.y) * clamped_screen_scale / 100.0))
	available_size.x = maxi(available_size.x, 1)
	available_size.y = maxi(available_size.y, 1)
	var available_position := Vector2i(
		int((window_size.x - available_size.x) / 2.0),
		int((window_size.y - available_size.y) / 2.0))

	var width_scale := float(available_size.x) / float(source_size.x)
	var height_scale := float(available_size.y) / float(source_size.y)
	var fit_scale := minf(width_scale, height_scale)
	var target_size := Vector2i.ZERO
	if scaling_mode == _SCALING_INTEGER:
		var integer_scale := maxi(1, int(floor(fit_scale)))
		fit_scale = float(integer_scale)
		target_size = source_size * integer_scale
	else:
		target_size = Vector2i(
			clampi(int(floor(float(source_size.x) * fit_scale + 0.0001)), 1, available_size.x),
			clampi(int(floor(float(source_size.y) * fit_scale + 0.0001)), 1, available_size.y))

	var remaining_size := available_size - target_size
	var target_position := available_position + Vector2i(
		remaining_size.x / 2,
		remaining_size.y / 2)
	if stretch:
		target_position.x = available_position.x
		target_size.x = available_size.x

	return {
		"pixel_rect": Rect2(Vector2(target_position), Vector2(target_size)),
		"intermediate_scale": (
			maxi(1, int(ceil(fit_scale)))
			if scaling_mode == _SCALING_BILINEAR
			else 1
		),
	}


func _refresh_game_scaling() -> void:
	if not is_instance_valid(game_output) or not is_instance_valid(game_sub_viewport):
		return
	var window := get_window()
	var viewport := get_viewport()
	if not is_instance_valid(window) or not is_instance_valid(viewport):
		return
	var output := calculate_game_output(
		window.size,
		_game_source_size,
		_scaling_mode,
		_stretch_game,
		_screen_scale)
	if output.is_empty():
		return

	var intermediate_scale := int(output.get("intermediate_scale", 1))
	game_sub_viewport.size = _game_source_size * intermediate_scale
	game_sub_viewport.canvas_item_default_texture_filter = (
		Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST)
	var sharp_pixel_enabled := _scaling_mode == _SCALING_SHARP_PIXEL
	game_output.texture_filter = (
		CanvasItem.TEXTURE_FILTER_LINEAR
		if _scaling_mode == _SCALING_BILINEAR or sharp_pixel_enabled
		else CanvasItem.TEXTURE_FILTER_NEAREST)
	game_output.material = (
		_get_sharp_pixel_material() if sharp_pixel_enabled else null)

	var pixel_rect: Rect2 = output.get("pixel_rect", Rect2())

	game_output.anchor_left = 0.0
	game_output.anchor_top = 0.0
	game_output.anchor_right = 0.0
	game_output.anchor_bottom = 0.0
	game_output.position = pixel_rect.position
	game_output.size = pixel_rect.size
	LimboConsole.set_game_output_rect(pixel_rect)
	game_sub_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func _get_sharp_pixel_material() -> ShaderMaterial:
	if not is_instance_valid(_sharp_pixel_material):
		_sharp_pixel_material = ShaderMaterial.new()
		_sharp_pixel_material.shader = SharpPixelShader
	return _sharp_pixel_material
