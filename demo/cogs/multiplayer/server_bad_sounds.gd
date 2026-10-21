extends RefCounted

const PROFILE_DIRECTORY := "res://config/server/bad_sounds/"
const OPTION_PREFIX := "--bad-sounds="


static func parse_options(args: PackedStringArray) -> Dictionary:
	var profile := ""
	for argument in args:
		if argument == "--bad-sounds":
			return {"ok": false, "profile": "", "error": "use --bad-sounds=<profile>"}
		if not argument.begins_with(OPTION_PREFIX):
			continue
		var selected := argument.substr(OPTION_PREFIX.length())
		if not _is_valid_profile(selected):
			return {
				"ok": false, "profile": "",
				"error": "bad-sounds profile must contain only a-z, 0-9, _ or - and cannot be empty",
			}
		if not profile.is_empty() and profile != selected:
			return {"ok": false, "profile": "", "error": "conflicting --bad-sounds profiles"}
		profile = selected
	return {"ok": true, "profile": profile, "error": ""}


static func parse_config(text: String) -> Dictionary:
	var parser := JSON.new()
	if parser.parse(text) != OK:
		return {
			"ok": false, "names": {},
			"error": "invalid JSON at line %d: %s" % [
				parser.get_error_line(), parser.get_error_message()],
		}
	var data: Variant = parser.data
	if typeof(data) != TYPE_DICTIONARY:
		return {"ok": false, "names": {}, "error": "bad-sounds config must be a JSON object"}
	if not data.has("bad_sounds") or typeof(data["bad_sounds"]) != TYPE_STRING:
		return {"ok": false, "names": {}, "error": "bad_sounds must be a string"}
	var names: Dictionary = {}
	var configured_names: String = data["bad_sounds"]
	for entry in configured_names.split(",", false):
		var name := entry.strip_edges()
		if not name.is_empty():
			names[normalize_name(name)] = true
	return {"ok": true, "names": names, "error": ""}


static func load_profile(profile: String) -> Dictionary:
	if profile.is_empty():
		return {"ok": true, "names": {}, "error": ""}
	if not _is_valid_profile(profile):
		return {"ok": false, "names": {}, "error": "invalid bad-sounds profile name"}
	var path := PROFILE_DIRECTORY + profile + ".json"
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {
			"ok": false, "names": {},
			"error": "cannot read %s: %s" % [path, error_string(FileAccess.get_open_error())],
		}
	var text := file.get_as_text()
	file.close()
	var result := parse_config(text)
	if not result["ok"]:
		result["error"] = "%s: %s" % [path, result["error"]]
	return result


static func normalize_name(name: String) -> String:
	# These are logical resource names: preserve dots, suffixes and subdirectories.
	var normalized := ""
	for index in range(name.length()):
		var code := name.unicode_at(index)
		if code == 92: # Backslash.
			code = 47
		elif code >= 65 and code <= 90: # ASCII A-Z.
			code += 32
		normalized += String.chr(code)
	return normalized


static func _is_valid_profile(profile: String) -> bool:
	if profile.is_empty():
		return false
	for index in range(profile.length()):
		var code := profile.unicode_at(index)
		if not ((code >= 97 and code <= 122) or (code >= 48 and code <= 57)
				or code == 95 or code == 45):
			return false
	return true
