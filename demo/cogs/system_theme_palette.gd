class_name SystemThemePalette
extends RefCounted

const _CELL_SIZE := 16
const _TABLE_Y := 48
const _SAMPLE_Y := 8
const _NORMAL_INDEX := 0
const _ALTERNATE_INDEX := 1
const _MUTED_INDEX := 3


static func strong_style_index(image: Image) -> int:
	if not _is_usable_image(image):
		return _ALTERNATE_INDEX
	for row in range(_CELL_SIZE):
		var normal := image.get_pixel(
			_NORMAL_INDEX * _CELL_SIZE, _TABLE_Y + row)
		var alternate := image.get_pixel(
			_ALTERNATE_INDEX * _CELL_SIZE, _TABLE_Y + row)
		if not _same_rgb(normal, alternate):
			return _ALTERNATE_INDEX
	return _MUTED_INDEX


static func colors_from_image(image: Image) -> Dictionary:
	if not _is_usable_image(image):
		return {}
	var strong_index := strong_style_index(image)
	return {
		"normal": _sample(image, _NORMAL_INDEX),
		"strong": _sample(image, strong_index),
		"muted": _sample(image, _MUTED_INDEX),
		"strong_index": strong_index,
	}


static func _is_usable_image(image: Image) -> bool:
	return (image != null and not image.is_empty()
		and image.get_width() >= _CELL_SIZE * 4
		and image.get_height() >= _TABLE_Y + _CELL_SIZE)


static func _sample(image: Image, style_index: int) -> Color:
	var color := image.get_pixel(
		style_index * _CELL_SIZE, _TABLE_Y + _SAMPLE_Y)
	color.a = 1.0
	return color


static func _same_rgb(first: Color, second: Color) -> bool:
	return (is_equal_approx(first.r, second.r)
		and is_equal_approx(first.g, second.g)
		and is_equal_approx(first.b, second.b))
