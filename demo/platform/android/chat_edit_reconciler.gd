extends RefCounted

# The journal's ranges refer to the native buffer, which may still contain text
# removed by the semantic editor (an atomic mention or the wire-length limit).
# Map every raw boundary through each accepted replacement, rather than guessing
# intent from a longest-common-prefix diff. Equal-text replacements remain edits.
static func apply(field: LineEdit, baseline: Dictionary, edits: Array,
		raw_text: String, selection: Vector2i) -> bool:
	var raw: String = baseline.state.text
	for edit: Dictionary in edits:
		var a := int(edit.a)
		var b := int(edit.b)
		if a < 0 or b < a or b > raw.length() or not edit.text is String:
			return false
		raw = raw.left(a) + str(edit.text) + raw.substr(b)
	if raw != raw_text:
		return false
	var saved: Dictionary = field.edit_checkpoint()
	field.restore_edit_checkpoint(baseline)
	var mapping: Array[int] = []
	for i in str(baseline.state.text).length() + 1:
		mapping.append(i)
	var previous_group := -1
	field.set("_handling_native_change", true)
	for edit: Dictionary in edits:
		var a := int(edit.a)
		var b := int(edit.b)
		var insertion := str(edit.text)
		var bounds: Vector2i = field.call("_expanded", mapping[a], mapping[b])
		var old_length := field.text.length()
		var group := int(edit.get("group", 0))
		if not field.replace_range(mapping[a], mapping[b], insertion, [], group != previous_group):
			field.restore_edit_checkpoint(saved)
			field.set("_handling_native_change", false)
			return false
		previous_group = group
		var inserted := field.text.length() - old_length + bounds.y - bounds.x
		var next: Array[int] = []
		for i in a:
			next.append(_map(mapping[i], bounds, inserted, false))
		for i in insertion.length() + 1:
			var clean_prefix := insertion.left(i).replace("\uFFFF", "").replace("\uFFFE", "")
			next.append(bounds.x + mini(inserted, clean_prefix.length()))
		for i in range(b + 1, mapping.size()):
			next.append(_map(mapping[i], bounds, inserted, true))
		mapping = next
	field.set_edit_selection(mapping[clampi(selection.x, 0, mapping.size() - 1)],
		mapping[clampi(selection.y, 0, mapping.size() - 1)])
	field.set("_handling_native_change", false)
	field.finish_external_reconcile()
	return true


static func _map(value: int, bounds: Vector2i, inserted: int, after: bool) -> int:
	if value < bounds.x:
		return value
	if value > bounds.y:
		return value + inserted - (bounds.y - bounds.x)
	return bounds.x + inserted if after else bounds.x
