extends RefCounted

const BadSounds := preload("res://cogs/multiplayer/server_bad_sounds.gd")
const OPTIONS := ["port", "bind", "global-vars", "bad-sounds",
	"punishment-address-source", "max-connections", "max-pending-admissions",
	"data-dir", "admins-file", "punishments-file", "audit-file"]


# This is an argument editor, not a shell. Backslashes in Windows paths are literal.
static func tokenize(text: String) -> Dictionary:
	var tokens := PackedStringArray()
	var token := ""
	var quote := ""
	for character in text:
		if not quote.is_empty():
			if character == quote:
				quote = ""
			else:
				token += character
		elif character == '"' or character == "'":
			quote = character
		elif character in [" ", "\t", "\r", "\n"]:
			if not token.is_empty():
				tokens.append(token)
				token = ""
		else:
			token += character
	if not quote.is_empty():
		return _failure("引号尚未闭合。")
	if not token.is_empty():
		tokens.append(token)
	return {"ok": true, "tokens": tokens}


static func serialize(tokens: PackedStringArray) -> String:
	var parts := PackedStringArray()
	for token in tokens:
		if not (token.contains(" ") or token.contains("\t") or token.contains("\r")
				or token.contains("\n") or token.contains('"') or token.contains("'")):
			parts.append(token)
			continue
		# Adjacent quoted fragments are one token. Backslashes remain literal.
		var chunks := PackedStringArray()
		for chunk in token.split('"', true):
			chunks.append('"' + chunk + '"')
		parts.append(("'" + '"' + "'").join(chunks))
	return " ".join(parts)


static func with_preset(text: String, key: String, enabled: bool) -> Dictionary:
	var split := tokenize(text)
	if not split.ok:
		return split
	var tokens := PackedStringArray()
	for token in split.tokens:
		if not token.begins_with("--%s=" % key):
			tokens.append(token)
	if enabled:
		tokens.append("--%s=unconscious" % key)
	return {"ok": true, "text": serialize(tokens)}


static func overlay_command_line(text: String, args: PackedStringArray) -> String:
	var overrides := PackedStringArray()
	var keys := {}
	for argument in args:
		var key := argument.get_slice("=", 0).trim_prefix("--")
		if argument.begins_with("--") and key in OPTIONS:
			overrides.append(argument)
			keys[key] = true
	if overrides.is_empty():
		return text
	var split := tokenize(text)
	if not split.ok:
		return text # Keep a malformed saved draft visible and actionable.
	var tokens := PackedStringArray()
	for token in split.tokens:
		if not keys.has(token.get_slice("=", 0).trim_prefix("--")):
			tokens.append(token)
	tokens.append_array(overrides)
	return serialize(tokens)


static func parse(text: String) -> Dictionary:
	var split := tokenize(text)
	if not split.ok:
		return split
	var values := {}
	for token in split.tokens:
		var equal: int = token.find("=")
		if not token.begins_with("--") or equal < 3:
			return _failure("请使用 --参数=值：%s" % token)
		var key: String = token.substr(2, equal - 2)
		var value: String = token.substr(equal + 1)
		if key not in OPTIONS:
			return _failure("主机附加设置不支持：--%s" % key)
		if value.strip_edges().is_empty():
			return _failure("--%s 的值不能为空；关闭功能请删除该参数。" % key)
		if values.has(key) and values[key] != value:
			return _failure("--%s 出现互相冲突的重复值。" % key)
		values[key] = value
	var port := _integer(values, "port", 42424, 65535)
	if not port.ok:
		return port
	var maximum := _integer(values, "max-connections", EasyServer.MAX_CONNECTIONS,
		EasyServer.MAX_CONNECTIONS)
	if not maximum.ok:
		return maximum
	var pending := _integer(values, "max-pending-admissions",
		mini(EasyServer.DEFAULT_MAX_PENDING_ADMISSIONS, maximum.value), maximum.value)
	if not pending.ok:
		return pending
	var bind_address := str(values.get("bind", "*"))
	if bind_address not in ["*", "0.0.0.0", "127.0.0.1"]:
		return _failure("自动连接本机时，--bind 请使用 *、0.0.0.0 或 127.0.0.1。")
	var source := str(values.get("punishment-address-source", "direct")).to_lower()
	if source not in ["direct", "disabled"]:
		return _failure("客户端主机直连使用 direct 或 disabled，不经过 Nginx。")
	var global_mode := str(values.get("global-vars", "")).to_lower()
	if not global_mode.is_empty() and global_mode != "unconscious":
		return _failure("--global-vars 目前支持 unconscious；关闭时删除该参数。")
	var sounds := str(values.get("bad-sounds", ""))
	var profile := BadSounds.load_profile(sounds)
	if not profile.ok:
		return _failure("音效过滤配置不可用：%s" % profile.error)
	var directory := str(values.get("data-dir", "user://local-host"))
	return {"ok": true, "port": port.value, "bind": bind_address,
		"global_vars": global_mode, "bad_sounds": sounds, "address_source": source,
		"max_connections": maximum.value, "max_pending_admissions": pending.value,
		"admins": str(values.get("admins-file", directory.path_join("admins.json"))),
		"punishments": str(values.get("punishments-file", directory.path_join("punishments.json"))),
		"audit": str(values.get("audit-file", directory.path_join("moderation-audit.jsonl")))}


static func _integer(values: Dictionary, key: String, default_value: int, maximum: int) -> Dictionary:
	var value := str(values.get(key, str(default_value)))
	if not value.is_valid_int() or int(value) < 1 or int(value) > maximum:
		return _failure("--%s 必须为 1 至 %d 的整数。" % [key, maximum])
	return {"ok": true, "value": int(value)}


static func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message}
