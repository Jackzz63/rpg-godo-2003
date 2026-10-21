extends Window

signal save_requested(endpoint: String, credential: String)
signal editing_started()
signal editing_finished()

const PopupGeometryScript := preload("res://cogs/popup_geometry.gd")

@onready var credential: LineEdit = $Margin/Content/CredentialRow/AdminCredential
@onready var visibility_button: Button = $Margin/Content/CredentialRow/AdminCredentialVisibility
@onready var error_label: Label = $Margin/Content/SaveError

var endpoint: String = ""
var _layout_serial: int = 0


func _ready() -> void:
	preload("res://cogs/popup_title_spacing.gd").install($Margin, $Margin/Content/Title)
	UiScale.safe_area_changed.connect(_queue_layout)
	transparent_bg = true
	add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	$Margin/Content/Actions/Save.pressed.connect(_on_save_pressed)
	$Margin/Content/Actions/Cancel.pressed.connect(dismiss)
	preload("res://cogs/dialog_footer.gd").install_shared($Margin/Content/Actions)
	close_requested.connect(dismiss)
	get_tree().root.size_changed.connect(_queue_layout)
	UiScale.scale_changed.connect(_on_scale_changed)
	$Margin/Content.minimum_size_changed.connect(_queue_layout)


func open_for_endpoint(server_endpoint: String, saved_credential: String) -> void:
	endpoint = server_endpoint
	editing_started.emit()
	credential.text = saved_credential
	visibility_button.button_pressed = false
	credential.secret = true
	error_label.hide()
	_layout_serial += 1
	_show_after_layout(_layout_serial)


func is_open_or_opening() -> bool:
	return not endpoint.is_empty()


func dismiss() -> void:
	var was_editing := is_open_or_opening()
	_layout_serial += 1
	endpoint = ""
	credential.text = ""
	visibility_button.button_pressed = false
	credential.secret = true
	hide()
	if was_editing:
		editing_finished.emit()


func show_save_error(message: String) -> void:
	error_label.text = "保存失败：%s" % message
	error_label.show()
	_queue_layout()


func _on_save_pressed() -> void:
	if not endpoint.is_empty():
		save_requested.emit(endpoint, credential.text)


func _popup_rect() -> Rect2i:
	var content: Vector2 = $Margin.get_combined_minimum_size()
	var desired := Vector2i(ceili(maxf(UiScale.physical_value(276), content.x)), ceili(content.y))
	var bounds := PopupGeometryScript.bounds_for(self)
	return PopupGeometryScript.centered_rect_in_bounds(bounds, desired, Vector2i.ONE, UiScale.physical_int(12))


func _show_after_layout(serial: int) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if serial != _layout_serial or endpoint.is_empty():
		return
	popup(_popup_rect())
	credential.grab_focus()
	credential.caret_column = credential.text.length()
	_queue_layout()


func _queue_layout() -> void:
	if not visible:
		return
	_layout_serial += 1
	_reflow_after_layout(_layout_serial)


func _reflow_after_layout(serial: int) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if visible and serial == _layout_serial:
		var rect := _popup_rect()
		min_size = Vector2i.ZERO
		size = rect.size
		position = rect.position


func _on_scale_changed(_scale: float) -> void:
	_queue_layout()


func _input(event: InputEvent) -> void:
	# LineEdit consumes ui_cancel to leave editing. This modal's Escape contract
	# is Cancel, so handle it before the credential editor consumes the key.
	if visible and event.is_action_pressed("ui_cancel"):
		dismiss()
		set_input_as_handled()
