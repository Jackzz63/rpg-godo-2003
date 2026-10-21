extends RefCounted


static func read(path: String) -> Dictionary:
	var config := ConfigFile.new()
	var error := config.load(path)
	# Preserve ConfigFile's partial contents on a parse failure; callers choose
	# their existing fallback policy separately for each setting.
	return {"config": config, "error": error}


static func patch(path: String, values: Dictionary, erased_keys: Dictionary = {}) -> Dictionary:
	var loaded := read(path)
	if loaded.error != OK and loaded.error != ERR_FILE_NOT_FOUND:
		return {"error": loaded.error, "stage": "load"}
	var config: ConfigFile = loaded.config
	_write_values(config, values)
	for section in erased_keys:
		for key in erased_keys[section]:
			if config.has_section_key(section, key):
				config.erase_section_key(section, key)
	return {"error": config.save(path), "stage": "save"}


static func replace(path: String, values: Dictionary) -> Error:
	var config := ConfigFile.new()
	_write_values(config, values)
	return config.save(path)


static func _write_values(config: ConfigFile, values: Dictionary) -> void:
	for section in values:
		for key in values[section]:
			config.set_value(section, key, values[section][key])
