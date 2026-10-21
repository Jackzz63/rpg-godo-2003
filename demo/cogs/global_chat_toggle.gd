class_name GlobalChatToggle
extends Button

const _CIRCLE_COLOR := Color(1.0, 0.0, 1.0, 1.0)
const _CIRCLE_WIDTH := 1.0
const _CIRCLE_SEGMENTS := 40

var _cooldown_duration_msec: int = 0
var _cooldown_ends_at_msec: int = 0
var _cooldown_source: Callable


func _ready() -> void:
	focus_mode = Control.FOCUS_NONE
	_update_process_state()


func set_cooldown_source(source: Callable) -> void:
	_cooldown_source = source
	_update_process_state()
	_sync_cooldown_source()
	queue_redraw()


func _sync_cooldown_source() -> void:
	if not _cooldown_source.is_valid():
		return
	var snapshot: Array = _cooldown_source.call()
	_cooldown_ends_at_msec = int(snapshot[0])
	_cooldown_duration_msec = int(snapshot[1])


func start_cooldown(duration_seconds: float) -> void:
	_cooldown_duration_msec = maxi(1, roundi(duration_seconds * 1000.0))
	_cooldown_ends_at_msec = Time.get_ticks_msec() + _cooldown_duration_msec
	_update_process_state()
	queue_redraw()


func clear_cooldown() -> void:
	_cooldown_duration_msec = 0
	_cooldown_ends_at_msec = 0
	_update_process_state()
	queue_redraw()


func _process(_delta: float) -> void:
	_sync_cooldown_source()
	var now := Time.get_ticks_msec()
	if _cooldown_duration_msec > 0 and now >= _cooldown_ends_at_msec:
		_cooldown_duration_msec = 0
		_cooldown_ends_at_msec = 0
	_update_process_state()
	queue_redraw()


func _draw() -> void:
	var ratio := _remaining_ratio()
	if ratio <= 0.0:
		return
	var center := size * 0.5
	var radius := maxf(2.0, minf(size.x, size.y) * 0.5 - 2.0)
	var start_angle := -PI * 0.5
	draw_arc(
		center,
		radius,
		start_angle,
		start_angle + TAU * ratio,
		_CIRCLE_SEGMENTS,
		_CIRCLE_COLOR,
		_CIRCLE_WIDTH,
		true
	)


func _remaining_ratio() -> float:
	_sync_cooldown_source()
	if _cooldown_duration_msec <= 0:
		return 0.0
	var remaining := _cooldown_ends_at_msec - Time.get_ticks_msec()
	return clampf(float(remaining) / float(_cooldown_duration_msec), 0.0, 1.0)


func _update_process_state() -> void:
	set_process(_cooldown_source.is_valid() or _cooldown_duration_msec > 0)
