extends RefCounted

const SCHEMA_VERSION := 4
const WEB_DEFAULT_OPACITY := 0.4
const ALIGNMENTS := ["default", "bottom", "center", "custom"]
const SUPPORTED_APP_ACTIONS := ["limbo_console_toggle", "chat_focus"]

static func default_state() -> Dictionary:
	return {
		"enabled": true, "opacity": WEB_DEFAULT_OPACITY, "show_key_labels": true, "panel_dock": "left",
		"layouts": {"portrait": default_layout(), "landscape": default_layout()},
		"group_settings": default_group_settings(),
	}

static func default_group_settings() -> Dictionary:
	return {
		"portrait": {"alignment": "default", "offset": 0.0, "custom_initialized": false},
		"landscape": {"alignment": "default", "offset": 0.0, "custom_initialized": false},
	}

static func decode(cfg: ConfigFile) -> Dictionary:
	var state := default_state()
	var schema := int(cfg.get_value("general", "schema_version", -1))
	state["schema"] = schema
	if schema == 1:
		state.enabled = bool(cfg.get_value("general", "enabled", true))
		state.opacity = clampf(float(cfg.get_value("general", "opacity", WEB_DEFAULT_OPACITY)), 0.1, 1.0)
		state.show_key_labels = true
		return state
	if schema == -1 and cfg.has_section_key("general", "enabled"):
		state.enabled = bool(cfg.get_value("general", "enabled", true))
		return state
	if schema not in [2, 3, SCHEMA_VERSION]:
		return state
	var portrait = cfg.get_value("portrait", "controls", null)
	var landscape = cfg.get_value("landscape", "controls", null)
	if not _is_valid_layout(portrait) or not _is_valid_layout(landscape):
		return state
	state.enabled = bool(cfg.get_value("general", "enabled", true))
	state.opacity = clampf(float(cfg.get_value("general", "opacity", WEB_DEFAULT_OPACITY)), 0.1, 1.0)
	state.show_key_labels = bool(cfg.get_value("general", "show_key_labels", true))
	state.panel_dock = str(cfg.get_value("general", "panel_dock", "left"))
	if state.panel_dock == "bottom": state.panel_dock = "center"
	if state.panel_dock not in ["left", "right", "center"]:
		state.panel_dock = "left"
	state.layouts = {"portrait": _sanitize_layout(portrait), "landscape": _sanitize_layout(landscape)}
	for orientation: String in ["portrait", "landscape"]:
		var alignment := str(cfg.get_value(orientation, "vertical_alignment", "bottom"))
		var offset := float(cfg.get_value(orientation, "vertical_offset", 0.0))
		state.group_settings[orientation] = {
			"alignment": alignment if alignment in ALIGNMENTS else "bottom",
			"offset": clampf(offset, -1.0, 1.0) if is_finite(offset) else 0.0,
		}
		var group: Dictionary = state.group_settings[orientation]
		if schema < 4 and not is_zero_approx(group.offset):
			group["legacy_custom_basis"] = group.alignment
			group.alignment = "custom"
			group["custom_initialized"] = true
		elif schema == 4:
			group["custom_initialized"] = bool(cfg.get_value(orientation, "custom_initialized", false))
			var basis := str(cfg.get_value(orientation, "legacy_custom_basis", ""))
			if basis in ["default", "bottom", "center"]: group["legacy_custom_basis"] = basis
	if schema == 2:
		_append_missing_chat_control(state.layouts["portrait"])
		_append_missing_chat_control(state.layouts["landscape"])
	return state

static func encode(state: Dictionary) -> ConfigFile:
	var cfg := ConfigFile.new()
	cfg.set_value("general", "schema_version", SCHEMA_VERSION)
	cfg.set_value("general", "enabled", state.enabled)
	cfg.set_value("general", "opacity", state.opacity)
	cfg.set_value("general", "show_key_labels", state.show_key_labels)
	cfg.set_value("general", "panel_dock", state.panel_dock)
	cfg.set_value("portrait", "controls", state.layouts["portrait"])
	cfg.set_value("landscape", "controls", state.layouts["landscape"])
	for orientation: String in ["portrait", "landscape"]:
		cfg.set_value(orientation, "vertical_alignment", state.group_settings[orientation].alignment)
		cfg.set_value(orientation, "vertical_offset", state.group_settings[orientation].offset)
		cfg.set_value(orientation, "custom_initialized", state.group_settings[orientation].get("custom_initialized", false))
		if state.group_settings[orientation].has("legacy_custom_basis"):
			cfg.set_value(orientation, "legacy_custom_basis", state.group_settings[orientation].legacy_custom_basis)
	return cfg

static func _append_missing_chat_control(layout: Array) -> void:
	for control in layout:
		if str(control.get("type", "")) == "app_action" \
				and str(control.get("app_action", "")) == "chat_focus":
			return
	layout.append(app_action_control("chat_focus", "T", "chat"))

static func _is_valid_layout(value) -> bool:
	if not value is Array:
		return false
	for raw_control in value:
		if not raw_control is Dictionary:
			return false
		var kind := str(raw_control.get("type", ""))
		if kind not in ["key", "dpad", "editor_menu", "app_action"]:
			return false
		if kind == "key" and (int(raw_control.get("key_id", -1)) < 1 or int(raw_control.get("key_id", -1)) > 106):
			return false
		if kind == "app_action" and str(raw_control.get("app_action", "")) not in SUPPORTED_APP_ACTIONS:
			return false
		for field in ["normalized_x", "normalized_y", "width_ratio", "height_ratio"]:
			var value_type := typeof(raw_control.get(field, null))
			if value_type != TYPE_FLOAT and value_type != TYPE_INT:
				return false
		if raw_control.has("label_visible_override") and typeof(raw_control.label_visible_override) != TYPE_BOOL: return false
		if typeof(raw_control.get("visible", true)) != TYPE_BOOL:
			return false
	return true

static func _sanitize_layout(value: Array) -> Array:
	var result: Array = []
	for raw_control in value:
		var control: Dictionary = raw_control
		# Earlier Android test builds could persist the removed floating menu.
		# Accept those files, but do not recreate the obsolete three-line button.
		if str(control.get("type", "")) == "editor_menu":
			continue
		var clean := {
			"type": str(control.get("type", "key")),
			"key_id": int(control.get("key_id", -1)),
			"key_name": str(control.get("key_name", "")),
			"display_label": str(control.get("display_label", "")),
			"shape": str(control.get("shape", "circle")),
			"normalized_x": clampf(float(control.get("normalized_x", 0.5)), 0.0, 1.0),
			"normalized_y": clampf(float(control.get("normalized_y", 0.5)), 0.0, 1.0),
			"width_ratio": clampf(float(control.get("width_ratio", 1.0)), 0.15, 3.0),
			"height_ratio": clampf(float(control.get("height_ratio", 1.0)), 0.15, 3.0),
			"visible": bool(control.get("visible", true)),
		}
		if str(control.get("type", "")) == "app_action":
			clean["app_action"] = str(control.get("app_action", ""))
			if clean.app_action == "chat_focus" and clean.display_label == "聊天":
				clean.display_label = "T"
		if clean.shape == "square": clean.shape = "rectangle"
		if control.has("label_visible_override"):
			clean["label_visible_override"] = bool(control.label_visible_override)
		var web_slot := str(control.get("web_slot", ""))
		if not web_slot.is_empty():
			clean["web_slot"] = web_slot
		result.append(clean)
	return result

static func default_layout() -> Array:
	return [
		dpad_control("dpad"),
		key_control(6, "ESCAPE", "B", "circle", 1.0, 1.0, "escape"),
		key_control(4, "RETURN", "A", "circle", 1.0, 1.0, "enter"),
		key_control(20, "LSHIFT", "Shift", "rectangle", 0.6, 0.4, "shift"),
		key_control(29, "N1", "1", "rectangle", 0.3, 0.3, "digit1"),
		key_control(31, "N3", "3", "rectangle", 0.3, 0.3, "digit3"),
		key_control(33, "N5", "5", "rectangle", 0.3, 0.3, "digit5"),
		key_control(37, "N9", "9", "rectangle", 0.3, 0.3, "digit9"),
		app_action_control("chat_focus", "T", "chat"),
	]

static func dpad_control(web_slot: String = "") -> Dictionary:
	var control := {
		"type": "dpad", "key_id": -1, "key_name": "DPAD", "display_label": "",
		"shape": "rectangle", "normalized_x": 0.0, "normalized_y": 0.0,
		"width_ratio": 2.0, "height_ratio": 2.0, "visible": true,
	}
	if not web_slot.is_empty():
		control["web_slot"] = web_slot
	return control

static func key_control(key_id: int, key_name: String, label: String, shape: String, width_ratio: float, height_ratio: float, web_slot: String = "") -> Dictionary:
	var control := {
		"type": "key", "key_id": key_id, "key_name": key_name, "display_label": label,
		"shape": shape, "normalized_x": 0.5, "normalized_y": 0.5,
		"width_ratio": width_ratio, "height_ratio": height_ratio, "visible": true,
	}
	if not web_slot.is_empty():
		control["web_slot"] = web_slot
	return control

static func app_action_control(action: String, label: String = "Console", web_slot: String = "") -> Dictionary:
	var control := {
		"type": "app_action", "app_action": action, "key_id": -1,
		"key_name": "APP_CHAT" if action == "chat_focus" else "APP_CONSOLE", "display_label": label,
		"shape": "rectangle", "normalized_x": 0.5, "normalized_y": 0.5,
		"width_ratio": 1.1, "height_ratio": 0.55, "visible": true,
	}
	if not web_slot.is_empty():
		control["web_slot"] = web_slot
	return control
