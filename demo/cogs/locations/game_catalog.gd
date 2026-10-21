class_name GameCatalog
extends RefCounted

## Maps the original RPG Maker GameTitle to a locations slug.  Catalogs are
## deliberately data sources rather than a closed enum so a later UI can add
## user-maintained games without changing this service.

const SUPPORTED_SCHEMA_VERSION := 1

var _games: Dictionary = {}
var _alias_to_game_id: Dictionary = {}


func add_source(path: String, allow_override: bool = false) -> bool:
	var root := _read_json_object(path)
	if root.is_empty():
		return false
	if int(root.get("schemaVersion", 0)) != SUPPORTED_SCHEMA_VERSION:
		push_warning("[GameCatalog] unsupported schema version in '%s'" % path)
		return false

	var raw_games: Variant = root.get("games", null)
	if typeof(raw_games) != TYPE_DICTIONARY:
		push_warning("[GameCatalog] games must be an object in '%s'" % path)
		return false
	var locations_root := str(root.get("locationsRoot", "")).strip_edges()
	if locations_root.is_empty():
		locations_root = path.get_base_dir().path_join("locations")

	# Build a transaction first.  A bad or ambiguous source must not leave half
	# of its games installed.
	var candidate_games := _games.duplicate(true)
	var candidate_aliases := _alias_to_game_id.duplicate(true)
	var incoming_ids: Dictionary = {}
	for raw_game_id: Variant in raw_games.keys():
		if typeof(raw_game_id) != TYPE_STRING:
			return _reject(path, "game ids must be strings")
		var game_id := (raw_game_id as String).strip_edges()
		if game_id.is_empty() or incoming_ids.has(game_id):
			return _reject(path, "empty or duplicate game id '%s'" % game_id)
		incoming_ids[game_id] = true

		var raw_game: Variant = raw_games[raw_game_id]
		if typeof(raw_game) != TYPE_DICTIONARY:
			return _reject(path, "game '%s' must be an object" % game_id)
		if candidate_games.has(game_id):
			if not allow_override:
				return _reject(path, "game '%s' already exists" % game_id)
			_remove_game_aliases(game_id, candidate_aliases)

		var canonical_title := str(raw_game.get("canonicalTitle", "")).strip_edges()
		if canonical_title.is_empty():
			return _reject(path, "game '%s' has no canonicalTitle" % game_id)
		var aliases: Array[String] = [canonical_title]
		var raw_aliases: Variant = raw_game.get("titleAliases", [])
		if typeof(raw_aliases) != TYPE_ARRAY:
			return _reject(path, "game '%s' titleAliases must be an array" % game_id)
		for raw_alias: Variant in raw_aliases:
			if typeof(raw_alias) != TYPE_STRING:
				return _reject(path, "game '%s' has a non-string alias" % game_id)
			var alias := (raw_alias as String).strip_edges()
			if not alias.is_empty() and not aliases.has(alias):
				aliases.append(alias)

		var slug: Variant = raw_game.get("locationsSlug", null)
		if slug != null:
			if typeof(slug) != TYPE_STRING or not _is_safe_slug(slug as String):
				return _reject(path, "game '%s' has an unsafe locationsSlug" % game_id)

		for alias: String in aliases:
			var key := normalize_title(alias)
			if key.is_empty():
				return _reject(path, "game '%s' has an empty normalized alias" % game_id)
			if candidate_aliases.has(key) and candidate_aliases[key] != game_id:
				return _reject(
					path,
					"alias '%s' conflicts with game '%s'" % [alias, candidate_aliases[key]]
				)
			candidate_aliases[key] = game_id

		candidate_games[game_id] = {
			"game_id": game_id,
			"canonical_title": canonical_title,
			"title_aliases": aliases,
			"locations_slug": slug,
			"locations_root": locations_root,
			"catalog_path": path,
		}

	_games = candidate_games
	_alias_to_game_id = candidate_aliases
	return true


func match_title(game_title: String) -> Dictionary:
	var key := normalize_title(game_title)
	if not _alias_to_game_id.has(key):
		return {}
	var game_id: String = _alias_to_game_id[key]
	return (_games[game_id] as Dictionary).duplicate(true)


func game_count() -> int:
	return _games.size()


static func normalize_title(value: String) -> String:
	# Godot has no public NFKC helper.  GameTitle values in this catalog need the
	# compatibility normalization that matters in practice: full-width ASCII and
	# ideographic space.  All Unicode White_Space characters are then ignored so
	# old releases such as "YumeTsushin" and "Yume Tsushin" match identically.
	var normalized := ""
	for index in value.length():
		var codepoint := value.unicode_at(index)
		if _is_unicode_whitespace(codepoint):
			continue
		if codepoint >= 0xFF01 and codepoint <= 0xFF5E:
			codepoint -= 0xFEE0
		normalized += String.chr(codepoint)
	return normalized.to_lower()


static func _is_unicode_whitespace(codepoint: int) -> bool:
	return (
		(codepoint >= 0x0009 and codepoint <= 0x000D)
		or codepoint == 0x0020
		or codepoint == 0x0085
		or codepoint == 0x00A0
		or codepoint == 0x1680
		or (codepoint >= 0x2000 and codepoint <= 0x200A)
		or codepoint == 0x2028
		or codepoint == 0x2029
		or codepoint == 0x202F
		or codepoint == 0x205F
		or codepoint == 0x3000
		or codepoint == 0xFEFF
	)


static func _is_safe_slug(slug: String) -> bool:
	if slug.is_empty() or slug != slug.strip_edges():
		return false
	return not (
		slug.contains("..")
		or slug.contains("/")
		or slug.contains("\\")
		or slug.contains(":")
	)


static func _read_json_object(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning(
			"[GameCatalog] cannot open '%s': %s"
			% [path, error_string(FileAccess.get_open_error())]
		)
		return {}
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_warning(
			"[GameCatalog] invalid JSON in '%s' at line %d: %s"
			% [path, json.get_error_line(), json.get_error_message()]
		)
		return {}
	if typeof(json.data) != TYPE_DICTIONARY:
		push_warning("[GameCatalog] root must be an object in '%s'" % path)
		return {}
	return json.data as Dictionary


static func _remove_game_aliases(game_id: String, aliases: Dictionary) -> void:
	for key: Variant in aliases.keys():
		if aliases[key] == game_id:
			aliases.erase(key)


static func _reject(path: String, reason: String) -> bool:
	push_warning("[GameCatalog] rejected '%s': %s" % [path, reason])
	return false
