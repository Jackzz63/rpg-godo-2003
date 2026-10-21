class_name LocationResolver
extends RefCounted

const ConfigLoader := preload("res://cogs/locations/location_config_loader.gd")

## Resolves the unmodified ynolocations JSON schema locally.  It intentionally
## does not use Yume 2kki's online Explorer fallback; maps absent from the
## bundled JSON resolve to the localized Unknown Location label.

const UNKNOWN_LOCATION_LABELS := {
	"ar": "موقع غير معروف",
	"de": "Unbekannter Ort",
	"en": "Unknown Location",
	"eo": "Nekonata Loko",
	"es": "Ubicación Desconocida",
	"fr": "Lieu Inconnu",
	"id": "Unknown Location",
	"it": "Ubicazione Sconosciuta",
	"ja": "場所不明",
	"ko": "알 수 없는 장소",
	"pl": "Nieznana lokalizacja",
	"pt": "Localização Inválida",
	"ro": "Locație Necunoscută",
	"ru": "Неизвестно",
	"tr": "Bilinmeyen Konum",
	"uk": "Невідома локація",
	"vi": "Không rõ Địa điểm",
	"zh": "未知领域",
}

const LANGUAGE_NAME_ALIASES := {
	"arabic": "ar",
	"chinese": "zh",
	"chs": "zh",
	"cht": "zh",
	"zh-cn": "zh",
	"zh-hans": "zh",
	"zh-tw": "zh",
	"zh-hant": "zh",
	"english": "en",
	"esperanto": "eo",
	"french": "fr",
	"german": "de",
	"indonesian": "id",
	"italian": "it",
	"japanese": "ja",
	"korean": "ko",
	"polish": "pl",
	"portuguese": "pt",
	"ptbr": "pt",
	"pt-br": "pt",
	"romanian": "ro",
	"russian": "ru",
	"spanish": "es",
	"turkish": "tr",
	"ukrainian": "uk",
	"vietnamese": "vi",
}

var _source: Dictionary = {}
var _language_code := "en"
var _english_config: Dictionary = {}
var _localized_config: Dictionary = {}
var _english_available := false
var _localized_available := false
var _allowed_url_roots: Array[String] = []


func load_game(game: Dictionary, language_code: String) -> bool:
	var slug: Variant = game.get("locations_slug", null)
	clear(language_code)
	if slug == null or str(slug).is_empty():
		return false
	var locations_root := str(game.get("locations_root", ""))
	if locations_root.is_empty():
		return false
	var loaded := ConfigLoader.load_directory(locations_root.path_join(str(slug)))
	if not loaded.ok:
		push_warning("[LocationResolver] %s (%s): %s" % [
			loaded.error, loaded.file, loaded.detail])
		return false
	_source = loaded.data
	return set_language(language_code)


func load_source(source: Dictionary, language_code: String) -> bool:
	clear(language_code)
	_source = source.duplicate(true)
	return set_language(language_code)


func set_language(language_code: String) -> bool:
	_language_code = normalize_language_code(language_code)
	_english_config.clear()
	_localized_config.clear()
	_allowed_url_roots.clear()
	_english_available = _source.has("base")
	_localized_available = false
	if _english_available:
		_english_config = (_source.base as Dictionary).duplicate(true)
	if _language_code != "en":
		var languages: Dictionary = _source.get("languages", {})
		_localized_available = languages.has(_language_code)
		if _localized_available:
			_localized_config = (languages[_language_code] as Dictionary).duplicate(true)
			_inherit_english_coordinate_layout()

	_collect_allowed_root(_english_config)
	_collect_allowed_root(_localized_config)
	return _english_available or _localized_available


func clear(language_code: String = "") -> void:
	_source.clear()
	_english_config.clear()
	_localized_config.clear()
	_english_available = false
	_localized_available = false
	_allowed_url_roots.clear()
	if not language_code.is_empty():
		_language_code = normalize_language_code(language_code)


func resolve(map_id: int, prev_map_id: int, x: int, y: int) -> Dictionary:
	var result := {
		"hidden": false,
		"language_code": _language_code,
		"localized_available": _localized_available and _language_code != "en",
		"english_available": _english_available,
		"localized_entries": [],
		"english_entries": [],
	}
	if map_id <= 0 or (not _english_available and not _localized_available):
		result.hidden = true
		return result
	if is_ignored(map_id):
		result.hidden = true
		return result

	var english_internal: Array[Dictionary] = []
	if _english_available:
		english_internal = _resolve_config(
			_english_config, map_id, prev_map_id, x, y, "en"
		)
		result.english_entries = _finalize_entries(
			english_internal, _english_config, [], {}, false
		)

	if _localized_available and _language_code != "en":
		var localized_internal := _resolve_config(
			_localized_config, map_id, prev_map_id, x, y, _language_code
		)
		result.localized_entries = _finalize_entries(
			localized_internal,
			_localized_config,
			english_internal,
			_english_config,
			true
		)
	return result


func is_ignored(map_id: int) -> bool:
	var map_key := _map_key(map_id)
	return (
		_config_ignores(_english_config, map_key)
		or _config_ignores(_localized_config, map_key)
	)


func is_url_allowed(url: String) -> bool:
	if not _is_safe_https_root(url):
		return false
	var url_authority := _https_authority(url)
	for root: String in _allowed_url_roots:
		# A textual prefix alone is unsafe for extension catalogs: a root such as
		# https://wiki.example could otherwise allow
		# https://wiki.example.evil.invalid.  Require the parsed authority to be
		# identical as well as the configured path prefix.
		if url_authority == _https_authority(root) and url.begins_with(root):
			return true
	return false


func get_language_code() -> String:
	return _language_code


static func normalize_language_code(raw_code: String) -> String:
	var code := raw_code.strip_edges().to_lower().replace("_", "-")
	if LANGUAGE_NAME_ALIASES.has(code):
		return LANGUAGE_NAME_ALIASES[code]
	if code.is_empty() or code == "default":
		return "en"
	if code.contains("-"):
		code = code.get_slice("-", 0)
	# EasyRPG language directories can be descriptive names such as
	# Japanese_Localization or Chinese_Simplified rather than ISO codes.
	if LANGUAGE_NAME_ALIASES.has(code):
		return LANGUAGE_NAME_ALIASES[code]
	return code if not code.is_empty() else "en"


func _inherit_english_coordinate_layout() -> void:
	if not _english_available:
		return
	var localized_maps: Variant = _localized_config.get("mapLocations", null)
	var english_maps: Variant = _english_config.get("mapLocations", null)
	if typeof(localized_maps) != TYPE_DICTIONARY or typeof(english_maps) != TYPE_DICTIONARY:
		return
	for map_id: Variant in localized_maps.keys():
		if english_maps.has(map_id):
			localized_maps[map_id] = _inherit_descriptor_layout(
				localized_maps[map_id], english_maps[map_id]
			)


func _inherit_descriptor_layout(localized: Variant, english: Variant) -> Variant:
	if typeof(localized) == TYPE_STRING:
		if (
			typeof(english) == TYPE_DICTIONARY
			and english.has("title")
			and typeof(english.get("coords", null)) == TYPE_DICTIONARY
		):
			return {
				"title": localized,
				"coords": (english.coords as Dictionary).duplicate(true),
			}
		return localized
	if typeof(localized) == TYPE_ARRAY:
		if typeof(english) != TYPE_ARRAY:
			return localized
		var localized_array := localized as Array
		var english_array := english as Array
		for index in mini(localized_array.size(), english_array.size()):
			localized_array[index] = _inherit_descriptor_layout(
				localized_array[index], english_array[index]
			)
		return localized_array
	if typeof(localized) != TYPE_DICTIONARY:
		return localized
	var localized_object := localized as Dictionary
	if typeof(english) != TYPE_DICTIONARY:
		return localized_object
	var english_object := english as Dictionary
	if localized_object.has("title"):
		if (
			english_object.has("title")
			and typeof(english_object.get("coords", null)) == TYPE_DICTIONARY
			and not localized_object.has("coords")
		):
			localized_object.coords = (english_object.coords as Dictionary).duplicate(true)
		return localized_object
	# Previous-map branches preserve their translated leaves while inheriting
	# coordinate constraints at matching keys/indices.
	for key: Variant in localized_object.keys():
		if english_object.has(key):
			localized_object[key] = _inherit_descriptor_layout(
				localized_object[key], english_object[key]
			)
	return localized_object


func _resolve_config(
		config: Dictionary,
		map_id: int,
		prev_map_id: int,
		x: int,
		y: int,
		unknown_language: String) -> Array[Dictionary]:
	var map_locations: Variant = config.get("mapLocations", null)
	if typeof(map_locations) != TYPE_DICTIONARY:
		return [_unknown_entry(unknown_language)]
	var map_key := _map_key(map_id)
	if not map_locations.has(map_key):
		return [_unknown_entry(unknown_language)]
	var entries := _select_descriptor(
		map_locations[map_key], _map_key(prev_map_id), x, y, config
	)
	return entries if not entries.is_empty() else [_unknown_entry(unknown_language)]


func _select_descriptor(
		descriptor: Variant,
		prev_map_key: String,
		x: int,
		y: int,
		config: Dictionary) -> Array[Dictionary]:
	if typeof(descriptor) == TYPE_STRING:
		return [_make_internal_entry({"title": descriptor}, config)]
	if typeof(descriptor) == TYPE_ARRAY:
		return _select_array(descriptor as Array, prev_map_key, x, y, config)
	if typeof(descriptor) != TYPE_DICTIONARY:
		return []
	var object := descriptor as Dictionary
	if object.has("title"):
		var entry := _make_internal_entry(object, config)
		if entry.title.is_empty():
			return []
		var single: Array[Dictionary] = [entry]
		return single
	if object.has(prev_map_key):
		return _select_descriptor(object[prev_map_key], prev_map_key, x, y, config)
	if object.has("else"):
		return _select_descriptor(object["else"], prev_map_key, x, y, config)
	return []


func _select_array(
		items: Array, prev_map_key: String, x: int, y: int, config: Dictionary) -> Array[Dictionary]:
	var parsed: Array[Dictionary] = []
	var has_coordinate_entries := false
	for raw_item: Variant in items:
		var selected := _select_descriptor(raw_item, prev_map_key, x, y, config)
		for entry: Dictionary in selected:
			parsed.append(entry)
			if entry.has("coords"):
				has_coordinate_entries = true
	if not has_coordinate_entries:
		return parsed
	for entry: Dictionary in parsed:
		if entry.has("coords") and _coords_include(entry.coords, x, y):
			return [entry]
	var fallback: Array[Dictionary] = []
	for entry: Dictionary in parsed:
		if not entry.has("coords"):
			fallback.append(entry)
	return fallback


func _make_internal_entry(raw: Dictionary, config: Dictionary) -> Dictionary:
	var title := str(raw.get("title", "")).strip_edges()
	var result := {
		"title": title,
		"url_title_present": raw.has("urlTitle"),
		"url_title": raw.get("urlTitle", null),
		"unknown": false,
	}
	if not result.url_title_present:
		var title_map: Variant = config.get("locationUrlTitles", null)
		if typeof(title_map) == TYPE_DICTIONARY and title_map.has(title):
			result.url_title_present = true
			result.url_title = title_map[title]
	if raw.has("coords") and typeof(raw.coords) == TYPE_DICTIONARY:
		result.coords = (raw.coords as Dictionary).duplicate(true)
	return result


func _finalize_entries(
		entries: Array[Dictionary],
		config: Dictionary,
		english_entries: Array[Dictionary],
		english_config: Dictionary,
		allow_english_fallback: bool) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	var root_state := _url_root_state(config)
	for index in entries.size():
		var entry := entries[index]
		var url := ""
		var link_disabled := bool(entry.get("url_title_present", false)) \
			and entry.get("url_title") == null
		if not bool(entry.get("unknown", false)) and not link_disabled:
			if root_state.kind == "value":
				url = _build_url(root_state.value, entry)
			elif root_state.kind == "absent" and allow_english_fallback:
				var english_root_state := _url_root_state(english_config)
				if english_root_state.kind == "value" and index < english_entries.size():
					url = _build_url(english_root_state.value, english_entries[index])
		if not is_url_allowed(url):
			url = ""
		output.append({"title": str(entry.title), "url": url})
	return output


func _build_url(root: String, entry: Dictionary) -> String:
	if not _is_safe_https_root(root):
		return ""
	if bool(entry.get("url_title_present", false)):
		if entry.url_title == null:
			return ""
		var explicit_suffix := str(entry.url_title)
		if not explicit_suffix.is_empty():
			return root + explicit_suffix
	var suffix := str(entry.title).replace(" ", "_")
	while suffix.contains("__"):
		suffix = suffix.replace("__", "_")
	return root + suffix.uri_encode()


static func _coords_include(coords: Dictionary, x: int, y: int) -> bool:
	if not (
		coords.has("x1") and coords.has("x2")
		and coords.has("y1") and coords.has("y2")
	):
		return false
	var x1 := int(coords.x1)
	var x2 := int(coords.x2)
	var y1 := int(coords.y1)
	var y2 := int(coords.y2)
	var x_matches := (x1 == -1 and x2 == -1) or (x >= x1 and x <= x2)
	var y_matches := (y1 == -1 and y2 == -1) or (y >= y1 and y <= y2)
	return x_matches and y_matches


static func _config_ignores(config: Dictionary, map_key: String) -> bool:
	var ignored: Variant = config.get("ignoredMapIds", [])
	if typeof(ignored) != TYPE_ARRAY:
		return false
	for raw_id: Variant in ignored:
		var key := str(int(raw_id)) if typeof(raw_id) in [TYPE_INT, TYPE_FLOAT] else str(raw_id)
		if key.pad_zeros(4) == map_key:
			return true
	return false


static func _url_root_state(config: Dictionary) -> Dictionary:
	if not config.has("urlRoot"):
		return {"kind": "absent", "value": ""}
	if config.urlRoot == null:
		return {"kind": "null", "value": ""}
	var value := str(config.urlRoot)
	return {"kind": "value", "value": value}


func _collect_allowed_root(config: Dictionary) -> void:
	var state := _url_root_state(config)
	if state.kind == "value" and _is_safe_https_root(state.value):
		var root := str(state.value)
		if not _allowed_url_roots.has(root):
			_allowed_url_roots.append(root)


static func _is_safe_https_root(url: String) -> bool:
	return not _https_authority(url).is_empty()


static func _https_authority(url: String) -> String:
	if not url.to_lower().begins_with("https://") or url.length() <= 8:
		return ""
	var remainder := url.substr(8)
	var authority_end := remainder.length()
	for separator in ["/", "?", "#"]:
		var index := remainder.find(separator)
		if index >= 0:
			authority_end = mini(authority_end, index)
	var authority := remainder.substr(0, authority_end)
	if (
		authority.is_empty()
		or authority.contains("@")
		or authority.contains("\\")
		or authority.contains(" ")
		or authority.contains("\t")
		or authority.contains("\r")
		or authority.contains("\n")
	):
		return ""
	return authority.to_lower()


static func _unknown_entry(language_code: String) -> Dictionary:
	return {
		"title": str(UNKNOWN_LOCATION_LABELS.get(language_code, "Unknown Location")),
		"url_title_present": true,
		"url_title": null,
		"unknown": true,
	}


static func _map_key(map_id: int) -> String:
	return str(maxi(0, map_id)).pad_zeros(4)
