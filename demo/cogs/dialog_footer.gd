extends Node
## Opt-in confirmation footers. Callers retain their theme and window layout.
const Spacing := preload("res://cogs/popup_title_spacing.gd")
const Styles := preload("res://cogs/launcher_popup_style.gd")
const Baseline := preload("res://cogs/ui_text_baseline.gd")
const STATES := ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]
var _row: BoxContainer
var _wrap: MarginContainer
var _shared := false
var _measure := false
var _queued := false


static func metrics(font: Font, pixels: int, padding: float, text: String) -> Dictionary:
	var character := font.get_string_size("汉", HORIZONTAL_ALIGNMENT_LEFT, -1, pixels).x
	var horizontal := maxf(padding, ceilf(character * 0.5))
	var line := TextLine.new()
	line.add_string(text, font, pixels)
	# Absorb the half-character rounding so two- and four-character actions
	# share a minimum even at odd physical font sizes.
	var minimum := Vector2(maxf(ceilf(80.0 * pixels / 16.0), ceilf(4 * character + 2 * horizontal)),
		ceilf(32.0 * pixels / 16.0))
	return {"horizontal": horizontal, "vertical": padding,
		"minimum": minimum.max(Vector2(ceilf(line.get_size().x + 2 * horizontal),
			ceilf(maxf(int(font.get_height(pixels)), line.get_size().y) + 2 * padding)))}


static func apply_button(button: Button, padding: float, square := false, source_theme: Theme = null) -> void:
	var font := button.get_theme_font("font")
	var pixels := button.get_theme_font_size("font_size")
	var measured := metrics(font, pixels, padding, button.text)
	var key := [font, pixels, padding, source_theme]
	if button.get_meta(&"dialog_footer_metrics", []) != key:
		button.set_meta(&"dialog_footer_metrics", key)
		button.begin_bulk_theme_override()
		for state: String in STATES:
			# Android replaces its physical theme on resize. Use that fresh frame,
			# rather than retaining a border from the previous scale's override.
			var source := source_theme.get_stylebox(state, "Button") if source_theme != null else button.get_theme_stylebox(state)
			var style := Styles.copy_frame(source)
			style.set_content_margin(SIDE_LEFT, measured.horizontal)
			style.set_content_margin(SIDE_RIGHT, measured.horizontal)
			style.set_content_margin(SIDE_TOP, padding)
			style.set_content_margin(SIDE_BOTTOM, padding)
			button.add_theme_stylebox_override(state, style)
		button.end_bulk_theme_override()
		Baseline.reset_button_styles(button)
	var minimum: Vector2 = measured.minimum
	if square:
		var natural := button.get_minimum_size()
		minimum = Vector2.ONE * maxf(natural.x, natural.y)
	if button.custom_minimum_size != minimum:
		button.custom_minimum_size = minimum
	button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER


static func apply_buttons(row: BoxContainer, padding: float, source_theme: Theme = null) -> void:
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	for child: Node in row.get_children():
		if child is Button:
			apply_button(child, padding, child.get_meta(&"dialog_footer_square", false), source_theme)


static func wrap_row(row: BoxContainer) -> MarginContainer:
	var parent := row.get_parent() as BoxContainer
	var index := row.get_index()
	var margin := MarginContainer.new()
	margin.name = "FooterSpacing"
	for side: String in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 0)
	Spacing.own_constants(margin)
	parent.add_child(margin)
	parent.move_child(margin, index)
	row.reparent(margin)
	return margin


static func set_gap(margin: MarginContainer, gap: int) -> void:
	var box := margin.get_parent() as BoxContainer
	var top := gap - box.get_theme_constant("separation")
	if margin.get_theme_constant("margin_top") != top:
		margin.add_theme_constant_override("margin_top", top)


static func install_shared(row: BoxContainer, common := false, measure := false) -> Node:
	var binding := new()
	binding._row = row
	binding._wrap = wrap_row(row)
	binding._shared = common
	binding._measure = measure
	if measure:
		for child: Node in row.get_children():
			if child is Button:
				UiScale.mark_geometry_physical(child)
				UiScale.mark_styles_physical(child)
	binding._wrap.add_child(binding)
	return binding


func _ready() -> void:
	UiScale.scale_changed.connect(func(_scale: float): _queue_refresh())
	_row.theme_changed.connect(_queue_refresh)
	_queue_refresh()


func _queue_refresh() -> void:
	if not _queued:
		_queued = true
		_refresh.call_deferred()


func _refresh() -> void:
	_queued = false
	var ratio := Spacing.common_padding_ratio if _shared else 1.0
	set_gap(_wrap, UiScale.physical_int(12 * ratio))
	if _measure:
		apply_buttons(_row, UiScale.physical_int(4 * ratio))
	_row.queue_sort()
