@tool
extends "res://cogs/launcher_icon_preview.gd"

const Protocol := preload("res://cogs/multiplayer/server_status_protocol.gd")

class CooldownSector extends Control:
	var remaining_ratio: float = 0.0

	func _draw() -> void:
		if remaining_ratio <= 0.0:
			return
		var center := size * 0.5
		var radius := minf(size.x, size.y) * 0.5
		var points := PackedVector2Array([center])
		var segments := maxi(1, ceili(64.0 * remaining_ratio))
		for index in range(segments + 1):
			var angle := -PI * 0.5 + TAU * remaining_ratio * float(index) / float(segments)
			points.append(center + Vector2(cos(angle), sin(angle)) * radius)
		draw_colored_polygon(points, Color(0.0, 0.0, 0.0, 0.5))

var _sector: CooldownSector


func _ready() -> void:
	super._ready()
	if Engine.is_editor_hint():
		return
	_sector = CooldownSector.new()
	_sector.name = "CooldownSector"
	_sector.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sector.show_behind_parent = true
	add_child(_sector)
	_sector.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func set_remaining_msec(remaining_msec: int) -> void:
	if _sector == null:
		return
	var ratio := clampf(float(remaining_msec) / float(Protocol.COOLDOWN_MSEC), 0.0, 1.0)
	if not is_equal_approx(ratio, _sector.remaining_ratio):
		_sector.remaining_ratio = ratio
		_sector.queue_redraw()
