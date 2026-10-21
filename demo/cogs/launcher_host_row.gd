@tool
extends Control
## Pure layout shared by the editor preview and the launcher's physical UI layout.

var _layout_queued := false


func _ready() -> void:
	if Engine.is_editor_hint():
		(%MpEnable.get_parent() as Container).sort_children.connect(_queue_editor_layout)
		resized.connect(_queue_editor_layout)
		_queue_editor_layout()


func _queue_editor_layout() -> void:
	if _layout_queued:
		return
	_layout_queued = true
	_update_editor_layout.call_deferred()


func _update_editor_layout() -> void:
	_layout_queued = false
	if is_inside_tree():
		layout_at_scale(1.0)


func layout_at_scale(ui_scale: float) -> void:
	var checkbox := $MpServer as CheckBox
	var reference := %MpEnable as CheckBox
	var label_column := $VBoxContainer as Control
	var title := %MpUrl.get_parent().get_node("RichTextLabel") as Control
	var gear := $HostAdvancedButton as Button
	var title_x := title.global_position.x - global_position.x
	var checkbox_x := reference.global_position.x - global_position.x
	checkbox.size = reference.size
	checkbox.position = Vector2(checkbox_x, (size.y - checkbox.size.y) * 0.5)
	label_column.position = Vector2(title_x, 0)
	label_column.size = Vector2(checkbox_x - title_x - 8.0 * ui_scale, size.y)
	var button_size := Vector2(roundf(32 * ui_scale), roundf(32 * ui_scale))
	gear.size = button_size
	# Preserve separate visible frames and input rectangles.
	var gap := minf(8.0 * ui_scale, button_size.x / 3.0)
	gear.position = Vector2(checkbox_x + checkbox.size.x + gap, (size.y - button_size.y) * 0.5)
