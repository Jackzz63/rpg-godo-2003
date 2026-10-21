extends Control

@onready var godot_menu_layer: CanvasLayer = %GodotMenuLayer
@onready var engine_layer: CanvasLayer = %EngineLayer
@onready var game_path: LineEdit = %GamePath
@onready var game_path_button: Button = %GamePathButton
@onready var game_path_file_dialog: FileDialog = %GamePathFileDialog
@onready var advanced_settings_button: Button = %AdvancedSettingsButton
@onready var advanced_options_popup: Window = %AdvancedOptionsPopup
var _advanced_keyboard_activation := false
@onready var location_config_error: AcceptDialog = %LocationConfigError
@onready var audio_slider: HSlider = %AudioSlider
@onready var mp_enable: CheckBox = %MpEnable
@onready var mp_name: LineEdit = %MpName
@onready var mp_url: LineEdit = %MpUrl
@onready var admin_credential: LineEdit = %AdminCredential
@onready var admin_credential_visibility: Button = %AdminCredentialVisibility
@onready var admin_credential_button: Button = %AdminCredentialButton
@onready var admin_credential_popup: Window = %AdminCredentialPopup
@onready var server_ping: Label = %ServerPing
@onready var server_online_count: Label = %ServerOnlineCount
@onready var server_status_values: Control = %ServerStatusValues
@onready var server_status_title: RichTextLabel = %ServerStatusTitle
@onready var launcher_modal_shade: ColorRect = %LauncherModalShade
@onready var server_refresh_button: Button = %ServerRefreshButton
@onready var mp_server: CheckBox = %MpServer
@onready var host_advanced_button: Button = %HostAdvancedButton
@onready var host_advanced_popup: Window = %HostAdvancedPopup
@onready var run_on_start: CheckBox = %RunOnStart
@onready var save_and_run: Button = %SaveAndRun
@onready var chat_ctrl: Control = %ChatControl
@onready var chat_layer: CanvasLayer = %ChatOverlayLayer
@onready var world_location_banner: Control = %WorldLocationBanner
@onready var chat_vbox: Control = %MessageContainer
@onready var chat_field: LineEdit = %ChatField

@export var engine: Node

const SettingsStore := preload("res://cogs/launcher_settings_store.gd")
const _SETTINGS_PATH := "user://main_settings.cfg"
const _NAMETAG_MODE_COMPACT := 2
const InputLimits := preload("res://cogs/input_limits.gd")
const LocationRuntimeScript := preload("res://cogs/locations/location_runtime.gd")
const LocationConfigLoaderScript := preload("res://cogs/locations/location_config_loader.gd")
const AdminStoreScript := preload("res://cogs/multiplayer/admin_store.gd")
const ServerConsoleScript := preload("res://cogs/multiplayer/server_console.gd")
const ServerBadSounds := preload("res://cogs/multiplayer/server_bad_sounds.gd")
const HostParameters := preload("res://cogs/multiplayer/host_parameters.gd")
const _HOST_GEAR := preload("res://resources/icons/gear.svg")
const _LAUNCHER_FONT := preload("res://resources/launcher_font.tres")
const _ADMIN_PASSWORD_VISIBLE_ICON := preload("res://resources/icons/eye.svg")
const _ADMIN_PASSWORD_HIDDEN_ICON := preload("res://resources/icons/eye-closed.svg")
const _ADMIN_STATUS_ICON := preload("res://resources/icons/usershield.svg")
const _SERVER_REFRESH_ICON := preload("res://resources/icons/reload.svg")
const LauncherIcon := preload("res://cogs/launcher_icon_preview.gd")
const ServerStatusProbeScript := preload("res://cogs/multiplayer/server_status_probe.gd")
const _ADMIN_UNAUTHENTICATED_COLOR := Color("c8c8c8")
const _ADMIN_AUTHENTICATED_COLOR := Color("67d17a")
const _MULTIPLAYER_DISABLED_COLOR := Color("999999")
const TextBaseline := preload("res://cogs/ui_text_baseline.gd")
const _PING_GOOD_COLOR := Color("67d17a")
const _PING_MEDIUM_COLOR := Color("ffd166")
const _PING_BAD_COLOR := Color("ff6b6b")
const WebpageThemeTextRuntimeScript := preload("res://cogs/webpage_theme_text_runtime.gd")
const _CHECK_BOX_ICON_NAMES: Array[StringName] = [
	&"checked", &"unchecked", &"checked_disabled", &"unchecked_disabled",
	&"radio_checked", &"radio_unchecked", &"radio_checked_disabled",
	&"radio_unchecked_disabled"]

var multiplayer_node: EasyMultiplayer = null
var server_node: EasyServer = null
var location_runtime: Node = null
var _watch_timer: Timer = null
var _global_vars_mode: String = ""
var _bad_sounds_options: Dictionary = {"ok": true, "profile": "", "error": ""}
var _mp_resume_states_by_endpoint: Dictionary = {}
var _admin_credentials_by_endpoint: Dictionary = {}
var _location_directories_by_game: Dictionary = {}
var _updating_endpoint_field: bool = false
var _private_mode_desired: bool = false
var _audio_muted: bool = false
var _nametag_mode: int = _NAMETAG_MODE_COMPACT
var _admin_password_visible_icon: Texture2D
var _admin_password_hidden_icon: Texture2D
var _game_path_source_icon: Texture2D
var _check_box_source_icons: Dictionary = {}
var _audio_slider_source_styles: Dictionary = {}
var _audio_slider_source_icons: Dictionary = {}
var _server_status_probe: Node = null
var _auto_probe_pending: bool = false
var _launcher_preview_active: bool = false
var _game_path_browsing: bool = false
var _status_layout_queued := false
var _saved_host_parameters := ""
var _host_parameters_text := ""
var _local_host_client: EasyMultiplayer = null
var _android_runtime: Node = null


func _enter_tree() -> void:
	var root := get_tree().root
	if not root.size_changed.is_connected(_sync_launcher_viewport):
		root.size_changed.connect(_sync_launcher_viewport)
	call_deferred("_sync_launcher_viewport")


func _exit_tree() -> void:
	_suspend_launcher_preview()
	var root := get_tree().root
	if root.size_changed.is_connected(_sync_launcher_viewport):
		root.size_changed.disconnect(_sync_launcher_viewport)
	if UiScale.scale_changed.is_connected(_on_ui_scale_changed):
		UiScale.scale_changed.disconnect(_on_ui_scale_changed)

func _ready() -> void:
	set_process(false)
	var args := _get_application_args()
	_global_vars_mode = _parse_global_vars_mode(args)
	_bad_sounds_options = ServerBadSounds.parse_options(args)
	if _has_adminctl(args):
		_run_adminctl(args)
		return
	if args.has("--server-only"):
		_start_server_only(args)
		return
	%WindowModeController.apply_desktop_startup_default()
	for field: LineEdit in [game_path, mp_name, mp_url, admin_credential]:
		preload("res://cogs/input_field_style.gd").install(field)
	preload("res://cogs/dialog_error_layout.gd").install(location_config_error, 440)
	if OS.get_name() == "Android":
		_android_runtime = load("res://platform/android/android_runtime.gd").new()
		_android_runtime.launcher = self
		_android_runtime.engine = engine
		engine.get_parent().add_child.call_deferred(_android_runtime)
	mp_name.max_length = InputLimits.NICKNAME_MAX_ASCII_CHARACTERS
	mp_name.text_changed.connect(_on_mp_name_text_changed)
	mp_url.text_changed.connect(_on_mp_url_text_changed)
	admin_credential.max_length = 160
	
	var loaded := SettingsStore.read(_SETTINGS_PATH)
	var cfg: ConfigFile = loaded.config
	var err: Error = loaded.error
	
	game_path.text = cfg.get_value("game", "path", engine.get_game_path()) \
		if err == OK else engine.get_game_path()
	_location_directories_by_game = _load_location_directories(cfg)
	
	audio_slider.min_value = 0.0
	audio_slider.max_value = 100.0
	audio_slider.step = 5.0
	audio_slider.value = cfg.get_value("audio", "volume", 80.0)
	_audio_muted = bool(cfg.get_value("audio", "muted", false))
	_apply_audio_muted()
	chat_ctrl.connect("audio_muted_changed", _on_audio_muted_changed)
	mp_enable.button_pressed = cfg.get_value("multiplayer", "enabled", false)
	mp_name.text = InputLimits.sanitize_nickname(
		str(cfg.get_value("multiplayer", "name", "Minnatsuki"))
	)
	_updating_endpoint_field = true
	mp_url.text = str(cfg.get_value("multiplayer", "url", "ws://127.0.0.1:42424"))
	_updating_endpoint_field = false
	_admin_credentials_by_endpoint = _load_admin_credentials(cfg)
	_refresh_admin_credential_for_endpoint()
	mp_server.button_pressed = cfg.get_value("multiplayer", "host_locally", false)
	_saved_host_parameters = str(cfg.get_value("multiplayer", "host_parameters", ""))
	_host_parameters_text = HostParameters.overlay_command_line(_saved_host_parameters, args)
	_private_mode_desired = bool(cfg.get_value("multiplayer", "private_mode", false))
	_nametag_mode = _sanitize_nametag_mode(int(
		cfg.get_value("multiplayer", "nametag_mode", _NAMETAG_MODE_COMPACT)))
	run_on_start.button_pressed = cfg.get_value("game", "run_on_start", false)
	chat_ctrl.call("set_multiplayer_enabled_context", false)
	chat_ctrl.call("set_privacy_mode_desired", _private_mode_desired)
	chat_ctrl.call("set_nametag_engine", engine)
	chat_ctrl.call("set_nametag_mode", _nametag_mode, false)
	# Launcher count tooltips are needed before the first game opens the chat UI.
	chat_ctrl.call_deferred("_refresh_local_menu_theme")
	var privacy_callback := Callable(self, "_on_privacy_mode_desired_changed")
	if not chat_ctrl.is_connected("privacy_mode_desired_changed", privacy_callback):
		chat_ctrl.connect("privacy_mode_desired_changed", privacy_callback)
	var nametag_callback := Callable(self, "_on_nametag_mode_changed")
	if not chat_ctrl.is_connected("nametag_mode_changed", nametag_callback):
		chat_ctrl.connect("nametag_mode_changed", nametag_callback)
	
	game_path_button.pressed.connect(_on_browse_pressed)
	advanced_settings_button.pressed.connect(_on_advanced_settings_pressed)
	advanced_settings_button.gui_input.connect(_on_advanced_settings_input)
	host_advanced_button.pressed.connect(_on_host_advanced_pressed)
	host_advanced_popup.connect("save_requested", _on_host_parameters_save_requested)
	for popup in [host_advanced_popup, advanced_options_popup, admin_credential_popup]:
		popup.connect("editing_started", _sync_launcher_modal_input)
		popup.connect("editing_finished", _on_launcher_modal_finished)
	for popup in [host_advanced_popup, advanced_options_popup]:
		popup.set("launcher_menu", $VBoxContainer)
		$VBoxContainer.resized.connect(Callable(popup, "_queue_layout"), CONNECT_DEFERRED)
	mp_server.toggled.connect(_on_host_toggled)
	mp_enable.get_parent().sort_children.connect(_layout_host_row, CONNECT_DEFERRED)
	mp_server.get_parent().resized.connect(_layout_host_row, CONNECT_DEFERRED)
	for control in [mp_server, host_advanced_button, mp_server.get_parent().get_node("VBoxContainer")]:
		UiScale.mark_geometry_physical(control)
	_layout_host_row.call_deferred()
	advanced_options_popup.connect("save_requested", _on_location_source_save_requested)
	location_config_error.visibility_changed.connect(
		_on_launcher_window_visibility_changed.bind(location_config_error))
	_game_path_source_icon = game_path_button.icon
	_capture_check_box_icons()
	_capture_audio_slider_theme()
	game_path_file_dialog.dir_selected.connect(_on_dir_selected)
	game_path_file_dialog.canceled.connect(_on_game_path_browse_finished)
	audio_slider.value_changed.connect(_on_audio_volume_changed)
	admin_credential_visibility.toggled.connect(
		_on_admin_credential_visibility_toggled)
	if not UiScale.scale_changed.is_connected(_on_ui_scale_changed):
		UiScale.scale_changed.connect(_on_ui_scale_changed)
	_refresh_launcher_icons()
	_refresh_audio_slider_theme()
	_on_admin_credential_visibility_toggled(false)
	save_and_run.pressed.connect(_on_save_and_run)
	admin_credential_button.pressed.connect(_on_admin_credential_button_pressed)
	admin_credential_popup.connect("save_requested", _on_admin_credential_save_requested)
	server_refresh_button.pressed.connect(_on_server_refresh_pressed)
	server_status_values.resized.connect(_queue_server_status_layout)
	server_status_title.get_parent().sort_children.connect(_queue_server_status_layout)
	for label in [server_status_title, server_ping, server_online_count]:
		label.theme_changed.connect(_queue_server_status_layout)
	_on_mp_enable_toggled(mp_enable.button_pressed)
	_server_status_probe = ServerStatusProbeScript.new()
	_server_status_probe.name = "ServerStatusProbe"
	add_child(_server_status_probe)
	_server_status_probe.connect("updated", _refresh_server_status)
	_launcher_preview_active = true
	_refresh_server_status()
	set_process(true)
	if args.has("--autorun") or run_on_start.button_pressed:
		call_deferred("_launch_game")
	else:
		_request_launcher_auto_refresh()


func _sync_launcher_viewport() -> void:
	var launcher_viewport := get_viewport() as SubViewport
	if launcher_viewport == null:
		return
	var container := launcher_viewport.get_parent() as SubViewportContainer
	if container != null:
		container.stretch = false
	launcher_viewport.size = get_tree().root.size


func _on_ui_scale_changed(_ui_scale: float) -> void:
	_refresh_launcher_icons()
	_refresh_audio_slider_theme()
	_on_admin_credential_visibility_toggled(
		admin_credential_visibility.button_pressed)
	call_deferred("_fit_launcher_nickname_hint")
	_layout_host_row.call_deferred()


func _layout_host_row() -> void:
	if not is_node_ready():
		return
	mp_server.get_parent().layout_at_scale(UiScale.get_ui_scale())


func _on_host_toggled(enabled: bool) -> void:
	mp_url.editable = mp_enable.button_pressed and not enabled
	if enabled:
		admin_credential_popup.call("dismiss")
		_auto_probe_pending = false
		if is_instance_valid(_server_status_probe):
			_server_status_probe.call("invalidate")
	else:
		_request_launcher_auto_refresh()
	_refresh_server_status()
	_layout_host_row.call_deferred()


func _on_host_advanced_pressed() -> void:
	if _launcher_preview_active and godot_menu_layer.visible and mp_enable.button_pressed:
		host_advanced_popup.call("open_for_parameters", _host_parameters_text)


func _save_host_parameters_now(text: String) -> Error:
	return SettingsStore.patch(_SETTINGS_PATH, {"multiplayer": {"host_parameters": text}}).error


func _on_host_parameters_save_requested(text: String) -> void:
	if not _launcher_preview_active or not mp_enable.button_pressed \
			or not bool(host_advanced_popup.call("is_open_or_opening")):
		return
	var result := HostParameters.parse(text)
	if not result.ok:
		host_advanced_popup.call("show_save_error", result.error)
		return
	var error := _save_host_parameters_now(text)
	if error != OK:
		host_advanced_popup.call("show_save_error", "保存失败：%s" % error_string(error))
		return
	_saved_host_parameters = text
	_host_parameters_text = text
	host_advanced_popup.call("dismiss")


func _start_configured_host(parent: Node) -> bool:
	var options := HostParameters.parse(_host_parameters_text)
	if not options.ok:
		_report_host_failure(str(options.error))
		return false
	if not _start_mp_server(parent, options.port, options.bind, options.admins,
			options.punishments, options.audit, options.address_source,
			options.max_connections, options.max_pending_admissions, false, options):
		_report_host_failure("服务端启动失败，请检查端口占用和管理数据文件。")
		return false
	var owner := server_node.prepare_local_host_admin()
	if not owner.ok:
		server_node.stop()
		server_node.queue_free()
		server_node = null
		_report_host_failure(str(owner.error))
		return false
	return _start_mp_client(parent, "ws://127.0.0.1:%d" % int(options.port), str(owner.credential))


func _report_host_failure(message: String) -> void:
	Log.error("[setup_screen] 主机启动失败：%s" % message)
	chat_ctrl.mp_connection = null
	# The game continues with the multiplayer context selected by the player.
	chat_ctrl.call("add_chat_message", "系统", "服务器主机启动失败，请完全退出本程序后重试。\n如果问题持续，请检查端口是否被占用、主机参数是否有效，以及管理数据文件是否可读写。\n详细信息：%s" % message)


func _capture_check_box_icons() -> void:
	for check_box in [mp_enable, mp_server, run_on_start,
			host_advanced_popup.get_node("%GlobalPreset"), host_advanced_popup.get_node("%SoundsPreset")]:
		var icons := {}
		for icon_name in _CHECK_BOX_ICON_NAMES:
			if check_box.has_theme_icon(icon_name):
				icons[icon_name] = check_box.get_theme_icon(icon_name)
		_check_box_source_icons[check_box] = icons


func _capture_audio_slider_theme() -> void:
	# Capture once before adding local overrides; later resizes always use these originals.
	for style_name in [&"slider", &"grabber_area", &"grabber_area_highlight"]:
		_audio_slider_source_styles[style_name] = audio_slider.get_theme_stylebox(style_name)
	for icon_name in [&"grabber", &"grabber_highlight", &"grabber_disabled"]:
		_audio_slider_source_icons[icon_name] = audio_slider.get_theme_icon(icon_name)


func _refresh_audio_slider_theme() -> void:
	audio_slider.begin_bulk_theme_override()
	for style_name in _audio_slider_source_styles:
		# This also excludes the physical override from UiScale's automatic style scaling.
		UiScale.apply_physical_stylebox(
			audio_slider, style_name, _audio_slider_source_styles[style_name])
	for icon_name in _audio_slider_source_icons:
		var source := _audio_slider_source_icons[icon_name] as Texture2D
		audio_slider.add_theme_icon_override(icon_name, _make_launcher_icon_texture(
			source, UiScale.physical_size(Vector2i(source.get_size()))))
	audio_slider.end_bulk_theme_override()


func _refresh_launcher_icons() -> void:
	host_advanced_button.icon = _make_launcher_icon_texture(
		_HOST_GEAR, UiScale.physical_size(Vector2i(16, 16)))
	if _game_path_source_icon != null:
		game_path_button.icon = _make_launcher_icon_texture(
			_game_path_source_icon, UiScale.physical_size(Vector2i(16, 16)))
	for check_box in _check_box_source_icons:
		if not is_instance_valid(check_box):
			continue
		var icons: Dictionary = _check_box_source_icons[check_box]
		for icon_name in icons:
			var source := icons[icon_name] as Texture2D
			if source == null:
				continue
			var target_size := UiScale.physical_size(Vector2i(source.get_size()))
			check_box.add_theme_icon_override(
				icon_name,
				_make_launcher_icon_texture(source, target_size))
	var target_size := UiScale.physical_size(Vector2i(32, 32))
	_admin_password_visible_icon = WebpageThemeTextRuntimeScript.make_dpi_icon_texture(
		_ADMIN_PASSWORD_VISIBLE_ICON, target_size)
	_admin_password_hidden_icon = WebpageThemeTextRuntimeScript.make_dpi_icon_texture(
		_ADMIN_PASSWORD_HIDDEN_ICON, target_size)
	admin_credential_button.icon = _make_launcher_white_icon(_ADMIN_STATUS_ICON, target_size)
	server_refresh_button.icon = _make_launcher_white_icon(_SERVER_REFRESH_ICON, target_size)
	call_deferred("_fit_launcher_nickname_hint")


func _make_launcher_white_icon(source: Texture2D, target_size: Vector2i) -> Texture2D:
	return LauncherIcon.white_icon(_make_launcher_icon_texture(source, target_size))


func _fit_launcher_nickname_hint() -> void:
	if not is_node_ready():
		return
	var font := mp_name.get_theme_font("font")
	var font_size := mp_name.get_theme_font_size("font_size")
	var hint_width := font.get_string_size(
		mp_name.placeholder_text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x
	var style := mp_name.get_theme_stylebox("normal")
	var input_width := maxf(UiScale.physical_value(184.0), ceilf(
		hint_width + style.get_margin(SIDE_LEFT)
		+ style.get_margin(SIDE_RIGHT)))
	for control in [mp_name, mp_url, server_status_values]:
		UiScale.mark_geometry_physical(control)
		control.custom_minimum_size = Vector2(input_width, UiScale.physical_value(32.0))
	var menu := $VBoxContainer as VBoxContainer
	var extra_width := input_width - UiScale.physical_value(184.0)
	menu.offset_left = -UiScale.physical_value(182.0) - extra_width * 0.5
	menu.offset_right = UiScale.physical_value(182.0) + extra_width * 0.5
	_layout_server_status_values()


static func _format_launcher_online_count(count: int) -> String:
	if count < 10000:
		return "%d人在线" % count
	# Round the original integer before choosing the unit, including a carry
	# from 9995 ten-thousands to one hundred-million. Keep three significant digits.
	var step := 100
	while count >= step * 1000:
		step *= 10
	@warning_ignore("integer_division")
	var rounded := ((count + step / 2) / step) * step
	var unit := 100000000 if rounded >= 100000000 else 10000
	var suffix := "亿在线" if unit == 100000000 else "万在线"
	@warning_ignore("integer_division")
	var whole := rounded / unit
	var decimals := 2 if whole < 10 else (1 if whole < 100 else 0)
	if decimals == 0:
		return str(whole) + suffix
	var factor := 100 if decimals == 2 else 10
	@warning_ignore("integer_division")
	var fraction := (rounded % unit) * factor / unit
	return "%d.%s%s" % [whole, str(fraction).pad_zeros(decimals), suffix]


func _queue_server_status_layout() -> void:
	if not _status_layout_queued:
		_status_layout_queued = true
		_layout_server_status_values.call_deferred()


func _layout_server_status_values() -> void:
	_status_layout_queued = false
	if not is_node_ready():
		return
	for index in 2:
		var label: Label = server_ping if index == 0 else server_online_count
		var width := label.get_combined_minimum_size().x
		label.size = Vector2(width, server_status_values.size.y)
		UiScale.mark_geometry_physical(label)
		label.position = Vector2(server_status_values.size.x * (0.25 if index == 0 else 0.75) - width * 0.5,
			TextBaseline.centered_label_offset_from_caption(label, server_status_title))


func _make_launcher_icon_texture(
		source: Texture2D, target_size: Vector2i) -> Texture2D:
	if source == null:
		return null
	if source is DPITexture:
		return WebpageThemeTextRuntimeScript.make_dpi_icon_texture(source, target_size)
	var image := source.get_image()
	if image == null or image.is_empty():
		return source
	image = image.duplicate()
	if image.has_mipmaps():
		image.clear_mipmaps()
	image.resize(
		maxi(1, target_size.x), maxi(1, target_size.y), Image.INTERPOLATE_NEAREST)
	return ImageTexture.create_from_image(image)


func _on_admin_credential_visibility_toggled(password_visible: bool) -> void:
	admin_credential.secret = not password_visible
	admin_credential.set_caret_column(admin_credential.caret_column)
	admin_credential_visibility.icon = (
		_admin_password_visible_icon
		if password_visible
		else _admin_password_hidden_icon)
	WebpageThemeTooltipRuntime.set_control_tooltip(
		admin_credential_visibility,
		"隐藏密码" if password_visible else "显示密码")


func _load_admin_credentials(cfg: ConfigFile) -> Dictionary:
	var result: Dictionary = {}
	var stored: Variant = cfg.get_value("multiplayer", "admin_credentials", {})
	if typeof(stored) != TYPE_DICTIONARY:
		return result
	for endpoint_value in (stored as Dictionary):
		var endpoint := EasyMultiplayer.normalize_server_endpoint(str(endpoint_value))
		var credential_value: Variant = (stored as Dictionary)[endpoint_value]
		if (endpoint.is_empty() or typeof(credential_value) != TYPE_STRING
				or (credential_value as String).length() > 160):
			continue
		var credential := credential_value as String
		if not credential.is_empty():
			result[endpoint] = credential
	return result


func _on_mp_url_text_changed(_value: String) -> void:
	if _updating_endpoint_field:
		return
	_refresh_admin_credential_for_endpoint()
	if is_instance_valid(_server_status_probe):
		_server_status_probe.call("invalidate")
	# A forced popup close above can synchronously request a refresh. Editing
	# the address cancels that intent as well as any query for the old address.
	_auto_probe_pending = false
	_refresh_server_status()


func _refresh_admin_credential_for_endpoint() -> void:
	var endpoint := EasyMultiplayer.normalize_server_endpoint(mp_url.text)
	if (not str(admin_credential_popup.get("endpoint")).is_empty()
			and str(admin_credential_popup.get("endpoint")) != endpoint):
		admin_credential_popup.call("dismiss")


func _save_admin_credentials_now() -> Error:
	var saved := SettingsStore.patch(_SETTINGS_PATH,
		{"multiplayer": {"admin_credentials": _admin_credentials_by_endpoint.duplicate(true)}},
		{"multiplayer": ["admin_credential"]})
	if saved.error != OK:
		if saved.stage == "load":
			Log.warn("[setup_screen] could not load settings for administrator credential")
		else:
			Log.warn("[setup_screen] could not save administrator credential: %s" \
				% error_string(saved.error))
	return saved.error


func _on_admin_credential_button_pressed() -> void:
	var endpoint := EasyMultiplayer.normalize_server_endpoint(mp_url.text)
	if endpoint.is_empty() or not _is_launcher_multiplayer_available():
		return
	admin_credential_popup.call("open_for_endpoint", endpoint,
		str(_admin_credentials_by_endpoint.get(endpoint, "")))


func _on_admin_credential_save_requested(endpoint: String, credential: String) -> void:
	if (not _is_launcher_multiplayer_available()
			or endpoint != EasyMultiplayer.normalize_server_endpoint(mp_url.text)
			or endpoint != str(admin_credential_popup.get("endpoint"))):
		admin_credential_popup.call("dismiss")
		return
	var previous_credentials := _admin_credentials_by_endpoint.duplicate(true)
	var previous_credential := str(_admin_credentials_by_endpoint.get(endpoint, ""))
	if credential.is_empty():
		_admin_credentials_by_endpoint.erase(endpoint)
	else:
		_admin_credentials_by_endpoint[endpoint] = credential
	var save_error := _save_admin_credentials_now()
	if save_error != OK:
		_admin_credentials_by_endpoint = previous_credentials
		admin_credential_popup.call("show_save_error", error_string(save_error))
		return
	if previous_credential != credential and is_instance_valid(_server_status_probe):
		_server_status_probe.call("invalidate")
	admin_credential_popup.call("dismiss")
	_refresh_server_status()


func _is_launcher_multiplayer_available() -> bool:
	return (_launcher_preview_active and godot_menu_layer.visible
		and mp_enable.button_pressed and not mp_server.button_pressed)


func _request_launcher_auto_refresh() -> void:
	# Record synchronously; dispatch after the current save/close/return stack.
	if _is_launcher_multiplayer_available() and is_instance_valid(_server_status_probe):
		_auto_probe_pending = true


func _on_launcher_window_visibility_changed(window: Window) -> void:
	if not window.visible:
		_request_launcher_auto_refresh()


func _sync_launcher_modal_input() -> void:
	var active := false
	if is_instance_valid(_android_runtime) and _android_runtime.is_node_ready():
		active = bool(_android_runtime.call("is_modal_open"))
	for popup in [host_advanced_popup, advanced_options_popup, admin_credential_popup]:
		active = active or bool(popup.call("is_open_or_opening"))
	# Only the launcher lives here. The sibling Windows continue receiving input.
	get_viewport().gui_disable_input = active
	launcher_modal_shade.visible = active


func _on_launcher_modal_finished() -> void:
	_sync_launcher_modal_input()
	_request_launcher_auto_refresh()


func _can_dispatch_launcher_probe() -> bool:
	return (_is_launcher_multiplayer_available()
		and is_instance_valid(_server_status_probe)
		and (not is_instance_valid(_android_runtime) or not bool(_android_runtime.call("is_modal_open")))
		and not _game_path_browsing and not game_path_file_dialog.visible
		and not admin_credential_popup.visible
		and str(admin_credential_popup.get("endpoint")).is_empty()
		and not bool(advanced_options_popup.call("is_open_or_opening"))
		and not bool(host_advanced_popup.call("is_open_or_opening"))
		and not location_config_error.visible
		and bool(_server_status_probe.call("can_refresh")))


func _on_server_refresh_pressed() -> void:
	if not _can_dispatch_launcher_probe():
		return
	var endpoint := EasyMultiplayer.normalize_server_endpoint(mp_url.text)
	if bool(_server_status_probe.call("refresh", endpoint,
			str(_admin_credentials_by_endpoint.get(endpoint, "")))):
		# Accepted attempts consume the intent even if the endpoint fails now.
		_auto_probe_pending = false
	_refresh_server_status()


func _process(_delta: float) -> void:
	if not _launcher_preview_active:
		return
	if not godot_menu_layer.visible:
		_suspend_launcher_preview()
		return
	if _auto_probe_pending:
		_on_server_refresh_pressed()
	_refresh_server_refresh_button()


func _refresh_server_refresh_button() -> void:
	if not is_instance_valid(_server_status_probe):
		return
	var remaining := int(_server_status_probe.call("cooldown_remaining_msec"))
	server_refresh_button.disabled = not _can_dispatch_launcher_probe()
	server_refresh_button.call("set_remaining_msec", remaining if _is_launcher_multiplayer_available() else 0)


func _refresh_server_status() -> void:
	if not is_instance_valid(server_ping):
		return
	var state := (str(_server_status_probe.get("state"))
		if is_instance_valid(_server_status_probe) else "idle")
	if not mp_enable.button_pressed or mp_server.button_pressed:
		state = "idle"
	var authenticated := (state == "ready"
		and bool(_server_status_probe.get("authenticated")))
	var count_tooltip := ""
	var ping_color := Color.WHITE
	if state == "ready":
		var ping := int(_server_status_probe.get("ping_msec"))
		server_ping.text = "%dms" % ping
		ping_color = _PING_GOOD_COLOR if ping <= 200 else (_PING_MEDIUM_COLOR if ping <= 500 else _PING_BAD_COLOR)
		var count := int(_server_status_probe.get("online_count"))
		server_online_count.text = _format_launcher_online_count(count)
		if count >= 10000:
			count_tooltip = "实际在线人数：%d" % count
	else:
		server_ping.text = "无法连接" if state == "unreachable" else "-ms"
		if state == "unreachable":
			ping_color = _PING_BAD_COLOR
		server_online_count.text = "-人在线"
	server_ping.add_theme_color_override("font_color", ping_color)
	server_online_count.visible = state != "unreachable"
	WebpageThemeTooltipRuntime.set_control_tooltip(server_online_count, count_tooltip)
	_queue_server_status_layout()
	var remote_available := _is_launcher_multiplayer_available()
	server_status_values.modulate = Color.WHITE if remote_available else _MULTIPLAYER_DISABLED_COLOR
	server_refresh_button.add_theme_color_override("icon_disabled_color",
		Color.WHITE if remote_available else _MULTIPLAYER_DISABLED_COLOR)
	admin_credential_button.disabled = (not _is_launcher_multiplayer_available()
		or EasyMultiplayer.normalize_server_endpoint(mp_url.text).is_empty())
	var normal_color := (_ADMIN_AUTHENTICATED_COLOR
		if authenticated else _ADMIN_UNAUTHENTICATED_COLOR)
	for color_name in ["icon_normal_color", "icon_pressed_color"]:
		admin_credential_button.add_theme_color_override(color_name, normal_color)
	admin_credential_button.add_theme_color_override("icon_disabled_color",
		normal_color if remote_available else _MULTIPLAYER_DISABLED_COLOR)
	for color_name in ["icon_hover_color", "icon_hover_pressed_color", "icon_focus_color"]:
		admin_credential_button.add_theme_color_override(color_name,
			_ADMIN_AUTHENTICATED_COLOR if authenticated else Color.WHITE)
	WebpageThemeTooltipRuntime.set_control_tooltip(admin_credential_button,
		"管理员已认证" if authenticated else "管理员密码")
	_refresh_server_refresh_button()


func _suspend_launcher_preview() -> void:
	_launcher_preview_active = false
	set_process(false)
	_auto_probe_pending = false
	if is_instance_valid(_server_status_probe):
		_server_status_probe.call("invalidate")
	if is_instance_valid(admin_credential_popup):
		admin_credential_popup.call("dismiss")
	if is_instance_valid(advanced_options_popup):
		advanced_options_popup.call("dismiss")
	if is_instance_valid(host_advanced_popup):
		host_advanced_popup.call("dismiss")


func _resume_launcher_preview() -> void:
	if not is_instance_valid(_server_status_probe):
		return
	_launcher_preview_active = true
	_server_status_probe.call("invalidate")
	_refresh_server_status()
	set_process(true)
	_request_launcher_auto_refresh()

func _start_mp_server(
	parent: Node,
	port: int = 42424,
	bind_address: String = "*",
	admins_path: String = "",
	punishments_path: String = "",
	audit_path: String = "",
	punishment_address_source: String = "direct",
	max_connections: int = EasyServer.MAX_CONNECTIONS,
	max_pending_admissions: int = EasyServer.DEFAULT_MAX_PENDING_ADMISSIONS,
	exit_process_on_protocol_limit: bool = false,
	host_options: Dictionary = {}
) -> bool:
	if host_options.is_empty() and not bool(_bad_sounds_options.get("ok", false)):
		Log.server_error("[EasyServer] FATAL invalid_cli option=bad-sounds error=%s" \
			% str(_bad_sounds_options.get("error", "invalid option")))
		return false
	if server_node:
		server_node.stop()
		server_node.queue_free()
		server_node = null
	server_node = EasyServer.new()
	server_node.name = "MpServerNode"
	server_node.port = port
	server_node.bind_address = bind_address
	server_node.global_vars_mode = str(host_options.get("global_vars", _global_vars_mode))
	server_node.bad_sounds_profile = str(host_options.get("bad_sounds", _bad_sounds_options.get("profile", "")))
	server_node.admins_file = admins_path
	server_node.punishments_file = punishments_path
	server_node.audit_file = audit_path
	server_node.punishment_address_source = punishment_address_source
	server_node.max_connections = max_connections
	server_node.max_pending_admissions = max_pending_admissions
	server_node.exit_process_on_protocol_limit = exit_process_on_protocol_limit
	parent.add_child(server_node)
	if not server_node.start():
		server_node.queue_free()
		server_node = null
		return false
	return true

func _start_mp_client(parent: Node, host_endpoint: String = "", host_credential: String = "") -> bool:
	var local_host := not host_endpoint.is_empty()
	var endpoint := host_endpoint if local_host else EasyMultiplayer.normalize_server_endpoint(mp_url.text)
	if endpoint.is_empty():
		Log.error("[setup_screen] invalid WebSocket server URL")
		return false
	var resume_state: Dictionary = {} if local_host else _mp_resume_states_by_endpoint.get(endpoint, {
		"token": "",
		"attempt_sequence": 0,
	})
	multiplayer_node = EasyMultiplayer.new()
	_local_host_client = multiplayer_node if local_host else null
	multiplayer_node.name = "MpNode"
	multiplayer_node.engine = engine.get_path()
	multiplayer_node.server_url = endpoint
	multiplayer_node.resume_state_changed.connect(
		_on_mp_resume_state_changed.bind(multiplayer_node, endpoint)
	)
	multiplayer_node.admin_credential_accepted.connect(
		_on_admin_credential_accepted.bind(multiplayer_node, endpoint)
	)
	multiplayer_node.admin_authentication_changed.connect(
		_on_admin_authentication_changed.bind(multiplayer_node, endpoint)
	)
	multiplayer_node.set_resume_state(
		str(resume_state.get("token", "")),
		int(resume_state.get("attempt_sequence", 0)))
	var safe_player_name := InputLimits.sanitize_nickname(mp_name.text)
	mp_name.text = safe_player_name
	multiplayer_node.player_name = safe_player_name
	multiplayer_node.enable_chat = true
	multiplayer_node.set_privacy_enabled(_private_mode_desired)
	multiplayer_node.set_admin_credential(
		host_credential if local_host else str(_admin_credentials_by_endpoint.get(endpoint, "")))
	chat_ctrl.mp_connection = multiplayer_node # p4o-a7o: this is a little weird yes but we all die in the end anyways
	parent.add_child(multiplayer_node)
	if is_instance_valid(location_runtime):
		multiplayer_node.set_location_runtime(location_runtime)
	# nametag modes: 0=NONE, 1=CLASSIC (3-char), 2=COMPACT (full), 3=SLIM (full, small font)
	engine.mp_set_nametag_mode(_nametag_mode)
	multiplayer_node.connect_to_room(0)
	return true


func _on_mp_resume_state_changed(
	token: String,
	attempt_sequence: int,
	source: EasyMultiplayer,
	endpoint: String
) -> void:
	if source != multiplayer_node or source == _local_host_client:
		return
	_mp_resume_states_by_endpoint[endpoint] = {
		"token": token,
		"attempt_sequence": attempt_sequence,
	}


func _on_admin_credential_accepted(
	source: EasyMultiplayer,
	endpoint: String
) -> void:
	if source != multiplayer_node or source == _local_host_client:
		return
	var credential := source.get_admin_credential()
	if credential.is_empty() or credential.length() > 160:
		return
	_admin_credentials_by_endpoint[endpoint] = credential
	_save_admin_credentials_now()


func _on_admin_authentication_changed(
	_authenticated: bool,
	_admin_id: String,
	error: String,
	source: EasyMultiplayer,
	endpoint: String
) -> void:
	if source != multiplayer_node or source == _local_host_client or error != "credential_revoked":
		return
	_admin_credentials_by_endpoint.erase(endpoint)
	if EasyMultiplayer.normalize_server_endpoint(mp_url.text) == endpoint:
		admin_credential_popup.call("dismiss")
		if is_instance_valid(_server_status_probe):
			_server_status_probe.call("invalidate")
	_save_admin_credentials_now()
	
func _start_server_only(args: PackedStringArray) -> void:
	godot_menu_layer.visible = false
	if not bool(_bad_sounds_options.get("ok", false)):
		Log.error("[EasyServer] FATAL invalid_cli option=bad-sounds error=%s" \
			% str(_bad_sounds_options.get("error", "invalid option")))
		get_tree().quit(2)
		return
	var port_text := "42424"
	var bind_address := "*"
	var punishment_address_source := "direct"
	var data_paths := _server_data_paths(args)
	var capacity_options := _parse_server_capacity_options(args)
	for arg in args:
		if arg.begins_with("--port="):
			port_text = arg.substr(7)
		elif arg.begins_with("--bind="):
			bind_address = arg.substr(7)
		elif arg.begins_with("--punishment-address-source="):
			punishment_address_source = arg.substr(28).to_lower()
	if not port_text.is_valid_int():
		Log.error("[EasyServer] FATAL invalid_cli option=port value=%s" % port_text)
		get_tree().quit(2)
		return
	var port := int(port_text)
	if port < 1 or port > 65535:
		Log.error("[EasyServer] FATAL invalid_cli option=port value=%s" % port_text)
		get_tree().quit(2)
		return
	if bind_address != "*" and not bind_address.is_valid_ip_address():
		Log.error("[EasyServer] FATAL invalid_cli option=bind value=%s" % bind_address)
		get_tree().quit(2)
		return
	if punishment_address_source not in [
			"direct", "disabled", "nginx_uri_v1", "direct_or_nginx_uri_v1"]:
		Log.error("[EasyServer] FATAL invalid_cli option=punishment-address-source value=%s" \
			% punishment_address_source)
		get_tree().quit(2)
		return
	if not bool(capacity_options.get("ok", false)):
		Log.error("[EasyServer] FATAL invalid_cli option=%s value=%s" % [
			str(capacity_options.get("option", "capacity")),
			str(capacity_options.get("value", "")),
		])
		get_tree().quit(2)
		return
	if not _start_mp_server(
			self, port, bind_address,
			str(data_paths["admins"]), str(data_paths["punishments"]),
			str(data_paths["audit"]), punishment_address_source,
			int(capacity_options["max_connections"]),
			int(capacity_options["max_pending_admissions"]), true):
		get_tree().quit(3)
		return
	var console := ServerConsoleScript.new()
	console.name = "ServerConsole"
	console.server = server_node
	add_child(console)
	Log.server_console("[EasyServer] console ready; type 'help' for commands")


static func _parse_server_capacity_options(args: PackedStringArray) -> Dictionary:
	var max_connections_text := str(EasyServer.MAX_CONNECTIONS)
	var max_pending_admissions_text := ""
	var max_pending_admissions_explicit := false
	for arg in args:
		if arg.begins_with("--max-connections="):
			max_connections_text = arg.trim_prefix("--max-connections=")
		elif arg.begins_with("--max-pending-admissions="):
			max_pending_admissions_explicit = true
			max_pending_admissions_text = arg.trim_prefix("--max-pending-admissions=")
	if not max_connections_text.is_valid_int():
		return {"ok": false, "option": "max-connections", "value": max_connections_text}
	var max_connections := int(max_connections_text)
	if max_connections < 1 or max_connections > EasyServer.MAX_CONNECTIONS:
		return {"ok": false, "option": "max-connections", "value": max_connections_text}
	var max_pending_admissions := mini(
		EasyServer.DEFAULT_MAX_PENDING_ADMISSIONS, max_connections)
	if max_pending_admissions_explicit:
		if not max_pending_admissions_text.is_valid_int():
			return {
				"ok": false,
				"option": "max-pending-admissions",
				"value": max_pending_admissions_text,
			}
		max_pending_admissions = int(max_pending_admissions_text)
		if max_pending_admissions < 1 or max_pending_admissions > max_connections:
			return {
				"ok": false,
				"option": "max-pending-admissions",
				"value": max_pending_admissions_text,
			}
	return {
		"ok": true,
		"max_connections": max_connections,
		"max_pending_admissions": max_pending_admissions,
	}


func _server_data_paths(args: PackedStringArray) -> Dictionary:
	var data_directory := OS.get_executable_path().get_base_dir().path_join("server-data")
	var admins_path := ""
	var punishments_path := ""
	var audit_path := ""
	for arg in args:
		if arg.begins_with("--data-dir="):
			data_directory = arg.substr(11).strip_edges()
		elif arg.begins_with("--admins-file="):
			admins_path = arg.substr(14).strip_edges()
		elif arg.begins_with("--punishments-file="):
			punishments_path = arg.substr(19).strip_edges()
		elif arg.begins_with("--audit-file="):
			audit_path = arg.substr(13).strip_edges()
	if admins_path.is_empty():
		admins_path = data_directory.path_join("admins.json")
	if punishments_path.is_empty():
		punishments_path = data_directory.path_join("punishments.json")
	if audit_path.is_empty():
		audit_path = data_directory.path_join("moderation-audit.jsonl")
	return {"admins": admins_path, "punishments": punishments_path, "audit": audit_path}


func _has_adminctl(args: PackedStringArray) -> bool:
	for arg in args:
		if arg == "--adminctl" or arg.begins_with("--adminctl="):
			return true
	return false


func _run_adminctl(args: PackedStringArray) -> void:
	var operation := ""
	var admin_id := ""
	for index in range(args.size()):
		var arg := args[index]
		if arg.begins_with("--adminctl="):
			operation = arg.substr(11).to_lower()
			if index + 1 < args.size():
				admin_id = args[index + 1]
			break
		if arg == "--adminctl":
			if index + 1 < args.size():
				operation = args[index + 1].to_lower()
			if index + 2 < args.size():
				admin_id = args[index + 2]
			break
	var paths := _server_data_paths(args)
	var store: AdminStore = AdminStoreScript.new()
	if not store.load_or_create(str(paths["admins"])):
		printerr("adminctl: %s" % store.last_error)
		get_tree().quit(2)
		return
	if operation == "list":
		var records := store.list_records()
		if records.is_empty():
			print("No administrators")
		else:
			for record in records:
				print("%s enabled=%s" % [record.get("id", ""), record.get("enabled", false)])
		get_tree().quit(0)
		return
	if operation not in ["add", "rotate", "revoke"] or admin_id.is_empty():
		printerr("Usage: --adminctl add|rotate|revoke <admin_id> | --adminctl list")
		get_tree().quit(2)
		return
	var result: Dictionary
	match operation:
		"add": result = store.add(admin_id)
		"rotate": result = store.rotate(admin_id)
		"revoke": result = store.revoke(admin_id)
	if not bool(result.get("ok", false)):
		printerr("adminctl: %s" % result.get("error", "operation failed"))
		get_tree().quit(3)
		return
	if result.has("credential"):
		print("%s succeeded. Credential (shown once): %s" % [
			operation.capitalize(), result["credential"]])
	else:
		print("%s succeeded for %s" % [operation.capitalize(), result.get("admin_id", admin_id)])
	get_tree().quit(0)


func _get_application_args() -> PackedStringArray:
	var args := OS.get_cmdline_args()
	for arg in OS.get_cmdline_user_args():
		if not args.has(arg):
			args.append(arg)
	return args


func _parse_global_vars_mode(args: PackedStringArray) -> String:
	for arg in args:
		if not arg.begins_with("--global-vars="):
			continue
		var mode := arg.substr(14).to_lower()
		if mode == "unconscious":
			return mode
		Log.warn("[setup_screen] unsupported global variables mode '%s'; feature disabled" % mode)
	return ""


func _on_browse_pressed() -> void:
	if _game_path_browsing:
		return
	_game_path_browsing = true
	if is_instance_valid(_android_runtime):
		_android_runtime.call("browse_game_directory", game_path.text)
		return
	game_path_file_dialog.popup_centered_ratio(0.75)


func _on_android_browse_completed(path: String) -> void:
	if not path.is_empty():
		game_path.text = path
	_on_game_path_browse_finished()

func _on_dir_selected(dir: String) -> void:
	game_path.text = dir
	_on_game_path_browse_finished()


func _on_game_path_browse_finished() -> void:
	# Browsing is independent of multiplayer and survives preview suspension.
	_game_path_browsing = false
	_request_launcher_auto_refresh()


static func _location_game_key(path: String) -> String:
	path = path.strip_edges().replace("\\", "/")
	if path.is_empty():
		return ""
	path = ProjectSettings.globalize_path(path).simplify_path().trim_suffix("/")
	return path.to_lower() if OS.get_name() == "Windows" else path


func _load_location_directories(cfg: ConfigFile) -> Dictionary:
	var result: Dictionary = {}
	var stored: Variant = cfg.get_value("locations", "directories_by_game", {})
	if stored is Dictionary:
		for key: Variant in stored:
			if key is String and stored[key] is String:
				var normalized := _location_game_key(key)
				if not normalized.is_empty() and not stored[key].strip_edges().is_empty():
					result[normalized] = stored[key].strip_edges()
	return result


func _on_advanced_settings_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_advanced_keyboard_activation = false
	elif event is InputEventScreenTouch and event.pressed:
		_advanced_keyboard_activation = false
	elif event.is_action_pressed("ui_accept"):
		_advanced_keyboard_activation = true


func _on_advanced_settings_pressed() -> void:
	var keyboard := _advanced_keyboard_activation
	_advanced_keyboard_activation = false
	var key := _location_game_key(game_path.text)
	advanced_options_popup.call("open_for_game", key,
		str(_location_directories_by_game.get(key, "")), keyboard)


func _on_location_source_save_requested(key: String, directory: String) -> void:
	if key.is_empty() or key != _location_game_key(game_path.text):
		advanced_options_popup.call("show_save_error", "游戏目录已变化，请重新打开其他设置。")
		return
	var candidate := _location_directories_by_game.duplicate(true)
	if directory.is_empty():
		candidate.erase(key)
	else:
		candidate[key] = directory
	var error := _save_location_directories_now(candidate)
	if error != OK:
		advanced_options_popup.call("show_save_error", "设置保存失败：%s" % error_string(error))
		return
	_location_directories_by_game = candidate
	advanced_options_popup.call("dismiss")


func _save_location_directories_now(directories: Dictionary) -> Error:
	return SettingsStore.patch(_SETTINGS_PATH, {"locations": {"directories_by_game": directories}}).error


func _load_location_source_for_launch(path: String) -> Variant:
	var directory := str(_location_directories_by_game.get(_location_game_key(path), ""))
	if directory.is_empty():
		return null
	var loaded := LocationConfigLoaderScript.load_directory(directory)
	if loaded.ok:
		return loaded.data
	location_config_error.dialog_text = "%s\n问题文件：%s\n本次游戏将不显示地点信息。" % [
		loaded.error, loaded.file]
	if is_instance_valid(_android_runtime):
		_android_runtime.call("show_location_error", location_config_error.dialog_text)
	else:
		location_config_error.popup_centered.call_deferred(Vector2i(UiScale.physical_int(440), 1))
	return {}


func _on_mp_name_text_changed(new_text: String) -> void:
	var safe_name := InputLimits.sanitize_nickname(new_text)
	if safe_name == new_text:
		return
	var previous_caret := mp_name.caret_column
	var safe_caret := InputLimits.sanitize_nickname(
		new_text.substr(0, previous_caret)
	).length()
	mp_name.text = safe_name
	mp_name.caret_column = mini(safe_caret, safe_name.length())

func _on_audio_volume_changed(value: float) -> void:
	AudioServer.set_bus_volume_db(
		AudioServer.get_bus_index("Master"),
		linear_to_db(value / 100.0)
	)

func _apply_audio_muted() -> void:
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Master"), _audio_muted)
	engine.set_native_midi_muted(_audio_muted)
	chat_ctrl.call("set_audio_muted", _audio_muted)


func _on_audio_muted_changed(enabled: bool) -> void:
	_audio_muted = enabled
	_apply_audio_muted()
	var saved := SettingsStore.patch(_SETTINGS_PATH, {"audio": {"muted": _audio_muted}})
	if saved.error != OK:
		if saved.stage == "load":
			Log.warn("[setup_screen] could not load settings for audio mute: %s" % error_string(saved.error))
		else:
			Log.warn("[setup_screen] could not save audio mute: %s" % error_string(saved.error))


func _on_save_and_run() -> void:
	if engine.is_shutdown_requested():
		return
	if Transition.is_playing:
		return
	if game_path.text.strip_edges().is_empty():
		push_warning("[main] Game path is empty")
		return
	save_and_run.disabled = true
	_suspend_launcher_preview()
	_save_settings()
	Transition.custom(_launch_game, TransitionPresets.get_slow_fade())

func _save_settings() -> void:
	var safe_player_name := InputLimits.sanitize_nickname(mp_name.text)
	mp_name.text = safe_player_name
	SettingsStore.replace(_SETTINGS_PATH, {
		"game": {"path": game_path.text.strip_edges(), "run_on_start": run_on_start.button_pressed},
		"audio": {"volume": audio_slider.value, "muted": _audio_muted},
		"multiplayer": {
			"enabled": mp_enable.button_pressed, "name": safe_player_name, "url": mp_url.text,
			"host_locally": mp_server.button_pressed, "host_parameters": _saved_host_parameters,
			"private_mode": _private_mode_desired, "nametag_mode": _nametag_mode,
			"admin_credentials": _admin_credentials_by_endpoint.duplicate(true),
		},
		"locations": {"directories_by_game": _location_directories_by_game.duplicate(true)},
	})


func _on_privacy_mode_desired_changed(enabled: bool) -> void:
	_private_mode_desired = enabled
	var saved := SettingsStore.patch(_SETTINGS_PATH, {"multiplayer": {"private_mode": _private_mode_desired}})
	if saved.error != OK:
		if saved.stage == "load":
			Log.warn("[setup_screen] could not load settings for privacy mode: %s" % error_string(saved.error))
		else:
			Log.warn("[setup_screen] could not save privacy mode: %s" % error_string(saved.error))


func _on_nametag_mode_changed(mode: int) -> void:
	_nametag_mode = _sanitize_nametag_mode(mode)
	var saved := SettingsStore.patch(_SETTINGS_PATH, {"multiplayer": {"nametag_mode": _nametag_mode}})
	if saved.error != OK:
		if saved.stage == "load":
			Log.warn("[setup_screen] could not load settings for nametag mode: %s" % error_string(saved.error))
		else:
			Log.warn("[setup_screen] could not save nametag mode: %s" % error_string(saved.error))


func _sanitize_nametag_mode(mode: int) -> int:
	return mode if mode >= 0 and mode <= 3 else _NAMETAG_MODE_COMPACT

func _start_engine_watcher() -> void:
	if _watch_timer:
		_watch_timer.stop()
		_watch_timer.queue_free()
	_watch_timer = Timer.new()
	_watch_timer.wait_time = 0.5
	_watch_timer.one_shot = false
	_watch_timer.timeout.connect(_on_watch_timer_timeout)
	add_child(_watch_timer)
	_watch_timer.start()

func _on_watch_timer_timeout() -> void:
	if engine.is_running():
		return
	_watch_timer.stop()
	_watch_timer.queue_free()
	_watch_timer = null
	_on_engine_stopped()

func _on_engine_stopped() -> void:
	if is_instance_valid(_android_runtime):
		_android_runtime.call("game_stopped")
	_local_host_client = null
	Transition.outro()
	godot_menu_layer.visible = true
	engine_layer.visible = false
	save_and_run.disabled = false
	if multiplayer_node:
		multiplayer_node.queue_free()
		multiplayer_node = null
	if server_node:
		server_node.queue_free()
		server_node = null
	chat_ctrl.call("_set_chat_enabled", false)
	chat_ctrl.clear_chat()
	chat_ctrl.mp_connection = null
	chat_ctrl.call("set_multiplayer_enabled_context", false)
	chat_ctrl.call("set_location_runtime", null)
	chat_ctrl.call("refresh_local_theme")
	world_location_banner.call("set_location_runtime", null)
	world_location_banner.call("reset_banner")
	if location_runtime:
		location_runtime.queue_free()
		location_runtime = null
	_resume_launcher_preview()

func _launch_game() -> void:
	if engine.is_shutdown_requested():
		return
	_suspend_launcher_preview()
	var path := game_path.text.strip_edges()
	# Both the button and saved --autorun path enter here.
	if is_instance_valid(_android_runtime) and not _android_runtime.call("prepare_launch", path):
		save_and_run.disabled = false
		_resume_launcher_preview()
		return
	if path.is_empty():
		push_warning("[main] Game path is empty")
		save_and_run.disabled = false
		_resume_launcher_preview()
		return
	
	engine.set_game_path(path)
	_on_audio_volume_changed(audio_slider.value)
	_apply_audio_muted()
	engine.start_game()
	if not engine.is_running():
		save_and_run.disabled = false
		_resume_launcher_preview()
		if is_instance_valid(_android_runtime):
			_android_runtime.call("show_launch_error")
		return
	engine.mp_set_nametag_mode(_nametag_mode)
	chat_ctrl.call("refresh_local_theme")
	chat_ctrl.call("set_nametag_mode", _nametag_mode, false)
	if location_runtime:
		location_runtime.queue_free()
	location_runtime = LocationRuntimeScript.new()
	location_runtime.name = "LocationRuntime"
	engine.add_child(location_runtime)
	location_runtime.initialize(engine, _load_location_source_for_launch(path))
	chat_ctrl.call("set_location_runtime", location_runtime)
	world_location_banner.call("set_location_runtime", location_runtime)
	
	godot_menu_layer.visible = false
	engine_layer.visible = true
	chat_ctrl.call("_set_chat_enabled", true)
	chat_field.visible = true
	chat_field.editable = true
	chat_ctrl.call("set_multiplayer_enabled_context", mp_enable.button_pressed)
	chat_ctrl.call("set_privacy_mode_desired", _private_mode_desired)
	
	_start_engine_watcher()
	if is_instance_valid(_android_runtime):
		_android_runtime.call("game_started")
	
	if mp_enable.button_pressed:
		if multiplayer_node:
			chat_ctrl.mp_connection = null
			multiplayer_node.queue_free()
			multiplayer_node = null
		if server_node:
			server_node.queue_free()
			server_node = null
		if mp_server.button_pressed:
			_start_configured_host(engine)
		else:
			_start_mp_client(engine)

func _on_mp_enable_toggled(toggled_on: bool) -> void:
	mp_name.editable = toggled_on
	mp_url.editable = toggled_on and not mp_server.button_pressed
	mp_server.disabled = not toggled_on
	host_advanced_button.disabled = not toggled_on
	if not toggled_on:
		mp_server.button_pressed = false
		_auto_probe_pending = false
		if is_instance_valid(_server_status_probe):
			_server_status_probe.call("invalidate")
		if admin_credential_popup.is_node_ready():
			admin_credential_popup.call("dismiss")
		if host_advanced_popup.is_node_ready():
			host_advanced_popup.call("dismiss")
	else:
		_request_launcher_auto_refresh()
	_refresh_server_status()
