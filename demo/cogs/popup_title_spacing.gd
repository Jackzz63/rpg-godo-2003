extends Node
## Local title spacing; controls below the title retain their existing row gaps.
static var common_padding_ratio := 1.0
var margin: MarginContainer
var title_control: Control
var title_wrap: MarginContainer
var box: VBoxContainer
var padding_design := 8.0
var common_padding := false
var bottom_design := -1.0


static func line_height(control: Control) -> float:
	if control is Container:
		var height := 0.0
		for child: Node in control.get_children():
			if child is Control:
				height = maxf(height, line_height(child))
		return height
	var rich := control is RichTextLabel
	var font := control.get_theme_font("normal_font" if rich else "font")
	var pixels := control.get_theme_font_size("normal_font_size" if rich else "font_size")
	var value: String = control.get_parsed_text() if rich else str(control.get("text"))
	var line := TextLine.new()
	line.add_string(value.get_slice("\n", 0), font, pixels, str(control.get("language")))
	return line.get_size().y if rich else maxf(int(font.get_height(pixels)), line.get_size().y)


static func half_line(control: Control) -> int:
	return ceili(line_height(control) * 0.5)


static func shared_padding() -> int:
	return UiScale.physical_int(16.0 * common_padding_ratio)


static func own_constants(control: Control) -> void:
	UiScale.declare_control_overrides(control, [], [])
	if control.has_meta(UiScale.META_BASE):
		control.get_meta(UiScale.META_BASE).constants.clear()


static func install(outer: MarginContainer, title: Control, padding := 8.0, shared := false) -> Node:
	var binding := new()
	binding.margin = outer
	binding.title_control = title
	binding.box = title.get_parent()
	binding.padding_design = padding
	binding.common_padding = shared
	own_constants(outer)
	binding.title_wrap = MarginContainer.new()
	binding.title_wrap.name = "TitleSpacing"
	# The launcher theme supplies MarginContainer defaults. This wrapper owns
	# only the title's following gap, so it must not add another themed inset.
	for side: String in ["left", "top", "right", "bottom"]:
		binding.title_wrap.add_theme_constant_override("margin_" + side, 0)
	var index := title.get_index()
	binding.box.add_child(binding.title_wrap)
	binding.box.move_child(binding.title_wrap, index)
	own_constants(binding.title_wrap)
	title.reparent(binding.title_wrap)
	outer.add_child(binding)
	return binding


func _ready() -> void:
	UiScale.scale_changed.connect(func(_scale: float): refresh.call_deferred())
	title_control.theme_changed.connect(refresh.call_deferred)
	refresh.call_deferred()


func refresh() -> void:
	var padding := shared_padding() if common_padding else UiScale.physical_int(padding_design)
	var gap := half_line(title_control)
	for side: String in ["left", "right", "bottom", "top"]:
		var value := maxi(padding, gap) if side == "top" else padding
		if side == "bottom" and bottom_design >= 0:
			value = UiScale.physical_int(bottom_design * (common_padding_ratio if common_padding else 1.0))
		if margin.get_theme_constant("margin_" + side) != value:
			margin.add_theme_constant_override("margin_" + side, value)
	# MarginContainer accepts signed offsets: replace the adjacent VBox gap,
	# including when the existing form gap is larger than half a title line.
	var after := gap - box.get_theme_constant("separation")
	if title_wrap.get_theme_constant("margin_bottom") != after:
		title_wrap.add_theme_constant_override("margin_bottom", after)
