extends RefCounted

## EasyRPG keyboard key catalogue copied from this build's src/keys.h.
## These IDs are not Godot Key values, Android keycodes, or browser keycodes.

static func entries() -> Array:
	var result: Array = []
	_add_many(result, "导航与编辑", [
		[1, "BACKSPACE", "退格"], [2, "TAB", "Tab"], [3, "CLEAR", "Clear"],
		[4, "RETURN", "回车"], [5, "PAUSE", "Pause"], [6, "ESCAPE", "ESC"],
		[7, "SPACE", "空格"], [8, "PGUP", "Page Up"], [9, "PGDN", "Page Down"],
		[10, "ENDS", "End"], [11, "HOME", "Home"], [12, "LEFT", "左"],
		[13, "UP", "上"], [14, "RIGHT", "右"], [15, "DOWN", "下"],
		[16, "SNAPSHOT", "Print Screen"], [17, "INSERT", "Insert"], [18, "DEL", "Delete"],
		[66, "MENU", "Menu"], [100, "AC_BACK", "AC Back"], [101, "SELECT", "Select"],
	])
	for index in range(10):
		result.append(_entry(28 + index, "N%d" % index, str(index), "普通数字 0–9"))
	for index in range(26):
		var letter := String.chr(65 + index)
		result.append(_entry(38 + index, letter, letter, "字母 A–Z"))
	for index in range(10):
		result.append(_entry(67 + index, "KP%d" % index, "Num %d" % index, "数字小键盘"))
	_add_many(result, "数字小键盘", [
		[77, "KP_MULTIPLY", "Num *"], [78, "KP_ADD", "Num +"],
		[79, "KP_SUBTRACT", "Num -"], [80, "KP_PERIOD", "Num ."],
		[81, "KP_DIVIDE", "Num /"],
	])
	for index in range(12):
		result.append(_entry(85 + index, "F%d" % (index + 1), "F%d" % (index + 1), "功能键 F1–F12"))
	_add_many(result, "修饰键", [
		[19, "SHIFT", "Shift"], [20, "LSHIFT", "Left Shift"], [21, "RSHIFT", "Right Shift"],
		[22, "CTRL", "Ctrl"], [23, "LCTRL", "Left Ctrl"], [24, "RCTRL", "Right Ctrl"],
		[25, "ALT", "Alt"], [26, "LALT", "Left Alt"], [27, "RALT", "Right Alt"],
	])
	_add_many(result, "标点符号", [
		[82, "COMMA", ","], [83, "PERIOD", "."], [84, "SLASH", "/"],
		[102, "LEFT_BRACKET", "["], [103, "RIGHT_BRACKET", "]"], [104, "BACKSLASH", "\\"],
		[105, "SEMICOLON", ";"], [106, "APOSTROPH", "'"],
	])
	_add_many(result, "锁定键及其它", [
		[64, "LOS", "Left OS"], [65, "ROS", "Right OS"],
		[97, "CAPS_LOCK", "Caps Lock"], [98, "NUM_LOCK", "Num Lock"],
		[99, "SCROLL_LOCK", "Scroll Lock"],
	])
	return result

static func categories() -> PackedStringArray:
	return PackedStringArray([
		"全部类别", "梦日记派生常用", "导航与编辑", "字母 A–Z", "普通数字 0–9", "数字小键盘",
		"功能键 F1–F12", "修饰键", "标点符号", "锁定键及其它",
	])

static func required_ids_are_valid() -> bool:
	var expected := {"H": 45, "T": 57, "F1": 85, "F12": 96, "N0": 28, "N9": 37, "KP0": 67, "KP9": 76}
	var found := {}
	for item in entries():
		found[str(item["key_name"])] = int(item["key_id"])
	for key_name in expected:
		if int(found.get(key_name, -1)) != int(expected[key_name]):
			return false
	return true

static func _add_many(result: Array, category: String, values: Array) -> void:
	for value in values:
		result.append(_entry(int(value[0]), str(value[1]), str(value[2]), category))

static func _entry(key_id: int, key_name: String, label: String, category: String) -> Dictionary:
	return {
		"key_id": key_id,
		"key_name": key_name,
		"display_label": label,
		"category": category,
	}

static func editor_entries() -> Array:
	var result := entries()
	result.append({"type": "dpad", "key_id": -1, "key_name": "DPAD", "display_label": "Dpad", "category": "导航与编辑"})
	result.append({"type": "app_action", "app_action": "chat_focus", "key_id": -1, "key_name": "APP_CHAT", "display_label": "T", "category": "应用功能"})
	result.append({"type": "app_action", "app_action": "limbo_console_toggle", "key_id": -1, "key_name": "APP_CONSOLE", "display_label": "`", "category": "应用功能"})
	return result

static func is_common(entry: Dictionary) -> bool:
	if entry.get("type") in ["dpad", "app_action"]: return true
	var key := int(entry.key_id)
	return key in [4, 6, 7, 12, 13, 14, 15, 20, 38, 40, 41, 56, 60, 61, 63, 85, 86, 96, 102, 103] or (key >= 28 and key <= 37)
