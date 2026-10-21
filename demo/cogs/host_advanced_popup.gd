extends Window

signal save_requested(parameters: String)
signal editing_finished()
signal editing_started()

const Parameters := preload("res://cogs/multiplayer/host_parameters.gd")
const Geometry := preload("res://cogs/popup_geometry.gd")

@onready var parameters: TextEdit = %Parameters
@onready var parameters_padding: MarginContainer = %ParametersPadding
@onready var global_preset: CheckBox = %GlobalPreset
@onready var sounds_preset: CheckBox = %SoundsPreset
@onready var error_label: Label = %SaveError

var _editing := false
var _serial := 0
var _padding_queued := false
var launcher_menu: Control


func _ready() -> void:
	preload("res://cogs/input_field_style.gd").install(parameters)
	preload("res://cogs/popup_title_spacing.gd").install($Margin, $Margin/Scroll/Content/Title)
	preload("res://cogs/dialog_footer.gd").install_shared($Margin/Scroll/Content/Actions)
	UiScale.safe_area_changed.connect(_queue_layout)
	close_requested.connect(dismiss)
	%Cancel.pressed.connect(dismiss)
	%Confirm.pressed.connect(_on_confirm)
	parameters.text_changed.connect(_sync_presets)
	global_preset.toggled.connect(_on_preset.bind("global-vars"))
	sounds_preset.toggled.connect(_on_preset.bind("bad-sounds"))
	get_tree().root.size_changed.connect(_queue_layout)
	UiScale.scale_changed.connect(_on_scale_changed)
	$Margin/Scroll/Content.minimum_size_changed.connect(_queue_layout)
	# Capture scene margins as design values before applying physical clearances.
	UiScale.apply_control(parameters_padding)
	parameters.theme_changed.connect(_queue_parameter_padding)
	_update_parameter_padding()


func _exit_tree() -> void:
	if UiScale.scale_changed.is_connected(_on_scale_changed):
		UiScale.scale_changed.disconnect(_on_scale_changed)
	if get_tree().root.size_changed.is_connected(_queue_layout):
		get_tree().root.size_changed.disconnect(_queue_layout)


func open_for_parameters(text: String) -> void:
	_update_parameter_padding()
	_serial += 1
	_editing = true
	editing_started.emit()
	parameters.text = text
	_sync_presets()
	_show_after_layout(_serial)


func is_open_or_opening() -> bool:
	return _editing


func dismiss() -> void:
	var was_editing := _editing
	_serial += 1
	_editing = false
	hide()
	if was_editing:
		editing_finished.emit()


func show_save_error(message: String) -> void:
	error_label.text = message
	error_label.visible = not message.is_empty()
	_queue_layout()


func _sync_presets() -> void:
	var split := Parameters.tokenize(parameters.text)
	var global_enabled := false
	if split.ok:
		for token in split.tokens:
			if token.begins_with("--global-vars=") and token.substr(14).to_lower() == "unconscious":
				global_enabled = true
	global_preset.set_pressed_no_signal(global_enabled)
	sounds_preset.set_pressed_no_signal(split.ok and "--bad-sounds=unconscious" in split.tokens)
	var result := Parameters.parse(parameters.text)
	show_save_error("" if result.ok else result.error)


func _on_preset(enabled: bool, key: String) -> void:
	var result := Parameters.with_preset(parameters.text, key, enabled)
	if result.ok:
		parameters.text = result.text
	_sync_presets()


func _on_confirm() -> void:
	if not _editing:
		return
	var result := Parameters.parse(parameters.text)
	if not result.ok:
		show_save_error(result.error)
		return
	save_requested.emit(parameters.text)


func _show_after_layout(serial: int) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if not _editing or serial != _serial:
		return
	popup(_window_rect())
	_queue_layout()
	parameters.grab_focus()


func _window_rect() -> Rect2i:
	var bounds := Geometry.bounds_for(self)
	var width := launcher_menu.size.x if is_instance_valid(launcher_menu) else UiScale.physical_value(364)
	var height: float = $Margin/Scroll/Content.get_combined_minimum_size().y + $Margin.get_theme_constant("margin_top") + $Margin.get_theme_constant("margin_bottom")
	return Geometry.centered_rect_in_bounds(bounds, Vector2i(ceili(width), ceili(height)),
		Vector2i.ONE, UiScale.physical_int(12))


func _queue_layout() -> void:
	if visible:
		_reflow.call_deferred()


func _reflow() -> void:
	if visible:
		var rect := _window_rect()
		min_size = Vector2i.ZERO
		size = rect.size
		position = rect.position


func _on_scale_changed(_scale: float) -> void:
	_update_parameter_padding()
	_queue_layout()


func _queue_parameter_padding() -> void:
	if not _padding_queued:
		_padding_queued = true
		_update_parameter_padding.call_deferred()


func _update_parameter_padding() -> void:
	_padding_queued = false
	var focus := parameters.get_theme_stylebox("focus")
	var extents := {"margin_left": 0.0, "margin_right": 0.0}
	if focus is StyleBoxFlat or focus is StyleBoxTexture:
		extents.margin_left = focus.get("expand_margin_left")
		extents.margin_right = focus.get("expand_margin_right")
	for margin: String in extents:
		var pixels := maxi(UiScale.physical_int(4), ceili(maxf(0.0, extents[margin])) + 1)
		if parameters_padding.get_theme_constant(margin) != pixels:
			parameters_padding.add_theme_constant_override(margin, pixels)


func _unhandled_key_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		dismiss()
		set_input_as_handled()
