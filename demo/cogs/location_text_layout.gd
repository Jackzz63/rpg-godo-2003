extends Control

const DESIGN_WIDTH := 320.0

# The common location cap is a root-session budget, including the current UI
# scale once. A player card may have less space after its name/status columns.
static func width_limit(node: Node) -> float:
	var cap := floorf(UiScale.physical_value(DESIGN_WIDTH))
	if node.is_inside_tree():
		cap = minf(cap, floorf(node.get_tree().root.get_visible_rect().size.x * 0.5))
	return maxf(1.0, cap)


var label: RichTextLabel
var _layout_queued := false


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func _ready() -> void:
	UiScale.mark_geometry_physical(self)
	UiScale.mark_geometry_physical(label)
	resized.connect(_queue_layout)
	label.minimum_size_changed.connect(_queue_layout)
	UiScale.scale_changed.connect(_on_scale_changed)
	get_tree().root.size_changed.connect(_queue_layout)
	_queue_layout()


func _on_scale_changed(_scale: float) -> void:
	_queue_layout()


func _queue_layout() -> void:
	if _layout_queued or not is_inside_tree():
		return
	_layout_queued = true
	_layout.call_deferred()


func _layout() -> void:
	_layout_queued = false
	if not is_inside_tree() or not is_instance_valid(label):
		return
	# This Control deliberately reports no minimum width. Reporting the cap as
	# a minimum would enlarge the card and squeeze the status column instead.
	var width := maxf(1.0, minf(size.x, width_limit(self)))
	if not is_equal_approx(label.size.x, width):
		label.size.x = width
	var height := float(label.get_content_height())
	var style := label.get_theme_stylebox("normal")
	if style != null:
		height += style.get_minimum_size().y
	if not is_equal_approx(label.size.y, height):
		label.size.y = height
	if not is_equal_approx(custom_minimum_size.y, height):
		custom_minimum_size.y = height
