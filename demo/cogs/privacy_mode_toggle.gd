class_name PrivacyModeToggle
extends Button

const _PUBLIC_ICON := preload("res://resources/icons/users.svg")
const _PRIVATE_ICON := preload("res://resources/icons/person-private-bold.svg")
const _BANNED_ICON := preload("res://resources/icons/users-slash.svg")
const _CIRCLE_COLOR := Color(1.0, 0.0, 1.0, 1.0)
const _CIRCLE_WIDTH := 1.0
const _CIRCLE_SEGMENTS := 40

var _pending_duration_msec: int = 0
var _pending_ends_at_msec: int = 0
var _interaction_enabled: bool = true
var _banned_display: bool = false


func _ready() -> void:
	focus_mode = Control.FOCUS_NONE
	set_private_mode_display(button_pressed)
	set_process(false)


func start_pending(duration_seconds: float = 1.0) -> void:
	_pending_duration_msec = maxi(1, roundi(duration_seconds * 1000.0))
	_pending_ends_at_msec = Time.get_ticks_msec() + _pending_duration_msec
	_refresh_disabled()
	set_process(true)
	queue_redraw()


func clear_pending() -> void:
	_pending_duration_msec = 0
	_pending_ends_at_msec = 0
	_refresh_disabled()
	set_process(false)
	queue_redraw()


func is_pending() -> bool:
	return _remaining_ratio() > 0.0


func set_interaction_enabled(enabled: bool) -> void:
	_interaction_enabled = enabled
	_refresh_disabled()


func set_private_mode_display(enabled: bool) -> void:
	if _banned_display:
		return
	set_pressed_no_signal(enabled)
	icon = _PRIVATE_ICON if enabled else _PUBLIC_ICON
	queue_redraw()


func set_banned_mode_display(enabled: bool) -> void:
	_banned_display = enabled
	if enabled:
		set_pressed_no_signal(true)
		icon = _BANNED_ICON
		WebpageThemeTooltipRuntime.set_control_tooltip(self, "封禁中")
	else:
		WebpageThemeTooltipRuntime.set_control_tooltip(self, "隐身")
		set_private_mode_display(button_pressed)
	_refresh_disabled()
	queue_redraw()


func _process(_delta: float) -> void:
	if _remaining_ratio() <= 0.0:
		clear_pending()
		return
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
	if _pending_duration_msec <= 0:
		return 0.0
	var remaining := _pending_ends_at_msec - Time.get_ticks_msec()
	return clampf(float(remaining) / float(_pending_duration_msec), 0.0, 1.0)


func _refresh_disabled() -> void:
	disabled = _banned_display or not _interaction_enabled or _remaining_ratio() > 0.0
