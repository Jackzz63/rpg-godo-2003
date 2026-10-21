class_name LocalMenuTheme
extends Node
## Local UI theme lifetime follows the loaded game, independently of networking.

signal changed

var _engine: Node
var _system_name := ""


func set_engine(engine: Node) -> void:
	if is_instance_valid(_engine) and _engine.player_system_changed.is_connected(_on_system_changed):
		_engine.player_system_changed.disconnect(_on_system_changed)
	_engine = engine
	_system_name = ""
	if is_instance_valid(_engine):
		_engine.player_system_changed.connect(_on_system_changed)
	changed.emit()


func active() -> bool:
	return is_instance_valid(_engine) and _engine.is_running()


func refresh() -> void:
	if not active():
		_system_name = ""
	changed.emit()


func _on_system_changed(system_name: String) -> void:
	_system_name = system_name
	changed.emit()


func get_menu_system_texture(system_name: String = "") -> Texture2D:
	return _engine.get_system_texture(system_name) if active() else null


func get_local_player_snapshot() -> Dictionary:
	return {"system_name": _system_name,
		"system_stretch": _engine.get_current_system_stretch() if active() else 1}


func get_current_menu_theme_colors() -> Dictionary:
	var texture := get_menu_system_texture()
	return SystemThemePalette.colors_from_image(texture.get_image()) if texture != null else {}
