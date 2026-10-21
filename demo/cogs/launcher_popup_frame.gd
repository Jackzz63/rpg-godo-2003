extends StyleBox
## The tiled fill and transparent border are separate drawing passes.
var background: StyleBox:
	set(value):
		var previous := background
		background = value
		_replace_child(previous, value)
var border: StyleBox:
	set(value):
		var previous := border
		border = value
		_replace_child(previous, value)
var right_edge: StyleBox:
	set(value):
		var previous := right_edge
		right_edge = value
		_replace_child(previous, value)
var edge_width := 0.0


func _replace_child(previous: StyleBox, current: StyleBox) -> void:
	if previous != null and previous not in [background, border, right_edge]:
		if previous.changed.is_connected(emit_changed):
			previous.changed.disconnect(emit_changed)
	if current != null and not current.changed.is_connected(emit_changed):
		current.changed.connect(emit_changed)
	emit_changed()


func _draw(canvas_item: RID, rect: Rect2) -> void:
	if background != null:
		background.draw(canvas_item, rect)
	if right_edge != null:
		right_edge.draw(canvas_item, Rect2(rect.end.x - edge_width, rect.position.y, edge_width, rect.size.y))
	elif border != null:
		border.draw(canvas_item, rect)
