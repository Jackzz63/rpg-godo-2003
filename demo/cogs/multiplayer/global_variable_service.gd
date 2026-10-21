class_name GlobalVariableService
extends RefCounted

signal minute_tick(raw_time: int, randint: int)
signal weather_tick(temperature: int, precipitation: int)
signal holiday_changed(holiday: int)

const MINUTE_SECONDS := 60
const WEATHER_SECONDS := 120
const TICK_SECOND := 58
const HOURS_PER_DAY := 20
const DAYS_PER_CYCLE := 12
const CYCLE_MINUTES := HOURS_PER_DAY * DAYS_PER_CYCLE
const MAX_CATCH_UP_TICKS := 120

var randint: int = 0
var temperature: int = 0
var precipitation: int = 0

var _rng := RandomNumberGenerator.new()
var _next_minute_deadline: int = 0
var _next_weather_deadline: int = 0
var _last_holiday: int = 0
var _last_poll_unix: int = -1
var _started: bool = false


func start(now_unix: int = int(Time.get_unix_time_from_system())) -> void:
	randint = 0
	temperature = 0
	precipitation = 0
	_rng.randomize()
	_next_minute_deadline = _next_deadline(now_unix, MINUTE_SECONDS)
	_next_weather_deadline = _next_deadline(now_unix, WEATHER_SECONDS)
	_last_holiday = holiday_for_unix(now_unix)
	_last_poll_unix = -1
	_started = true


func poll(now_unix: int = int(Time.get_unix_time_from_system())) -> void:
	if not _started:
		start(now_unix)
	if now_unix == _last_poll_unix:
		return
	_last_poll_unix = now_unix

	# Deadlines advance by fixed slots so a slow frame cannot silently lose ticks.
	var minute_ticks_due := _ticks_due(now_unix, _next_minute_deadline, MINUTE_SECONDS)
	if minute_ticks_due > MAX_CATCH_UP_TICKS:
		randint = _rng.randi_range(0, 255)
		minute_tick.emit(raw_time_for_unix(now_unix), randint)
		_next_minute_deadline = _next_deadline(now_unix, MINUTE_SECONDS)
	else:
		while now_unix >= _next_minute_deadline:
			randint = _rng.randi_range(0, 255)
			minute_tick.emit(raw_time_for_unix(_next_minute_deadline), randint)
			_next_minute_deadline += MINUTE_SECONDS

	var weather_ticks_due := _ticks_due(now_unix, _next_weather_deadline, WEATHER_SECONDS)
	if weather_ticks_due > MAX_CATCH_UP_TICKS:
		temperature = clampi(temperature + _weather_delta(temperature), -100, 100)
		precipitation = clampi(precipitation + _weather_delta(precipitation), 0, 100)
		weather_tick.emit(temperature, precipitation)
		_next_weather_deadline = _next_deadline(now_unix, WEATHER_SECONDS)
	else:
		while now_unix >= _next_weather_deadline:
			temperature = clampi(temperature + _weather_delta(temperature), -100, 100)
			precipitation = clampi(precipitation + _weather_delta(precipitation), 0, 100)
			weather_tick.emit(temperature, precipitation)
			_next_weather_deadline += WEATHER_SECONDS

	var holiday := holiday_for_unix(now_unix)
	if holiday != _last_holiday:
		_last_holiday = holiday
		holiday_changed.emit(holiday)


func raw_time_for_unix(unix_time: int) -> int:
	var datetime := Time.get_datetime_dict_from_unix_time(unix_time)
	var minutes_since_midnight: int = int(datetime.hour) * 60 + int(datetime.minute)
	return minutes_since_midnight % CYCLE_MINUTES


func current_raw_time(now_unix: int = int(Time.get_unix_time_from_system())) -> int:
	return raw_time_for_unix(now_unix)


func current_holiday(now_unix: int = int(Time.get_unix_time_from_system())) -> int:
	return holiday_for_unix(now_unix)


func holiday_for_unix(unix_time: int) -> int:
	var datetime := Time.get_datetime_dict_from_unix_time(unix_time)
	var month: int = int(datetime.month)
	var day: int = int(datetime.day)

	if (month == 12 and day >= 30) or (month == 1 and day <= 2):
		return 2
	if month == 3 and day >= 19 and day <= 21:
		return 3
	if (month == 3 and day == 31) or (month == 4 and day <= 2):
		return 4
	if month == 6 and day >= 4 and day <= 11:
		return 1
	if month == 6 and day >= 18 and day <= 24:
		return 5
	if (month == 10 and day >= 21) or (month == 11 and day <= 4):
		return 6
	if month == 12 and day >= 14 and day <= 28:
		return 7
	return 0


func _next_deadline(now_unix: int, interval_seconds: int) -> int:
	var slot := floori(float(now_unix - TICK_SECOND) / float(interval_seconds))
	var deadline := slot * interval_seconds + TICK_SECOND
	if deadline <= now_unix:
		deadline += interval_seconds
	return deadline


func _ticks_due(now_unix: int, deadline: int, interval_seconds: int) -> int:
	if now_unix < deadline:
		return 0
	return floori(float(now_unix - deadline) / float(interval_seconds)) + 1


func _weather_delta(value: int) -> int:
	var delta := _rng.randi_range(0, 20) - 10
	var normalized := float(value) / 100.0
	var center_bias := int(round(normalized * normalized)) * signi(value) * -4
	return delta + center_bias
