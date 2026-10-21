extends Control

const SYSTEM_TEXTURE := preload("res://resources/orchidmantis_system_celestial.png")
const SYSTEM_NAME := "launcher/celestial"

@onready var fullscreen_button: Button = $FullscreenButton
@onready var close_button: Button = $CloseButton
var _text_runtime: WebpageThemeTextRuntime
var _layout_pending := false


func _ready() -> void:
	UiScale.mark_geometry_physical(self)
	_text_runtime = WebpageThemeTextRuntime.new()
	add_child(_text_runtime)
	fullscreen_button.pressed.connect(_toggle_fullscreen)
	close_button.pressed.connect(_close_application)
	WebpageThemeTooltipRuntime.set_control_tooltip(fullscreen_button, WindowModeController.TOOLTIP)
	WebpageThemeTooltipRuntime.set_control_tooltip(close_button, "退出")
	# Context follows the launcher and its popup descendants, including controls
	# created later by Android's launcher adapters.
	WebpageThemeTooltipRuntime.set_control_theme_override(
		%GodotMenuLayer, self, _text_runtime, SYSTEM_NAME, true, 0)
	WebpageThemeTooltipRuntime.set_control_theme_override(
		%LocationConfigError, self, _text_runtime, SYSTEM_NAME, true, 0)
	UiScale.safe_area_changed.connect(_queue_layout)
	UiScale.scale_changed.connect(_on_scale_changed)
	get_viewport().size_changed.connect(_queue_layout)
	visibility_changed.connect(_queue_layout)
	var viewport_container := get_viewport().get_parent() as Control
	if viewport_container != null:
		viewport_container.resized.connect(_queue_layout)
	_refresh_style()
	# SetupScreen initializes the desktop policy after its children are ready.
	_refresh_visibility.call_deferred()
	_queue_layout()


func get_menu_system_texture(_system_name: String = "") -> Texture2D:
	return SYSTEM_TEXTURE


func _refresh_visibility() -> void:
	fullscreen_button.visible = %WindowModeController.desktop_controls_enabled()


func _refresh_style() -> void:
	for button in [fullscreen_button, close_button]:
		_text_runtime.style_icon(button, self, SYSTEM_NAME,
			WebpageThemeTextRuntime.ROLE_NORMAL, true, 20.0)


func _on_scale_changed(_scale: float) -> void:
	_refresh_style()
	_queue_layout()


func _queue_layout() -> void:
	if _layout_pending:
		return
	_layout_pending = true
	_layout.call_deferred()


func _layout() -> void:
	_layout_pending = false
	# SubViewport.size_changed precedes its container's minimum-size update.
	# Read the screen transform after that parent layout has settled.
	var safe := UiScale.safe_rect_for(get_viewport())
	position = safe.position
	size = safe.size
	fullscreen_button.position.y = UiScale.corner_top_inset(false)
	close_button.position.y = UiScale.corner_top_inset(true)


func _toggle_fullscreen() -> void:
	%WindowModeController.toggle_fullscreen()


func _close_application() -> void:
	%RPGMakerPlayer.call_deferred("_on_window_close_requested")
