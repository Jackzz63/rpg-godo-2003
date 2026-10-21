class_name ClientPerformance
extends Node
## Opt-in, bounded main-thread profiler. Durations are per-frame totals, not
## individual call percentiles. Nested scopes are explicitly named inclusive.

const BUILD_LABEL := "perf-stage5-20260911"
const BUCKET_US := 250
const BUCKETS := 8002 # 0..2000 ms, then overflow; exact max is retained.
const MAX_SECONDS := 3600
const NATIVE_NAMES := [&"engine.update", &"engine.draw_inclusive",
	&"engine.pixel_convert", &"engine.texture_upload", &"audio.native_pull"]
const NATIVE_AUDIO_BATCH_NAMES := [&"audio.convert", &"audio.push_buffer", &"audio.native_feed"]

class Metric:
	const LIMITS_US := [16667, 33333, 50000, 100000]
	var histogram := PackedInt64Array()
	var frames := 0
	var calls := 0
	var total_us := 0
	var max_us := 0
	var over := PackedInt64Array([0, 0, 0, 0])
	func _init() -> void:
		histogram.resize(BUCKETS)
	func add(usec: int, count: int) -> void:
		frames += 1
		calls += count
		total_us += usec
		max_us = maxi(max_us, usec)
		histogram[mini(ceili(float(usec) / BUCKET_US), BUCKETS - 1)] += 1
		for i in 4:
			if usec > LIMITS_US[i]:
				over[i] += 1
	func percentile(p: float) -> float:
		var target := ceili(frames * p)
		var seen := 0
		for i in histogram.size():
			seen += histogram[i]
			if seen >= target:
				return max_us / 1000.0 if i == BUCKETS - 1 else i * BUCKET_US / 1000.0
		return 0.0
	func summary() -> Dictionary:
		return {"active_frames": frames, "calls": calls, "total_ms": total_us / 1000.0,
			"mean_active_frame_ms": total_us / 1000.0 / maxi(frames, 1),
			"p50_ms": percentile(0.5), "p95_ms": percentile(0.95),
			"p99_ms": percentile(0.99), "p999_ms": percentile(0.999),
			"max_ms": max_us / 1000.0, "over_16_667_ms": over[0],
			"over_33_333_ms": over[1], "over_50_ms": over[2], "over_100_ms": over[3]}

static var enabled := false
static var _frame_us: Dictionary = {}
static var _frame_calls: Dictionary = {}
static var _counters: Dictionary = {}
static var _gauges: Dictionary = {}
static var _marks: Array[Dictionary] = []

var _metrics: Dictionary = {}
var _totals: Dictionary = {}
var _gauge_max: Dictionary = {}
var _timeline: Array[Dictionary] = []
var _native_nodes: Array[Node] = []
var _report_path := ""
var _duration_sec := 300.0
var _delay_sec := 0.0
var _armed_usec := 0
var _start_usec := 0
var _last_frame_usec := 0
var _start_unix := 0.0
var _finished := false
var _seconds_written := 0
var _second: Dictionary = {}

static func begin() -> int:
	return Time.get_ticks_usec() if enabled else 0

static func end(metric: StringName, started: int) -> void:
	if enabled and started > 0:
		record(metric, Time.get_ticks_usec() - started)

static func record(metric: StringName, usec: int, count: int = 1) -> void:
	if enabled:
		_frame_us[metric] = int(_frame_us.get(metric, 0)) + maxi(usec, 0)
		_frame_calls[metric] = int(_frame_calls.get(metric, 0)) + count

static func count_event(metric: StringName, count: int = 1) -> void:
	if enabled:
		_counters[metric] = int(_counters.get(metric, 0)) + count

static func gauge(metric: StringName, value: int) -> void:
	if enabled:
		_gauges[metric] = maxi(int(_gauges.get(metric, 0)), value)

static func mark(label: String) -> void:
	if enabled:
		if _marks.size() >= 128:
			_marks.pop_front()
		_marks.append({"unix_sec": Time.get_unix_time_from_system(),
			"ticks_usec": Time.get_ticks_usec(), "label": label})

static func parse_options(args: PackedStringArray, default_fps: int = 0) -> Dictionary:
	var result := {"client": true, "fps": default_fps, "report": "", "seconds": 300.0, "delay": 0.0}
	for i in args.size():
		var arg := args[i]
		if arg == "--server-only" or arg == "--adminctl" or arg.begins_with("--adminctl="):
			result.client = false
		if arg.begins_with("--client-max-fps="):
			var value := arg.get_slice("=", 1)
			if value.is_valid_int() and int(value) >= 0:
				result.fps = int(value)
		if arg.begins_with("--perf-report="):
			result.report = arg.trim_prefix("--perf-report=")
		if arg.begins_with("--perf-seconds="):
			var value := arg.get_slice("=", 1)
			if value.is_valid_float():
				result.seconds = clampf(float(value), 1.0, MAX_SECONDS)
		if arg.begins_with("--perf-delay="):
			var value := arg.get_slice("=", 1)
			if value.is_valid_float():
				result.delay = clampf(float(value), 0.0, MAX_SECONDS)
	return result

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = -100000 # Collect the previous frame before any measured node runs.
	var args := OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	# Godot consumes --max-fps before exposing application args. Preserve an
	# existing limit, including zero. VSync remains controlled by Godot/the driver.
	var options := parse_options(args, Engine.max_fps)
	if not options.client or Engine.is_editor_hint():
		set_process(false)
		return
	Engine.max_fps = options.fps
	print("CLIENT_FRAME_LIMIT=", Engine.max_fps, " BUILD=", BUILD_LABEL)
	_report_path = options.report
	if _report_path.is_empty():
		set_process(false)
		return
	_report_path = ProjectSettings.globalize_path(_report_path)
	_duration_sec = options.seconds
	_delay_sec = options.delay
	_armed_usec = Time.get_ticks_usec()
	get_tree().node_added.connect(_on_node_added)
	call_deferred("_find_native_nodes", get_tree().root)
	print("PERF_ARMED delay=", _delay_sec, " seconds=", _duration_sec, " report=", _report_path)

func _on_node_added(node: Node) -> void:
	# Script-derived GDExtension nodes do not reliably match is_class() on all
	# export templates. Check the exact timing interface and deduplicate discovery.
	if node.has_method("set_performance_enabled") and node.has_method("take_performance_counters"):
		if not _native_nodes.has(node):
			_native_nodes.append(node)
			node.call("set_performance_enabled", enabled)

func _find_native_nodes(node: Node) -> void:
	_on_node_added(node)
	for child in node.get_children():
		_find_native_nodes(child)

func _set_native_enabled(value: bool) -> void:
	for node in _native_nodes:
		if is_instance_valid(node):
			node.call("set_performance_enabled", value)

func _drain_native() -> void:
	for node in _native_nodes:
		if not is_instance_valid(node):
			continue
		var values: PackedInt64Array = node.call("take_performance_counters")
		for i in NATIVE_NAMES.size():
			if values[i * 2 + 1] > 0:
				record(NATIVE_NAMES[i], values[i * 2], values[i * 2 + 1])
		if values[3] > 0:
			record(&"engine.software_draw", maxi(0, values[2] - values[4] - values[6]), values[3])
		if values[11] > 0:
			record(&"audio.decode_mix", values[10], values[11])
		count_event(&"engine.logical_updates", values[13])
		if values.size() >= 17:
			count_event(&"engine.draw_skipped", values[14])
			count_event(&"engine.draw_forced", values[15])
			count_event(&"engine.frames_committed", values[16])
		if values.size() >= 23:
			for i in 3:
				if values[18 + i * 2] > 0:
					record(NATIVE_AUDIO_BATCH_NAMES[i],
						values[17 + i * 2], values[18 + i * 2])

func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	if not enabled:
		if _finished or now - _armed_usec < _delay_sec * 1000000.0:
			return
		enabled = true
		_start_usec = now
		_last_frame_usec = now
		_start_unix = Time.get_unix_time_from_system()
		_second = _new_second(0)
		_set_native_enabled(true)
		print("PERF_STARTED unix=", _start_unix, " native_nodes=", _native_nodes.size())
		return
	var overhead_start := now
	_drain_native()
	var frame_usec := now - _last_frame_usec
	_last_frame_usec = now
	record(&"frame.interval", frame_usec)
	_collect_frame()
	var elapsed := (now - _start_usec) / 1000000.0
	if elapsed >= float(_second.second) + 1.0:
		_store_second()
		_second = _new_second(int(elapsed))
	if elapsed >= _duration_sec:
		finish_report("duration")
	else:
		record(&"profiler.collect", Time.get_ticks_usec() - overhead_start)

func _new_second(second: int) -> Dictionary:
	return {"second": second, "frames": 0, "frame_max_ms": 0.0,
		"over_50_ms": 0, "duration_ms": {}, "calls": {}, "counters": {}, "gauge_max": {}}

func _collect_frame() -> void:
	if _frame_us.has(&"frame.interval"):
		_second.frames += 1
	for name in _frame_us:
		if not _metrics.has(name):
			_metrics[name] = Metric.new()
		var value: int = _frame_us[name]
		var calls: int = _frame_calls[name]
		(_metrics[name] as Metric).add(value, calls)
		_second.duration_ms[name] = float(_second.duration_ms.get(name, 0.0)) + value / 1000.0
		_second.calls[name] = int(_second.calls.get(name, 0)) + calls
		if name == &"frame.interval":
			_second.frame_max_ms = maxf(_second.frame_max_ms, value / 1000.0)
			if value > 50000:
				_second.over_50_ms += 1
	for name in _counters:
		_totals[name] = int(_totals.get(name, 0)) + int(_counters[name])
		_second.counters[name] = int(_second.counters.get(name, 0)) + int(_counters[name])
	for name in _gauges:
		_gauge_max[name] = maxi(int(_gauge_max.get(name, 0)), int(_gauges[name]))
		_second.gauge_max[name] = maxi(int(_second.gauge_max.get(name, 0)), int(_gauges[name]))
	_frame_us.clear()
	_frame_calls.clear()
	_counters.clear()
	_gauges.clear()

func _store_second() -> void:
	if int(_second.get("frames", 0)) == 0:
		return
	if _timeline.size() < MAX_SECONDS:
		_timeline.append(_second)
	else:
		_timeline[_seconds_written % MAX_SECONDS] = _second
	_seconds_written += 1

func finish_report(reason: String) -> void:
	if _finished or not enabled:
		return
	_drain_native()
	if not _frame_us.is_empty():
		_collect_frame()
	enabled = false
	_finished = true
	_set_native_enabled(false)
	_store_second()
	var duration := (Time.get_ticks_usec() - _start_usec) / 1000000.0
	var summaries := {}
	for name in _metrics:
		summaries[name] = (_metrics[name] as Metric).summary()
	_timeline.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.second < b.second)
	var report := {"schema": 1, "build": BUILD_LABEL, "reason": reason,
		"start_unix_sec": _start_unix, "duration_sec": duration,
		"platform": OS.get_name(), "cpu": OS.get_processor_name(),
		"logical_processors": OS.get_processor_count(), "godot": Engine.get_version_info().string,
		"debug_build": OS.is_debug_build(), "max_fps": Engine.max_fps,
		"vsync_mode": DisplayServer.window_get_vsync_mode(),
		"native_api_nodes": _native_nodes.size(), "histogram_resolution_ms": BUCKET_US / 1000.0,
		"metrics": summaries, "counters": _totals, "gauge_max": _gauge_max,
		"marks": _marks, "timeline": _timeline,
		"semantics": "Monotonic main-thread frame intervals include pacing/waits. Metric percentiles are summed time per active frame; inactive frames omitted. Inclusive scopes overlap and must not be added together. Queue age starts when the app enqueues parsed messages, not at network arrival. Timeline retains last 3600 observed seconds. Export occurs after sampling stops."}
	var error := DirAccess.make_dir_recursive_absolute(_report_path.get_base_dir())
	if error != OK:
		push_error("PERF report directory failed: " + error_string(error))
		return
	var file := FileAccess.open(_report_path, FileAccess.WRITE)
	if file == null:
		push_error("PERF report open failed: " + error_string(FileAccess.get_open_error()))
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	var markdown := FileAccess.open(_report_path.get_basename() + ".md", FileAccess.WRITE)
	if markdown != null:
		markdown.store_string(_markdown(report))
		markdown.close()
	print("PERF_REPORT_WRITTEN=", _report_path)
	set_process(false)

func _markdown(report: Dictionary) -> String:
	var lines := PackedStringArray(["# 客户端性能报告", "",
		"构建：%s；采样 %.1f 秒；帧率上限 %d；VSync 模式 %d。" % [
			BUILD_LABEL, report.duration_sec, report.max_fps, report.vsync_mode], "",
		"帧间隔包含限帧和等待。分项是每个活跃帧内的累计耗时；inclusive 项包含子项，不能相加。分位数精度 0.25 ms，最大值为实际采样值。", "",
		"| 分项 | 调用数 | 活跃帧均值 ms | P95 | P99 | P99.9 | 最大 ms | >50 ms 帧 |",
		"|---|---:|---:|---:|---:|---:|---:|---:|"])
	for name in report.metrics:
		var m: Dictionary = report.metrics[name]
		lines.append("| %s | %d | %.3f | %.2f | %.2f | %.2f | %.3f | %d |" % [
			name, m.calls, m.mean_active_frame_ms, m.p95_ms, m.p99_ms, m.p999_ms, m.max_ms, m.over_50_ms])
	lines.append("")
	if report.metrics.has("frame.interval"):
		var frame: Dictionary = report.metrics["frame.interval"]
		lines.append("平均帧率 %.2f；超过 33.33 / 50 / 100 ms 的帧：%d / %d / %d。" % [
			frame.active_frames / maxf(report.duration_sec, 0.001), frame.over_33_333_ms,
			frame.over_50_ms, frame.over_100_ms])
		lines.append("帧间隔需要继续分析。" if frame.p99_ms > 33.5 or frame.over_100_ms > 0 else "本次帧间隔未触发 P99 >33.5 ms 或单帧 >100 ms 的分析门槛。")
	lines.append("\n计数与队列峰值：\n```json\n" + JSON.stringify({"counters": report.counters, "gauge_max": report.gauge_max}, "\t") + "\n```")
	lines.append("\n请结合 JSON 中每秒 timeline 和 T/H 状态 marks 定位尖峰；报告不自动把最高分项认定为因果。")
	return "\n".join(lines) + "\n"

func _exit_tree() -> void:
	finish_report("exit")
