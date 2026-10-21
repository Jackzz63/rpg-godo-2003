class_name PopupGeometry
extends RefCounted


static func bounds_for(popup: Window) -> Rect2i:
	if popup.is_embedded():
		var host_viewport := _host_viewport(popup)
		return Rect2i(UiScale.safe_rect_for(host_viewport))
	return DisplayServer.screen_get_usable_rect(popup.current_screen)


static func _host_viewport(popup: Window) -> Viewport:
	# Match the actual embedding viewport, across ordinary Nodes and Windows.
	var ancestor := popup.get_parent()
	while ancestor != null:
		if ancestor is Viewport and ancestor.gui_embed_subwindows:
			return ancestor as Viewport
		ancestor = ancestor.get_parent()
	return popup.get_tree().root


static func control_point(popup: Window, source: Control, local_point: Vector2) -> Vector2:
	return viewport_point(popup, source.get_viewport(), source.get_global_transform_with_canvas() * local_point)


static func viewport_point(popup: Window, source: Viewport, point: Vector2) -> Vector2:
	var screen_point := source.get_screen_transform() * point
	if popup.is_embedded():
		screen_point = _host_viewport(popup).get_screen_transform().affine_inverse() * screen_point
	else:
		# Viewport.get_screen_transform omits the outer native window origin.
		var native_window := source.get_window()
		while native_window.is_embedded():
			native_window = native_window.get_parent().get_window()
		screen_point += Vector2(native_window.position)
	return screen_point


static func centered_rect(
	popup: PopupPanel,
	desired_size: Vector2i,
	minimum_size: Vector2i = Vector2i(1, 1),
	edge_margin: int = 0
) -> Rect2i:
	return centered_rect_in_bounds(
		bounds_for(popup), desired_size, minimum_size, edge_margin)


static func centered_rect_in_bounds(
	bounds: Rect2i,
	desired_size: Vector2i,
	minimum_size: Vector2i = Vector2i(1, 1),
	edge_margin: int = 0
) -> Rect2i:
	var inner := _inset_bounds(bounds, edge_margin)
	var target := _fit_size(desired_size, minimum_size, inner.size)
	var remainder := inner.size - target
	return Rect2i(
		inner.position + Vector2i(
			floori(float(remainder.x) * 0.5),
			floori(float(remainder.y) * 0.5)),
		target)


static func anchored_rect(
	popup: Window,
	desired_size: Vector2i,
	requested_position: Vector2i,
	edge_margin: int = 0,
	minimum_size: Vector2i = Vector2i(1, 1)
) -> Rect2i:
	return anchored_rect_in_bounds(
		bounds_for(popup), desired_size, requested_position,
		edge_margin, minimum_size)


static func anchored_rect_in_bounds(
	bounds: Rect2i,
	desired_size: Vector2i,
	requested_position: Vector2i,
	edge_margin: int = 0,
	minimum_size: Vector2i = Vector2i(1, 1)
) -> Rect2i:
	var inner := _inset_bounds(bounds, edge_margin)
	var target := _fit_size(desired_size, minimum_size, inner.size)
	var maximum := inner.end - target
	var position := Vector2i(
		clampi(requested_position.x, inner.position.x, maximum.x),
		clampi(requested_position.y, inner.position.y, maximum.y))
	return Rect2i(position, target)


static func anchor_ratio(popup: PopupPanel, position: Vector2i) -> Vector2:
	var bounds := bounds_for(popup)
	if bounds.size.x <= 0 or bounds.size.y <= 0:
		return Vector2.ZERO
	return Vector2(
		float(position.x - bounds.position.x) / float(bounds.size.x),
		float(position.y - bounds.position.y) / float(bounds.size.y))


static func anchor_from_ratio(popup: PopupPanel, ratio: Vector2) -> Vector2i:
	var bounds := bounds_for(popup)
	return bounds.position + Vector2i(
		roundi(clampf(ratio.x, 0.0, 1.0) * float(bounds.size.x)),
		roundi(clampf(ratio.y, 0.0, 1.0) * float(bounds.size.y)))


static func content_minimum_size(popup: PopupPanel) -> Vector2i:
	var minimum := Vector2.ZERO
	for child in popup.get_children():
		if child is Control and child.name != &"__SystemUISkin":
			var child_minimum := (child as Control).get_combined_minimum_size()
			minimum.x = maxf(minimum.x, child_minimum.x)
			minimum.y = maxf(minimum.y, child_minimum.y)
	return Vector2i(maxi(1, ceili(minimum.x)), maxi(1, ceili(minimum.y)))


static func apply_rect(popup: Window, rect: Rect2i) -> void:
	popup.min_size = Vector2i.ZERO
	popup.size = rect.size
	popup.position = rect.position


static func _inset_bounds(bounds: Rect2i, edge_margin: int) -> Rect2i:
	var margin := maxi(0, edge_margin)
	var inset_x := mini(
		margin, maxi(0, floori(float(bounds.size.x - 1) * 0.5)))
	var inset_y := mini(
		margin, maxi(0, floori(float(bounds.size.y - 1) * 0.5)))
	return Rect2i(
		bounds.position + Vector2i(inset_x, inset_y),
		Vector2i(
			maxi(1, bounds.size.x - inset_x * 2),
			maxi(1, bounds.size.y - inset_y * 2)))


static func _fit_size(
	desired_size: Vector2i,
	minimum_size: Vector2i,
	available_size: Vector2i
) -> Vector2i:
	var available := Vector2i(
		maxi(1, available_size.x), maxi(1, available_size.y))
	var minimum := Vector2i(
		clampi(minimum_size.x, 1, available.x),
		clampi(minimum_size.y, 1, available.y))
	return Vector2i(
		clampi(desired_size.x, minimum.x, available.x),
		clampi(desired_size.y, minimum.y, available.y))
