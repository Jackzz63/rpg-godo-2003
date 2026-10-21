extends RefCounted


static func is_safe_flat_resource_name(value: Variant, allow_empty: bool) -> bool:
	if typeof(value) != TYPE_STRING:
		return false
	var name := value as String
	if name.is_empty():
		return allow_empty
	return (name != "." and name != ".." and not name.contains("/")
		and not name.contains("\\") and not name.contains(":"))


static func is_safe_resource_path(value: Variant, allow_empty: bool) -> bool:
	if typeof(value) != TYPE_STRING:
		return false
	var name := value as String
	if name.is_empty():
		return allow_empty
	if name.contains(":"):
		return false
	var normalized := name.replace("\\", "/")
	if normalized.begins_with("/") or normalized.ends_with("/"):
		return false
	for segment in normalized.split("/", true):
		if segment.is_empty() or segment == "." or segment == "..":
			return false
	return true
