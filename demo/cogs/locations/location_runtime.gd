class_name LocationRuntime
extends Node

## Client-side bridge from the embedded EasyRPG getters to the data-only
## catalog/resolver.  Consumers receive raw dictionaries, so UI and multiplayer
## can be wired independently without moving location names onto the server.

signal current_location_changed(location: Dictionary)
signal language_changed(language_code: String)
signal context_changed(context: Dictionary)

const DEFAULT_CATALOG_PATH := "res://config/game-catalog.json"
const GameCatalogScript := preload("res://cogs/locations/game_catalog.gd")
const LocationResolverScript := preload("res://cogs/locations/location_resolver.gd")

var _engine: Node = null
var _catalog: GameCatalog = null
var _resolver: LocationResolver = null
var _catalog_initialized := false
var _original_game_title := ""
var _selected_game: Dictionary = {}
var _language_code := "en"
var _context := {
	"map_id": 0,
	"previous_map_id": 0,
	"x": -1,
	"y": -1,
}
var _last_nonignored_map_id := 0
var _previous_nonignored_map_id := 0
var _map_visit_history: Array[int] = []
var _current_location: Dictionary = {}
var _source_override: Variant = null


func initialize(engine_node: Node, source_override: Variant = null) -> void:
	_ensure_services()
	_engine = engine_node
	_original_game_title = ""
	_selected_game.clear()
	_language_code = "en"
	_context = {"map_id": 0, "previous_map_id": 0, "x": -1, "y": -1}
	_last_nonignored_map_id = 0
	_previous_nonignored_map_id = 0
	_map_visit_history.clear()
	_current_location.clear()
	_resolver.clear(_language_code)
	# null selects the built-in catalog; an empty override intentionally disables
	# locations after an unreadable custom source instead of falling back to CU.
	_source_override = source_override.duplicate(true) if source_override is Dictionary else null
	if _source_override != null:
		_resolver.load_source(_source_override, _language_code)
	set_process(true)
	_poll_engine(true)


func add_catalog_source(path: String, allow_override: bool = false) -> bool:
	_ensure_services()
	var added := _catalog.add_source(path, allow_override)
	if added and not _original_game_title.is_empty():
		_select_game_from_locked_title(true)
		_refresh_location(true)
	return added


func resolve_location(
		map_id: int, prev_map_id: int, x: int, y: int) -> Dictionary:
	_ensure_services()
	return _resolver.resolve(map_id, prev_map_id, x, y).duplicate(true)


func get_current_location() -> Dictionary:
	return _current_location.duplicate(true)


func get_language_code() -> String:
	return _language_code


func get_location_context() -> Dictionary:
	return _context.duplicate(true)


func is_url_allowed(url: String) -> bool:
	_ensure_services()
	return _resolver.is_url_allowed(url)


func _ready() -> void:
	# initialize() is explicit because this node must be paired with the exact
	# RPGMakerPlayer instance selected by the setup screen.
	set_process(_engine != null)


func _process(_delta: float) -> void:
	_poll_engine(false)


func _ensure_services() -> void:
	if _catalog == null:
		_catalog = GameCatalogScript.new()
	if _resolver == null:
		_resolver = LocationResolverScript.new()
	if not _catalog_initialized:
		_catalog_initialized = true
		_catalog.add_source(DEFAULT_CATALOG_PATH)


func _poll_engine(force: bool) -> void:
	if not is_instance_valid(_engine):
		return
	_ensure_services()
	var selection_changed := false
	if _original_game_title.is_empty() and _engine.has_method("get_original_game_title"):
		var detected_title := str(_engine.call("get_original_game_title")).strip_edges()
		if not detected_title.is_empty():
			_original_game_title = detected_title
			selection_changed = _select_game_from_locked_title(false)

	var detected_language := "en"
	if _engine.has_method("get_current_language_code"):
		detected_language = LocationResolverScript.normalize_language_code(
			str(_engine.call("get_current_language_code"))
		)
	var language_did_change := detected_language != _language_code
	if language_did_change:
		_language_code = detected_language
		_resolver.set_language(_language_code)
		_reconcile_previous_map_tracking()
		language_changed.emit(_language_code)

	var map_id := 0
	var x := -1
	var y := -1
	var map_ready := true
	if _engine.has_method("is_map_ready"):
		map_ready = bool(_engine.call("is_map_ready"))
	if map_ready and _engine.has_method("get_current_map_id"):
		map_id = maxi(0, int(_engine.call("get_current_map_id")))
		if _engine.has_method("get_current_player_x"):
			x = int(_engine.call("get_current_player_x"))
		if _engine.has_method("get_current_player_y"):
			y = int(_engine.call("get_current_player_y"))

	var old_map_id := int(_context.map_id)
	if map_id != old_map_id:
		_context.map_id = map_id
		if map_id > 0:
			_record_map_visit(map_id)
		_reconcile_previous_map_tracking(false)

	var context_did_change := (
		map_id != old_map_id
		or x != int(_context.x)
		or y != int(_context.y)
	)
	if context_did_change:
		_context.map_id = map_id
		_context.x = x
		_context.y = y
		context_changed.emit(_context.duplicate(true))

	if force or selection_changed or language_did_change or context_did_change:
		_refresh_location(force or selection_changed or language_did_change)


func _select_game_from_locked_title(force_reload: bool) -> bool:
	if _source_override != null:
		return false
	var matched := _catalog.match_title(_original_game_title)
	var old_game_id := str(_selected_game.get("game_id", ""))
	var new_game_id := str(matched.get("game_id", ""))
	if not force_reload and old_game_id == new_game_id:
		return false
	_selected_game = matched
	if _selected_game.is_empty():
		_resolver.clear(_language_code)
	else:
		_resolver.load_game(_selected_game, _language_code)
	_reconcile_previous_map_tracking()
	return old_game_id != new_game_id or force_reload


func _record_map_visit(map_id: int) -> void:
	if map_id <= 0:
		return
	var previous_index := _map_visit_history.find(map_id)
	if previous_index >= 0:
		_map_visit_history.remove_at(previous_index)
	_map_visit_history.append(map_id)


func _reconcile_previous_map_tracking(emit_change: bool = true) -> void:
	var old_previous_map_id := int(_context.previous_map_id)
	var current_map_id := int(_context.map_id)
	if current_map_id <= 0:
		# Map 0000 is the title/menu boundary.  A later game session must not
		# inherit any previous-map branch state from the session that ended.
		_map_visit_history.clear()
		_last_nonignored_map_id = 0
		_previous_nonignored_map_id = 0
		_context.previous_map_id = 0
		if emit_change and old_previous_map_id != 0:
			context_changed.emit(_context.duplicate(true))
		return

	# Retain the most recent visit order of every distinct map, not only the two
	# most recent resolved locations. A catalog may be recognized late, and
	# future user-supplied sources may change which earlier maps are ignored.
	# Replaying this bounded per-session sequence recovers the correct previous
	# location without asking the server to interpret client location data.
	if _map_visit_history.is_empty() or _map_visit_history.back() != current_map_id:
		_record_map_visit(current_map_id)
	var nonignored_history: Array[int] = []
	for visited_map_id: int in _map_visit_history:
		if visited_map_id <= 0 or _resolver.is_ignored(visited_map_id):
			continue
		# Returning to the same visible map through ignored maps must not make the
		# map its own previous-map branch origin.
		if nonignored_history.is_empty() or nonignored_history.back() != visited_map_id:
			nonignored_history.append(visited_map_id)

	_last_nonignored_map_id = (
		nonignored_history.back() if not nonignored_history.is_empty() else 0
	)
	_previous_nonignored_map_id = (
		nonignored_history[nonignored_history.size() - 2]
		if nonignored_history.size() >= 2
		else 0
	)
	_context.previous_map_id = _previous_nonignored_map_id
	if emit_change and old_previous_map_id != int(_context.previous_map_id):
		context_changed.emit(_context.duplicate(true))


func _refresh_location(force_emit: bool) -> void:
	var resolved := _resolver.resolve(
		int(_context.map_id),
		int(_context.previous_map_id),
		int(_context.x),
		int(_context.y)
	)
	if force_emit or resolved != _current_location:
		_current_location = resolved
		current_location_changed.emit(_current_location.duplicate(true))
