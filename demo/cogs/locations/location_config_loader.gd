class_name LocationConfigLoader
extends RefCounted

## A directory is one location source: config.json plus optional ISO language tables.
const FORMAT_ERROR := "json内容不符合格式，无法读取。请确认是否与ynolocations格式一致"
const MAX_GROUP_BYTES := 8 * 1024 * 1024
const MAX_DESCRIPTOR_DEPTH := 32
const MAX_INTEGER := 2147483647


static func load_directory(directory: String) -> Dictionary:
	directory = directory.strip_edges().simplify_path()
	var folder := DirAccess.open(directory)
	if folder == null:
		return _failure("配置目录不存在或无法读取，请重新选择。", directory)
	var files := folder.get_files()
	if not files.has("config.json"):
		return _failure("所选目录中未找到 config.json，请选择包含基础配置的目录。", directory)
	var names: Array[String] = ["config.json"]
	for filename in files:
		if _is_language_file(filename):
			names.append(filename)
	var total_bytes := 0
	var tables: Dictionary = {}
	for filename in names:
		var path := directory.path_join(filename)
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			return _failure("配置文件无法读取，请重新选择。", filename)
		total_bytes += file.get_length()
		if total_bytes > MAX_GROUP_BYTES:
			return _failure("配置文件总大小超过 8 MiB，无法读取。", filename)
		var parser := JSON.new()
		var content := file.get_as_text().trim_prefix("\ufeff")
		if parser.parse(content) != OK:
			return _failure(FORMAT_ERROR, filename, "第 %d 行：%s" % [
				parser.get_error_line(), parser.get_error_message()])
		var reason := validate_config(parser.data)
		if not reason.is_empty():
			return _failure(FORMAT_ERROR, filename, reason)
		tables[filename.get_basename()] = parser.data
	var base: Dictionary = tables["config"]
	tables.erase("config")
	return {"ok": true, "error": "", "file": "", "detail": "",
		"data": {"directory": directory, "base": base, "languages": tables}}


static func _is_language_file(filename: String) -> bool:
	if not filename.ends_with(".json"):
		return false
	var code := filename.get_basename()
	# English is always config.json; aliases such as zh-CN resolve to zh at runtime.
	# Two/three-letter codes also support languages without a built-in Unknown label.
	if code == "en" or code.length() < 2 or code.length() > 3:
		return false
	for character in code:
		if character < "a" or character > "z":
			return false
	return true


static func validate_config(value: Variant) -> String:
	if not value is Dictionary or not value.get("mapLocations") is Dictionary:
		return "mapLocations 必须是对象"
	var config: Dictionary = value
	if config.has("urlRoot") and not _string_or_null(config.urlRoot):
		return "urlRoot 必须是字符串或 null"
	if config.has("ignoredMapIds"):
		if not config.ignoredMapIds is Array:
			return "ignoredMapIds 必须是数组"
		for map_id: Variant in config.ignoredMapIds:
			if map_id is String:
				if not _is_map_key(map_id.pad_zeros(4)):
					return "ignoredMapIds 包含无效地图编号"
			elif not _integer_number(map_id) or map_id < 0:
				return "ignoredMapIds 包含无效地图编号"
	if config.has("locationUrlTitles"):
		if not config.locationUrlTitles is Dictionary:
			return "locationUrlTitles 必须是对象"
		for title: Variant in config.locationUrlTitles:
			if not title is String or not _string_or_null(config.locationUrlTitles[title]):
				return "locationUrlTitles 的值必须是字符串或 null"
	for map_id: Variant in config.mapLocations:
		if _is_comment(map_id):
			continue
		if not _is_map_key(map_id):
			return "mapLocations 包含无效地图编号"
		var reason := _validate_descriptor(config.mapLocations[map_id], 0)
		if not reason.is_empty():
			return "%s：%s" % [map_id, reason]
	return ""


static func _validate_descriptor(value: Variant, depth: int) -> String:
	if depth > MAX_DESCRIPTOR_DEPTH:
		return "地点结构嵌套超过 32 层"
	if value is String:
		return "地点名不能为空" if value.strip_edges().is_empty() else ""
	if value is Array:
		if value.is_empty():
			return "地点数组不能为空"
		for item: Variant in value:
			var reason := _validate_descriptor(item, depth + 1)
			if not reason.is_empty():
				return reason
		return ""
	if not value is Dictionary:
		return "地点必须是字符串、对象或数组"
	var object: Dictionary = value
	if object.has("title"):
		if not object.title is String or object.title.strip_edges().is_empty():
			return "title 必须是非空字符串"
		if object.has("urlTitle") and not _string_or_null(object.urlTitle):
			return "urlTitle 必须是字符串或 null"
		if object.has("coords") and not _valid_coords(object.coords):
			return "coords 必须包含有效的 x1、x2、y1、y2 整数范围"
		return ""
	var branches := 0
	for key: Variant in object:
		if _is_comment(key):
			continue
		if key != "else" and not _is_map_key(key):
			return "前序地图分支必须使用地图编号或 else"
		branches += 1
		var reason := _validate_descriptor(object[key], depth + 1)
		if not reason.is_empty():
			return reason
	return "地点分支不能为空" if branches == 0 else ""


static func _valid_coords(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	for key in ["x1", "x2", "y1", "y2"]:
		if not value.has(key) or not _integer_number(value[key]):
			return false
	for axis in ["x", "y"]:
		var first := int(value[axis + "1"])
		var last := int(value[axis + "2"])
		if first == -1 and last == -1:
			continue
		if first < 0 or last < first:
			return false
	return true


static func _integer_number(value: Variant) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) \
		and is_finite(float(value)) and absf(float(value)) <= MAX_INTEGER \
		and float(value) == floorf(float(value))


static func _is_map_key(value: Variant) -> bool:
	if not value is String or value.is_empty() or not value.is_valid_int():
		return false
	var number := int(value)
	return number >= 0 and number <= MAX_INTEGER and str(number).pad_zeros(4) == value


static func _string_or_null(value: Variant) -> bool:
	return value == null or value is String


static func _is_comment(value: Variant) -> bool:
	return value is String and value.begins_with("__comment")


static func _failure(message: String, filename: String, detail: String = "") -> Dictionary:
	return {"ok": false, "error": message, "file": filename, "detail": detail, "data": {}}
