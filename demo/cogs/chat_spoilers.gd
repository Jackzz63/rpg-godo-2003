extends RefCounted


# One level of ||...||, with \| and \\ escapes. Unpaired/empty markers stay text.
# All positions use Godot character indices, just like ChatMentions.
static func parse(raw: String) -> Dictionary:
	var tokens: Array[Dictionary] = []
	var index := 0
	while index < raw.length():
		var start := index
		var value := raw[index]
		var marker := false
		if value == "\\" and index + 1 < raw.length() and raw[index + 1] in ["|", "\\"]:
			index += 1
			value = raw[index]
		elif value == "|":
			while index + 1 < raw.length() and raw[index + 1] == "|":
				index += 1
			value = raw.substr(start, index - start + 1)
			marker = value.length() == 2
		index += 1
		tokens.append({"start": start, "end": index, "text": value, "marker": marker})
	var pairs: Dictionary = {}
	var opening := -1
	for token_index in tokens.size():
		if not bool(tokens[token_index].marker):
			continue
		if opening < 0:
			opening = token_index
			continue
		var body := ""
		for body_index in range(opening + 1, token_index):
			body += str(tokens[body_index].text)
		if not body.strip_edges().is_empty():
			pairs[opening] = token_index
			pairs[token_index] = opening
		opening = -1
	var display := ""
	var mapping := PackedInt32Array()
	mapping.resize(raw.length() + 1)
	var ranges: Array[Dictionary] = []
	var active: Dictionary = {}
	for token_index in tokens.size():
		var token := tokens[token_index]
		var output := "" if pairs.has(token_index) else str(token.text)
		for raw_index in range(int(token.start), int(token.end)):
			mapping[raw_index] = display.length() + mini(raw_index - int(token.start), output.length())
		if pairs.has(token_index):
			if int(pairs[token_index]) > token_index:
				active = {"id": ranges.size(), "start": display.length(), "raw_start": int(token.start)}
			else:
				active["end"] = display.length()
				active["raw_end"] = int(token.end)
				ranges.append(active)
		display += output
		mapping[int(token.end)] = display.length()
	return {"text": display, "ranges": ranges, "raw_to_display": mapping}


static func display_mentions(mentions: Array, mapping: PackedInt32Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for value: Dictionary in mentions:
		var start := int(value.start)
		var end := start + int(value.length)
		if start < 0 or end >= mapping.size():
			continue
		var span := value.duplicate(true)
		span.start = mapping[start]
		span.length = mapping[end] - mapping[start]
		if int(span.length) > 0:
			result.append(span)
	return result


static func wrap(raw: String, start: int, end: int) -> Dictionary:
	if start < 0 or end <= start or end > raw.length():
		return {}
	for span: Dictionary in parse(raw).ranges:
		if start < int(span.raw_end) and end > int(span.raw_start):
			return {}
	var selected := raw.substr(start, end - start)
	if selected.strip_edges().is_empty():
		return {}
	var insertion := "||"
	var mapping := PackedInt32Array()
	for character in selected:
		mapping.append(insertion.length())
		if character in ["|", "\\"]:
			insertion += "\\"
		insertion += character
	mapping.append(insertion.length())
	insertion += "||"
	var proposed := raw.left(start) + insertion + raw.substr(end)
	for span: Dictionary in parse(proposed).ranges:
		if int(span.raw_start) == start and int(span.raw_end) == start + insertion.length():
			return {"insertion": insertion, "offsets": mapping}
	return {}
