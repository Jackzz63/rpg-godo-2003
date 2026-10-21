class_name WorldLocationBanner
extends Control

## A client-local location notification. Runtime owns location resolution;
## this node owns only the latest target, its animation, and menu occlusion.
const ENTER_DURATION := 0.5
const HOLD_DURATION := 5.0
const EXIT_DURATION := 0.5
const FAST_EXIT_DURATION := 0.1

const _STATE_HIDDEN := 0
const _STATE_ENTERING := 1
const _STATE_HOLDING := 2
const _STATE_EXITING := 3

@export var chat_control: Control
@export var game_output: Control
@onready var banner_frame: Control = %BannerFrame
@onready var banner_label: RichTextLabel = %BannerLabel
@onready var display_timer: Timer = %BannerDisplayTimer

var _location_runtime: Node
var _state := _STATE_HIDDEN
var _current: Dictionary = {}
var _pending: Dictionary = {}
var _last_target_key := ""
var _last_target_context: Dictionary = {}
var _language_refresh: Dictionary = {}
var _fade_tween: Tween
var _exit_is_fast := false
var _presentation_ready := false
var _layout_queued := false
var _theme_dirty := true
var _rendered_entries: Array[Dictionary] = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	mouse_behavior_recursive = Control.MOUSE_BEHAVIOR_DISABLED
	UiScale.mark_geometry_physical(banner_frame)
	UiScale.mark_geometry_physical(banner_label)
	banner_frame.hide()
	display_timer.wait_time = HOLD_DURATION
	display_timer.one_shot = true
	display_timer.timeout.connect(_on_display_timer_timeout)
	banner_label.minimum_size_changed.connect(_queue_layout)
	get_viewport().size_changed.connect(_queue_layout)
	if is_instance_valid(game_output):
		game_output.item_rect_changed.connect(_queue_layout)
	_bind_location_runtime()
	if chat_control.is_node_ready():
		_on_chat_ready()
	else:
		chat_control.ready.connect(_on_chat_ready, CONNECT_ONE_SHOT)


func _exit_tree() -> void:
	_unbind_location_runtime()
	_kill_fade_tween()


func _on_chat_ready() -> void:
	_presentation_ready = true
	_on_chat_open_changed(bool(chat_control.call("is_chat_open")))
	_publish_initial_location()
	if _state == _STATE_HIDDEN:
		_start_pending()
	else:
		_refresh_active_content()


func set_location_runtime(runtime: Node) -> void:
	if _location_runtime == runtime:
		return
	_unbind_location_runtime()
	_location_runtime = runtime
	reset_banner()
	# SetupScreen may auto-launch before this later scene sibling is ready.
	if not is_node_ready():
		return
	_bind_location_runtime()
	_publish_initial_location()


func reset_banner() -> void:
	_theme_dirty = true
	_rendered_entries.clear()
	_current.clear()
	_pending.clear()
	_last_target_key = ""
	_last_target_context.clear()
	_language_refresh.clear()
	_state = _STATE_HIDDEN
	_exit_is_fast = false
	_kill_fade_tween()
	if not is_node_ready():
		return
	display_timer.stop()
	banner_frame.hide()
	banner_frame.modulate.a = 0.0
	banner_label.clear()


func _runtime_callbacks() -> Dictionary:
	return {
		"current_location_changed": _on_current_location_changed,
		"language_changed": _on_location_language_changed,
		"context_changed": _on_location_context_changed,
	}


func _bind_location_runtime() -> void:
	if not is_instance_valid(_location_runtime):
		return
	var callbacks := _runtime_callbacks()
	for signal_name: String in callbacks:
		var callback: Callable = callbacks[signal_name]
		if _location_runtime.has_signal(signal_name) and not _location_runtime.is_connected(signal_name, callback):
			_location_runtime.connect(signal_name, callback)


func _unbind_location_runtime() -> void:
	if is_instance_valid(_location_runtime):
		var callbacks := _runtime_callbacks()
		for signal_name: String in callbacks:
			var callback: Callable = callbacks[signal_name]
			if _location_runtime.has_signal(signal_name) and _location_runtime.is_connected(signal_name, callback):
				_location_runtime.disconnect(signal_name, callback)
	_location_runtime = null


func _get_context() -> Dictionary:
	if is_instance_valid(_location_runtime):
		return _location_runtime.call("get_location_context")
	return {}


func _resolve_context(context: Dictionary) -> Dictionary:
	if context.is_empty() or not is_instance_valid(_location_runtime):
		return {}
	return _location_runtime.call("resolve_location", int(context.get("map_id", 0)),
		int(context.get("previous_map_id", 0)), int(context.get("x", -1)), int(context.get("y", -1)))


func _publish_initial_location() -> void:
	if is_instance_valid(_location_runtime):
		_on_current_location_changed(_location_runtime.call("get_current_location"))


func _on_location_context_changed(context: Dictionary) -> void:
	# ignored -> Map0 can resolve to the same hidden dictionary, so the
	# deduplicated location signal alone cannot carry this lifecycle boundary.
	if int(context.get("map_id", 0)) <= 0:
		reset_banner()


func _is_transparent_location(location: Dictionary, context: Dictionary) -> bool:
	return int(context.get("map_id", 0)) > 0 and bool(location.get("hidden", false)) \
		and (bool(location.get("english_available", false)) or bool(location.get("localized_available", false)))


func _make_record(location: Dictionary, context: Dictionary) -> Dictionary:
	var english := str(location.get("language_code", "en")).to_lower() == "en"
	var available_key := "english_available" if english else "localized_available"
	var entries_key := "english_entries" if english else "localized_entries"
	if bool(location.get("hidden", false)) or not bool(location.get(available_key, false)):
		return {}
	var entries: Array[Dictionary] = []
	var titles: Array[String] = []
	for raw_entry: Variant in location.get(entries_key, []):
		if not raw_entry is Dictionary:
			continue
		# Explicit line breaks are flattened; only the shared width limit wraps.
		var title := str(raw_entry.get("title", "")).strip_edges().replace("\r\n", " ") \
			.replace("\r", " ").replace("\n", " ").replace("\t", " ")
		if title.is_empty():
			continue
		titles.append(title)
		entries.append({"title": title, "url": str(raw_entry.get("url", ""))})
	if entries.is_empty():
		return {}
	return {"key": " | ".join(titles), "entries": entries, "context": context.duplicate(true)}


func _translate_record(record: Dictionary) -> Dictionary:
	if record.is_empty():
		return {}
	var context: Dictionary = record.context
	return _make_record(_resolve_context(context), context)


func _on_location_language_changed(_language_code: String) -> void:
	# Runtime has changed its resolver's language, but has not yet replaced the
	# previous map/coordinates. Compare the next result in that same language.
	var context := _get_context()
	var baseline := _resolve_context(context)
	if _is_transparent_location(baseline, context):
		context = _last_target_context
		baseline = _resolve_context(context)
	_language_refresh = {
		"key": _make_record(baseline, context).get("key", ""),
		"current": _translate_record(_current),
		"pending": _translate_record(_pending),
	}


func _apply_language_refresh() -> void:
	_last_target_key = str(_language_refresh.key)
	var translated: Dictionary = _language_refresh.current
	if not translated.is_empty():
		_current = translated
		_refresh_active_content()
	# Keep the old glyphs only for their quick fade if this language has no name.
	_pending = _language_refresh.pending
	_language_refresh.clear()


func _on_current_location_changed(location: Dictionary) -> void:
	var context := _get_context()
	if int(context.get("map_id", 0)) <= 0:
		reset_banner()
		return
	if _is_transparent_location(location, context):
		if not _language_refresh.is_empty():
			_apply_language_refresh()
			if _last_target_key.is_empty():
				_pending.clear()
				_request_exit(true)
		return
	var record := _make_record(location, context)
	if not _language_refresh.is_empty():
		var translation_only := str(record.get("key", "")) == str(_language_refresh.key)
		_apply_language_refresh()
		if translation_only:
			_update_same_target(record)
			return
	_accept_target(record)


func _update_same_target(record: Dictionary) -> void:
	if record.is_empty():
		_pending.clear()
		_request_exit(true)
		return
	_last_target_context = record.context
	if not _pending.is_empty():
		_pending = record
	elif _state != _STATE_HIDDEN:
		# Runtime can deduplicate movement whose old-language text is identical.
		# A pure translation must use this newly resolved record, not the earlier
		# coordinates retained by the visible record. Keep its existing deadline.
		var changed: bool = _current.get("entries", []) != record.entries
		_current = record
		if changed:
			_refresh_active_content()


func _accept_target(record: Dictionary) -> void:
	var key := str(record.get("key", ""))
	if key == _last_target_key:
		_update_same_target(record)
		return
	_last_target_key = key
	_last_target_context = record.get("context", {})
	# The target is compared to the last accepted name, not the fading label:
	# A -> B -> A must replace the pending B with A.
	_pending = record
	if _state == _STATE_HIDDEN:
		_start_pending()
	else:
		_request_exit(true)


func _start_pending() -> void:
	if not _presentation_ready or _pending.is_empty():
		return
	_current = _pending
	_pending = {}
	_state = _STATE_ENTERING
	_exit_is_fast = false
	banner_frame.modulate = Color(1, 1, 1, 0)
	_refresh_active_content()
	banner_frame.show()
	_fade_tween = create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_fade_tween.tween_property(banner_frame, "modulate:a", 1.0, ENTER_DURATION)
	_fade_tween.finished.connect(_on_enter_finished, CONNECT_ONE_SHOT)


func _on_enter_finished() -> void:
	if _state != _STATE_ENTERING:
		return
	_fade_tween = null
	_state = _STATE_HOLDING
	display_timer.start(HOLD_DURATION)


func _on_display_timer_timeout() -> void:
	if _state == _STATE_HOLDING:
		_request_exit(false)


func _request_exit(fast: bool) -> void:
	if _state == _STATE_HIDDEN:
		return
	var duration := FAST_EXIT_DURATION if fast else EXIT_DURATION
	if _state == _STATE_EXITING:
		if not fast or _exit_is_fast:
			return
		_exit_is_fast = true
		# Do not turn the final 0.03 s of a normal fade into another 0.1 s wait.
		var remaining := maxf(0.0, EXIT_DURATION - _fade_tween.get_total_elapsed_time())
		if remaining <= FAST_EXIT_DURATION:
			return
	display_timer.stop()
	_kill_fade_tween()
	_state = _STATE_EXITING
	_exit_is_fast = fast
	if is_zero_approx(banner_frame.modulate.a):
		_on_exit_finished()
		return
	_fade_tween = create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_fade_tween.tween_property(banner_frame, "modulate:a", 0.0, duration)
	_fade_tween.finished.connect(_on_exit_finished, CONNECT_ONE_SHOT)


func _on_exit_finished() -> void:
	if _state != _STATE_EXITING:
		return
	_fade_tween = null
	banner_frame.hide()
	_current = {}
	_state = _STATE_HIDDEN
	_start_pending()


func _kill_fade_tween() -> void:
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()
	_fade_tween = null


func _on_chat_open_changed(open: bool) -> void:
	# Visibility is independent of alpha, Timer, and Tween progression.
	visible = not open


func _on_location_presentation_changed() -> void:
	# This signal includes same-name theme replacement and font/scale changes.
	# Remember it even when the notification is currently hidden.
	_theme_dirty = true
	_refresh_active_content()


func _refresh_active_content() -> void:
	if not _presentation_ready or _state == _STATE_HIDDEN or _current.is_empty():
		return
	if _theme_dirty or _rendered_entries != _current.entries:
		chat_control.call("render_location_notification", banner_label, _current.entries, _theme_dirty)
		_rendered_entries = _current.entries.duplicate(true)
		_theme_dirty = false
	_queue_layout()


func _queue_layout() -> void:
	if _layout_queued or not is_node_ready():
		return
	_layout_queued = true
	_layout_content.call_deferred()


func _layout_content() -> void:
	_layout_queued = false
	if not _presentation_ready or _state == _STATE_HIDDEN:
		return
	# Follow the visible game canvas independently of the HUD's safe margins.
	var bounds := get_viewport_rect()
	if is_instance_valid(game_output):
		bounds = bounds.intersection(game_output.get_global_rect())
	# Re-measure from the text's natural width when the game area grows again.
	chat_control.call("_fit_current_location_label", banner_label, maxf(1.0, minf(bounds.size.x,
		preload("res://cogs/location_text_layout.gd").width_limit(self))))
	banner_label.size.x = banner_label.custom_minimum_size.x
	# Hidden RichTextLabels do not draw and therefore do not refresh wrapping
	# automatically. Measure at the new width even while T masks the banner.
	var height := banner_label.get_content_height() + banner_label.get_theme_stylebox("normal").get_minimum_size().y
	banner_label.size.y = height
	banner_frame.size = banner_label.size
	banner_frame.position = get_global_transform_with_canvas().affine_inverse() * bounds.position
	# A masked label can change its line layout without drawing or resizing.
	var lines := banner_label.get_node_or_null("__ThemeTextLines")
	if lines != null:
		lines.refresh()
