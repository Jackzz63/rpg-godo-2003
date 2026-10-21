extends Node
## Opt-in input backgrounds. Keep the launcher's native design metrics, scaled
## once from the original theme; chat and other editors are not enrolled.
var _field: Control


static func install(field: Control) -> void:
	if field.has_node("__InputFieldStyle"): return
	var binding := new()
	binding.name = "__InputFieldStyle"
	binding._field = field
	field.add_child(binding)


func _ready() -> void:
	UiScale.scale_changed.connect(_refresh)
	_refresh(UiScale.get_ui_scale())


func _refresh(density: float) -> void:
	apply(_field, density)


static func apply(field: Control, density: float) -> void:
	if field.get_meta(&"input_field_density", -1.0) == density: return
	field.set_meta(&"input_field_density", density)
	UiScale.mark_styles_physical(field)
	var type := "TextEdit" if field is TextEdit else "LineEdit"
	var defaults := ThemeDB.get_default_theme()
	field.begin_bulk_theme_override()
	for key: StringName in defaults.get_stylebox_list(type):
		field.add_theme_stylebox_override(key,
			UiScale.physical_stylebox(defaults.get_stylebox(key, type), -1.0, density))
	field.end_bulk_theme_override()
