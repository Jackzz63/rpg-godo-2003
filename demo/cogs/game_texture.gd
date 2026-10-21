extends TextureRect

@export var engine: RPGMakerPlayer
var _bound_texture: Texture2D

func _ready() -> void:
	if not is_instance_valid(engine):
		return
	engine.resolution_changed.connect(_on_resolution_changed)
	_bind_frame_texture()

func _exit_tree() -> void:
	if is_instance_valid(engine) and engine.resolution_changed.is_connected(_on_resolution_changed):
		engine.resolution_changed.disconnect(_on_resolution_changed)
	if is_instance_valid(_bound_texture) and _bound_texture.changed.is_connected(_on_frame_changed):
		_bound_texture.changed.disconnect(_on_frame_changed)

func _on_resolution_changed(_width: int, _height: int) -> void:
	_bind_frame_texture()

func _bind_frame_texture() -> void:
	var next := engine.get_frame_texture()
	if next != _bound_texture:
		if is_instance_valid(_bound_texture) and _bound_texture.changed.is_connected(_on_frame_changed):
			_bound_texture.changed.disconnect(_on_frame_changed)
		_bound_texture = next
		texture = next
		if is_instance_valid(next):
			next.changed.connect(_on_frame_changed)
	_on_frame_changed()

func _on_frame_changed() -> void:
	var target := get_parent() as SubViewport
	if is_instance_valid(target):
		# The renderer consumes UPDATE_ONCE internally; do not compare the getter.
		target.render_target_update_mode = SubViewport.UPDATE_ONCE
		ClientPerformance.count_event(&"engine.viewport_update_requests")
