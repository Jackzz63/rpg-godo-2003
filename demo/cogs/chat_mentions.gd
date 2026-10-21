extends RefCounted

const InputLimits := preload("res://cogs/input_limits.gd")
const MAX_TEXT := InputLimits.CHAT_MESSAGE_MAX_CHARACTERS
const MAX_MENTIONS := 50
const PER_FIELD := 25
const PlayerName := preload("res://cogs/chat_player_name.gd")
const UNNAMED_TOKEN := "@<Unnamed Player>"


static func normalize_text(value: String) -> String:
	return value.replace("\uFFFF", "").replace("\uFFFE", "").left(MAX_TEXT)


static func valid_id(value: String) -> bool:
	if value.length() != 32:
		return false
	for c in value:
		if not c in "0123456789abcdef":
			return false
	return true


# Offsets are Unicode character indices in the body, never UTF-8 byte offsets.
static func valid_spans(body: String, spans: Array) -> bool:
	if body != normalize_text(body) or spans.size() > MAX_MENTIONS:
		return false
	var previous_end := 0
	for value in spans:
		if not value is Dictionary:
			return false
		var span: Dictionary = value
		if typeof(span.get("start")) != TYPE_INT or typeof(span.get("length")) != TYPE_INT:
			return false
		var start: int = span.start
		var length: int = span.length
		if start < previous_end or length < 2 or start + length > body.length():
			return false
		if not valid_id(str(span.get("public_chat_id", ""))):
			return false
		var token := body.substr(start, length)
		if token != UNNAMED_TOKEN and (length > InputLimits.NICKNAME_MAX_ASCII_CHARACTERS + 1 or not token.begins_with("@")
				or InputLimits.sanitize_nickname(token.substr(1)) != token.substr(1)):
			return false
		previous_end = start + length
	return true


static func has_unnamed(body: String, spans: Array) -> bool:
	for span: Dictionary in spans:
		if body.substr(int(span.start), int(span.length)) == UNNAMED_TOKEN:
			return true
	return false


# These projections only replace identity-bearing spans. Identical plain text
# stays literal. Editor spans remember the semantic kind across locale changes.
static func to_display(body: String, spans: Array, language: String) -> Dictionary:
	return _project(body, spans, language, false)


static func to_wire(body: String, spans: Array) -> Dictionary:
	return _project(body, spans, "en", true)


static func _project(body: String, spans: Array, language: String, wire: bool) -> Dictionary:
	var output := ""
	var result: Array[Dictionary] = []
	var mapping := PackedInt32Array()
	mapping.resize(body.length() + 1)
	var inverse := PackedInt32Array([0])
	var cursor := 0
	for value: Dictionary in spans:
		var start := int(value.start)
		var length := int(value.length)
		var token := body.substr(start, length)
		var unnamed := bool(value.get("is_unnamed", false)) or (not wire and token == UNNAMED_TOKEN)
		var replacement := token
		if unnamed:
			replacement = UNNAMED_TOKEN if wire else "@" + PlayerName.display("", language)
		while cursor < start:
			mapping[cursor] = output.length()
			output += body[cursor]
			cursor += 1
			inverse.append(cursor)
		var offset := output.length()
		for i in range(length + 1):
			mapping[start + i] = offset + int(float(i * replacement.length()) / length)
		for i in range(1, replacement.length() + 1):
			inverse.append(start + int(float(i * length) / replacement.length()))
		var span := value.duplicate(true)
		span.start = offset
		span.length = replacement.length()
		if wire:
			span.erase("is_unnamed")
		elif unnamed:
			span["is_unnamed"] = true
		result.append(span)
		output += replacement
		cursor = start + length
	while cursor < body.length():
		mapping[cursor] = output.length()
		output += body[cursor]
		cursor += 1
		inverse.append(cursor)
	mapping[body.length()] = output.length()
	return {"text": output, "mentions": result, "mapping": mapping, "inverse": inverse}


static func mapped_offset(mapping: PackedInt32Array, offset: int) -> int:
	return mapping[clampi(offset, 0, mapping.size() - 1)] if not mapping.is_empty() else offset


# Two bounded fields: at most 25 * 38 + 24 = 974 characters each.
# This stays within the existing 1024-character argument limit.
static func encode(spans: Array) -> Array[String]:
	var parts: Array[String] = ["", ""]
	for i in spans.size():
		var span: Dictionary = spans[i]
		var field := 0 if i < PER_FIELD else 1
		if not parts[field].is_empty():
			parts[field] += ","
		parts[field] += "%d:%d:%s" % [span.start, span.length, span.public_chat_id]
	return parts


static func decode(body: String, first: String, second: String) -> Variant:
	var spans: Array[Dictionary] = []
	for field in [first, second]:
		if field.length() > 1024:
			return null
		if field.is_empty():
			continue
		var entries: PackedStringArray = field.split(",", true)
		if entries.size() > PER_FIELD:
			return null
		for entry in entries:
			var values := entry.split(":", true)
			if values.size() != 3 or not _decimal(values[0]) or not _decimal(values[1]):
				return null
			spans.append({"start": int(values[0]), "length": int(values[1]), "public_chat_id": values[2]})
	return spans if valid_spans(body, spans) else null


static func _decimal(value: String) -> bool:
	if value.is_empty() or value.length() > 2:
		return false
	for c in value:
		if not c in "0123456789":
			return false
	return true


static func contains_target(spans: Array, public_id: String) -> bool:
	if public_id.is_empty():
		return false
	for span in spans:
		if str(span.get("public_chat_id", "")) == public_id:
			return true
	return false
