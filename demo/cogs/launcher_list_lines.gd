extends Node
## Launcher single-line ItemLists and enum PopupMenus retain native drawing/input.
## Only visible ItemList text is measured; scrolling offsets the row color bands.
const SHADER := preload("res://resources/webpage_theme_text.gdshader")
const SYSTEM := preload("res://resources/orchidmantis_system_celestial.png")
var control: Control
var menu: PopupMenu
var _last_lines: Array[Vector2] = []
var _last_height := -1
var _text_heights: Dictionary = {}
var _font_key: Array = []


static func install(list: ItemList) -> void:
	var binding := list.get_node_or_null("__AndroidListLines")
	if binding == null:
		binding = new()
		binding.name = "__AndroidListLines"
		binding.control = list
		list.add_child(binding)
	binding.refresh.call_deferred()


static func install_popup(popup: PopupMenu, scroll: ScrollContainer, text_material: ShaderMaterial = null) -> void:
	for child: Node in scroll.get_children(true):
		if not child is Control or child is ScrollBar:
			continue
		var binding := child.get_node_or_null("__AndroidListLines")
		if binding == null:
			binding = new()
			binding.name = "__AndroidListLines"
			binding.control = child
			binding.menu = popup
			var material := ShaderMaterial.new()
			material.shader = SHADER
			var strip := ImageTexture.create_from_image(SYSTEM.get_image().get_region(Rect2i(0, 48, 1, 16)))
			for role: String in ["normal_strip", "strong_strip", "muted_strip"]:
				material.set_shader_parameter(role, strip)
			child.material = material
			child.add_child(binding)
		if text_material != null:
			child.material = text_material.duplicate()
			binding._last_height = -1
		binding.refresh.call_deferred()
		return


func _ready() -> void:
	control.draw.connect(refresh)
	control.resized.connect(refresh.call_deferred)
	control.theme_changed.connect(refresh.call_deferred)
	if control is ItemList:
		control.get_v_scroll_bar().value_changed.connect(func(_value: float): refresh())


func _height(text: String, font: Font, font_size: int) -> float:
	if _font_key != [font, font_size]:
		_font_key = [font, font_size]
		_text_heights.clear()
	if not _text_heights.has(text):
		var line := TextLine.new()
		line.add_string(text, font, font_size)
		_text_heights[text] = line.get_size().y
	return float(_text_heights[text])


func refresh() -> void:
	if not is_instance_valid(control) or not control.material is ShaderMaterial:
		return
	var lines: Array[Vector2] = []
	var font: Font = menu.get_theme_font("font") if menu != null else control.get_theme_font("font")
	var font_size: int = menu.get_theme_font_size("font_size") if menu != null else control.get_theme_font_size("font_size")
	if control is ItemList and control.item_count > 0:
		var list := control as ItemList
		var offset := list.get_v_scroll_bar().value
		var first := maxi(0, list.get_item_at_position(Vector2(4, 0), false) - 1)
		for index in range(first, list.item_count):
			var rect := list.get_item_rect(index)
			rect.position.y -= offset
			if rect.position.y > list.size.y:
				break
			if rect.end.y < 0:
				continue
			var height := _height(list.get_item_text(index), font, font_size)
			lines.append(Vector2(rect.position.y + floorf((rect.size.y - height) / 2.0), height))
	elif menu != null:
		var separation := menu.get_theme_constant("v_separation")
		var y := float(separation / 2)
		for index in menu.item_count:
			var height := _height(menu.get_item_text(index), font, font_size)
			var row_height := height
			if menu.is_item_checkable(index) or menu.is_item_radio_checkable(index):
				row_height = maxf(row_height, maxf(menu.get_theme_icon("checked").get_height(), menu.get_theme_icon("radio_checked").get_height()))
			var icon := menu.get_item_icon(index)
			if icon != null:
				row_height = maxf(row_height, icon.get_height())
			lines.append(Vector2(y + floorf((row_height - height) / 2.0), height))
			y += row_height + separation
	var height := maxi(1, ceili(control.size.y))
	if lines == _last_lines and height == _last_height:
		return
	_last_lines = lines
	_last_height = height
	var material := control.material as ShaderMaterial
	material.set_shader_parameter("use_line_map", not lines.is_empty())
	if lines.is_empty():
		return
	var lookup := Image.create(1, height, false, Image.FORMAT_RF)
	var line_index := 0
	for y in height:
		while line_index + 1 < lines.size() and float(y) + 0.5 >= lines[line_index + 1].x:
			line_index += 1
		var line := lines[line_index]
		lookup.set_pixel(0, y, Color(clampf((y + 0.5 - line.x) / maxf(1, line.y), 0, 0.999999), 0, 0, 1))
	material.set_shader_parameter("line_map", ImageTexture.create_from_image(lookup))
	material.set_shader_parameter("line_map_height", float(height))
