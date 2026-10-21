extends RefCounted
## Opt-in alignment for single-line UI fragments. No font or horizontal layout changes.

const _METRICS := &"ui_text_baseline_metrics"
const _STYLES := &"ui_text_baseline_styles"
const _STYLE_KEY := &"ui_text_baseline_style_key"
const _STATES := ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]


static func install(row: HBoxContainer, chat_line: bool = false) -> void:
	var callback := _align_row.bind(row, chat_line)
	if not row.sort_children.is_connected(callback):
		row.sort_children.connect(callback)
	if chat_line:
		row.set_meta("chat_baseline_row", true)
	row.queue_sort()


static func install_buttons(row: HBoxContainer) -> void:
	var callback := _align_buttons.bind(row)
	if not row.sort_children.is_connected(callback):
		row.sort_children.connect(callback)
	row.queue_sort()


static func install_caption_peer(row: HBoxContainer, caption: RichTextLabel, peer: Button) -> void:
	# Native selectors keep their own text, arrows, styles and input geometry.
	# Align only the adjacent decorative caption to their shaped text baseline.
	var callback := _align_caption_peer.bind(row, caption, peer)
	if not row.sort_children.is_connected(callback):
		row.sort_children.connect(callback)
	row.queue_sort()


static func _align_caption_peer(row: HBoxContainer, caption: RichTextLabel, peer: Button) -> void:
	_watch(caption, row)
	_watch(peer, row)
	var metrics := _metrics(peer)
	var style := peer.get_theme_stylebox("normal")
	var top := style.get_margin(SIDE_TOP)
	var bottom := style.get_margin(SIDE_BOTTOM)
	var baseline := peer.position.y + top \
		+ (peer.size.y - top - bottom - float(metrics.shaped_height)) * 0.5 + float(metrics.ascent)
	caption.position.y = baseline - float(_metrics(caption).ascent)


static func centered_label_offset_from_caption(label: Label, caption: RichTextLabel) -> float:
	# Launcher-only contract: single-line plain text, native vertical centering.
	# RichTextLabel centers its integer content height; Label pads the shaped line
	# to the integer font height and truncates its centering offset toward zero.
	var caption_style := caption.get_theme_stylebox("normal")
	var caption_height := caption.size.y - caption_style.get_minimum_size().y
	var caption_baseline := caption_style.get_offset().y \
		+ maxf(0.0, caption_height - caption.get_content_height()) * 0.5 \
		+ float(_metrics(caption).ascent)
	var target := (label.get_parent() as Control).get_global_transform().affine_inverse() \
		* (caption.get_global_transform() * Vector2(0.0, caption_baseline))
	var metrics := _metrics(label)
	var style := label.get_theme_stylebox("normal")
	var height := maxf(float(metrics.font_height), float(metrics.shaped_height))
	var top := int((label.size.y - style.get_minimum_size().y - height) * 0.5)
	return target.y - style.get_offset().y - top - float(metrics.label_baseline)


static func _metrics(control: Control) -> Dictionary:
	var rich := control is RichTextLabel
	var font := control.get_theme_font("normal_font" if rich else "font")
	var pixels := control.get_theme_font_size("normal_font_size" if rich else "font_size")
	var value: String = (
		(control as RichTextLabel).get_parsed_text()
		if rich else str(control.get("text"))
	)
	var language := str(control.get("language"))
	var direction := int(control.get("text_direction"))
	var key := [font, pixels, value, language, direction, control.is_layout_rtl()]
	var cached: Dictionary = control.get_meta(_METRICS, {})
	if cached.get("key", []) == key:
		return cached
	var line := TextLine.new()
	match direction:
		Control.TEXT_DIRECTION_LTR:
			line.direction = TextServer.DIRECTION_LTR
		Control.TEXT_DIRECTION_RTL:
			line.direction = TextServer.DIRECTION_RTL
		Control.TEXT_DIRECTION_INHERITED:
			line.direction = TextServer.DIRECTION_RTL if control.is_layout_rtl() else TextServer.DIRECTION_LTR
		_:
			line.direction = TextServer.DIRECTION_AUTO
	line.add_string(value, font, pixels, language)
	var ascent := line.get_line_ascent()
	var height := line.get_size().y
	var reference := TextLine.new()
	reference.add_string("Ag", font, pixels, language)
	# Label pads each shaped line to the integer font-chain height. RichTextLabel
	# and Button use the shaped height instead. A stable primary-font reference
	# also aligns separate tab buttons, independent of which tab is selected.
	var font_height := float(int(font.get_height(pixels)))
	cached = {
		"key": key,
		"font_height": font_height,
		"shaped_height": height,
		"ascent": ascent,
		"label_baseline": ascent + maxf(0.0, font_height - height) * 0.5,
		"reference_baseline": reference.get_line_ascent() + maxf(
			0.0, font_height - reference.get_size().y) * 0.5,
		"button_delta": (reference.get_line_ascent() - reference.get_size().y * 0.5)
			- (ascent - height * 0.5),
	}
	control.set_meta(_METRICS, cached)
	return cached


static func _watch(control: Control, row: HBoxContainer) -> void:
	if not control.theme_changed.is_connected(row.queue_sort):
		control.theme_changed.connect(row.queue_sort)


static func _align_row(row: HBoxContainer, chat_line: bool) -> void:
	# sort_children is emitted AFTER the native HBox placement, before drawing.
	# Assign an absolute Y, not an accumulated offset. Keep size and local shader
	# coordinates unchanged; this leaves gradient sampling and X hit areas intact.
	for child in row.get_children():
		if not (child is Label or child is RichTextLabel) or not child.visible:
			continue
		var control := child as Control
		_watch(control, row)
		var metrics := _metrics(control)
		var top := 0.0 if chat_line else floorf(
			(row.size.y - float(metrics.font_height)) * 0.5)
		var baseline := top + float(metrics.reference_baseline)
		var own_baseline := float(metrics.ascent if control is RichTextLabel else metrics.label_baseline)
		control.position.y = baseline - own_baseline


static func reset_button_styles(button: Button) -> void:
	# A footer may replace its physical padding after a font/scale change.
	# Capture that new padding before applying the baseline-only correction.
	button.remove_meta(_STYLES)
	button.remove_meta(_STYLE_KEY)


static func _align_buttons(row: HBoxContainer) -> void:
	for child in row.get_children():
		if not child is Button:
			continue
		var button := child as Button
		_watch(button, row)
		var scale := UiScale.physical_value(1.0)
		var metrics := _metrics(button)
		var key: Array = [metrics.key, scale]
		if button.get_meta(_STYLE_KEY, []) == key:
			continue
		var styles: Dictionary = button.get_meta(_STYLES, {})
		if styles.is_empty():
			for state: String in _STATES:
				var original := button.get_theme_stylebox(state).duplicate() as StyleBox
				for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
					original.set_content_margin(side, original.get_content_margin(side) / scale)
				styles[state] = original
			button.set_meta(_STYLES, styles)
		# Only these two opt-in text buttons own their scaled content margins.
		# The sum of top/bottom margins, all X margins, and native input stay intact.
		UiScale.mark_styles_physical(button)
		button.set_meta(_STYLE_KEY, key)
		var delta := float(metrics.button_delta)
		button.begin_bulk_theme_override()
		for state: String in _STATES:
			var style := (styles[state] as StyleBox).duplicate() as StyleBox
			for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
				style.set_content_margin(side, style.get_content_margin(side) * scale)
			style.content_margin_top += delta
			style.content_margin_bottom -= delta
			button.add_theme_stylebox_override(state, style)
		button.end_bulk_theme_override()
