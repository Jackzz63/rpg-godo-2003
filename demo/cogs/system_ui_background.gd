@tool
extends StyleBox
## System backgrounds use one window-based period, independently of text/dp scale.

@export var texture: Texture2D:
	set(value):
		if texture != null and texture.changed.is_connected(_invalidate):
			texture.changed.disconnect(_invalidate)
		texture = value
		if texture != null:
			texture.changed.connect(_invalidate)
		_invalidate()
@export var region_rect := Rect2(0, 0, 32, 32):
	set(value):
		region_rect = value
		_invalidate()

var _source: Image
var _tiles: Dictionary = {}
var _base_scale := -1.0
var _root: Window
var _scale_source: Node


func _invalidate() -> void:
	_source = null
	_tiles.clear()
	emit_changed()


func _window_scale_changed(_value: float = 0.0) -> void:
	# Game UI scaling does not change the window-based tile period.
	var scale := _window_scale()
	if is_equal_approx(scale, _base_scale):
		return
	_base_scale = scale
	_tiles.clear()
	emit_changed()


func _window_scale() -> float:
	if Engine.is_editor_hint():
		return 1.0
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return 1.0
	if not is_instance_valid(_root):
		_root = tree.root
		_root.size_changed.connect(_window_scale_changed)
	if not is_instance_valid(_scale_source):
		_scale_source = _root.get_node_or_null("UiScale")
		if _scale_source != null:
			_scale_source.scale_changed.connect(_window_scale_changed)
	if _scale_source != null:
		return float(_scale_source.scale_for_size(_root.size))
	return minf(float(_root.size.x) / 640.0, float(_root.size.y) / 480.0)


func tile_side_for_size(size: Vector2) -> int:
	return maxi(1, floori(minf(64.0 * _window_scale(), minf(size.x, size.y))))


func _draw(canvas_item: RID, rect: Rect2) -> void:
	if texture == null or rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	var scale := _window_scale()
	if not is_equal_approx(scale, _base_scale):
		_base_scale = scale
		_tiles.clear()
	var side := tile_side_for_size(rect.size)
	if not _tiles.has(side):
		if _source == null:
			var pixels := texture.get_image()
			if pixels == null or pixels.is_empty():
				return
			pixels = pixels.duplicate()
			if pixels.is_compressed() and pixels.decompress() != OK:
				return
			_source = pixels.get_region(Rect2i(region_rect))
		var tile := _source.duplicate()
		tile.resize(side, side, Image.INTERPOLATE_NEAREST)
		_tiles[side] = ImageTexture.create_from_image(tile)
	# Cached per size: shared buttons and panels never overwrite each other's tile.
	(_tiles[side] as Texture2D).draw_rect(canvas_item, rect, true)
