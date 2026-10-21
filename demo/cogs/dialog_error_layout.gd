extends Node
## Native AcceptDialog layout for the launcher's two configuration errors.
const Footer := preload("res://cogs/dialog_footer.gd")
var _dialog: AcceptDialog
var _width := 420.0
var _queued := false


static func install(dialog: AcceptDialog, width: float) -> void:
	var binding := new()
	binding._dialog = dialog
	binding._width = width
	dialog.add_child(binding)


func _ready() -> void:
	_dialog.get_label().autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_dialog.about_to_popup.connect(_queue_fit)
	_dialog.get_label().minimum_size_changed.connect(_queue_fit)
	UiScale.scale_changed.connect(func(_scale: float): _queue_fit())
	UiScale.safe_area_changed.connect(_queue_fit)


func _queue_fit() -> void:
	if not _queued and not _dialog.get_meta(UiScale.META_EXTERNAL_SCALE, false):
		_queued = true
		_fit.call_deferred()


func _fit() -> void:
	_queued = false
	if _dialog.visible and not _dialog.get_meta(UiScale.META_EXTERNAL_SCALE, false):
		fit(_dialog, UiScale.physical_int(_width), UiScale.physical_int(4),
			UiScale.physical_int(12), UiScale.physical_int(8), UiScale.physical_int(12))


static func fit(dialog: AcceptDialog, width: int, padding: int, gap: int, bottom: int, edge: int) -> void:
	var button := dialog.get_ok_button()
	UiScale.mark_geometry_physical(button)
	UiScale.mark_styles_physical(button)
	Footer.apply_button(button, padding, false, dialog.theme)
	dialog.add_theme_constant_override("buttons_min_width", ceili(button.custom_minimum_size.x))
	dialog.add_theme_constant_override("buttons_min_height", ceili(button.custom_minimum_size.y))
	dialog.add_theme_constant_override("buttons_separation", gap)
	var panel := dialog.get_theme_stylebox("panel")
	if panel.get_content_margin(SIDE_BOTTOM) != bottom:
		panel = panel.duplicate()
		panel.set_content_margin(SIDE_BOTTOM, bottom)
		dialog.add_theme_stylebox_override("panel", panel)
	var bounds := PopupGeometry.bounds_for(dialog).grow(-edge)
	var edges := Vector4i.ZERO
	if not dialog.borderless and dialog.is_embedded():
		edges.y = dialog.get_theme_constant("title_height", "Window")
		for state: String in ["embedded_border", "embedded_unfocused_border"]:
			var style := dialog.get_theme_stylebox(state, "Window")
			if style is StyleBoxFlat or style is StyleBoxTexture:
				for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
					edges[side] = maxi(edges[side], ceili(style.get_expand_margin(side)))
	var decoration := Vector2i(edges.x + edges.z, edges.y + edges.w)
	dialog.min_size = Vector2i.ZERO
	# Keep the requested width; let the engine measure the wrapped body and footer.
	dialog.size = Vector2i(mini(width, bounds.size.x - decoration.x), 1)
	dialog.position = bounds.position + (bounds.size - dialog.size - decoration) / 2 + Vector2i(edges.x, edges.y)
