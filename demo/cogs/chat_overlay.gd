extends Control

# bde: i'll strip placeholder text for now o.o

signal privacy_mode_desired_changed(enabled: bool)
signal nametag_mode_changed(mode: int)
signal audio_muted_changed(enabled: bool)
signal chat_open_changed(open: bool)
signal location_presentation_changed
signal native_close_requested(discard: bool)
signal native_focus_requested()
var touch_input_available: Callable
var touch_chat := false
const _KEYBOARD_MAPPING := preload("res://cogs/easyrpg_keyboard_mapping.gd")
var _chat_toggle_sources: Dictionary = {}

const MULTIPLAYER_SIGNAL_METHODS := {
	"global_chat_cooldown_started": "_on_global_chat_cooldown_started",
	"global_chat_accepted": "_on_global_chat_accepted",
	"global_chat_rejected": "_on_global_chat_rejected",
	"room_chat_cooldown_started": "_on_room_chat_cooldown_started",
	"room_chat_accepted": "_on_room_chat_accepted",
	"room_chat_rejected": "_on_room_chat_rejected",
	"room_ready_changed": "_on_chat_readiness_changed",
	"global_chat_server_ready_changed": "_on_chat_readiness_changed",
	"room_chat_server_ready_changed": "_on_chat_readiness_changed",
	"connection_state_changed": "_on_multiplayer_connection_state_changed",
	"presence_changed": "_on_presence_changed",
	"privacy_state_changed": "_on_privacy_state_changed",
	"privacy_cooldown_started": "_on_privacy_cooldown_started",
	"privacy_server_ready_changed": "_on_privacy_server_ready_changed",
	"reconnect_cooldown_started": "_on_reconnect_cooldown_started",
	"reconnect_ready_changed": "_on_reconnect_ready_changed",
	"local_menu_theme_changed": "_on_local_menu_theme_changed",
	"moderation_status_changed": "_on_moderation_status_changed",
	"admin_authentication_changed": "_on_admin_authentication_changed",
}

var _audio_muted := false
var _local_theme: LocalMenuTheme

@export var mp_connection: EasyMultiplayer = null:
	set(value):
		if mp_connection == value:
			return
		_unbind_multiplayer_connection()
		mp_connection = value
		if is_node_ready():
			_bind_multiplayer_connection()
			_rerender_message_history()
# TODO: menu option for this thing or a debug command
@export var chat_history_limit: int = 250:
	set(value):
		chat_history_limit = maxi(0, value)
		if is_node_ready():
			_delete_old_messages()
@export var chat_fade_rate: float = 0.75
@export var chat_enabled = false

@onready var chat_text_field: LineEdit = %ChatField
@onready var chat_text_field_frame: PanelContainer = %ChatFieldFrame
@onready var chat_input_row: HBoxContainer = %ChatInputRow
@onready var global_chat_toggle: GlobalChatToggle = %GlobalChatToggle
@onready var chat_vbox: Control = %MessageContainer
@onready var chat_selection: Control = %ChatSelection
@onready var chat_history_scroll: Control = %ChatHistoryScroll
@onready var chat_virtual_content: Control = %ChatVirtualContent
@onready var chat_overlay_layer: CanvasLayer = %ChatOverlayLayer
@onready var current_location_modules: VBoxContainer = %CurrentLocationModules
@onready var current_location_localized: RichTextLabel = %CurrentLocationLocalized
@onready var current_location_english: RichTextLabel = %CurrentLocationEnglish
@onready var multiplayer_status_vbox: VBoxContainer = %MultiplayerStatusVBox
@onready var connection_status_indicator: PanelContainer = %ConnectionStatusIndicator
@onready var connection_status_icon: TextureRect = %ConnectionStatusIcon
@onready var connection_status_text: Label = %ConnectionStatusText
@onready var reconnect_button: GlobalChatToggle = %ReconnectButton
@onready var privacy_mode_toggle: PrivacyModeToggle = %PrivacyModeToggle
@onready var nametag_style_button: Button = %NametagStyleButton
@onready var audio_mute_toggle: Button = %AudioMuteToggle
@onready var fullscreen_button: Button = %FullscreenButton
@onready var player_list_button: Button = %PlayerListButton
@onready var server_player_count_panel: PanelContainer = %ServerPlayerCountPanel
@onready var server_player_count: Label = %ServerPlayerCount
@onready var world_player_count_panel: PanelContainer = %WorldPlayerCountPanel
@onready var world_player_count: Label = %WorldPlayerCount

const _CHAT_MESSAGE_STYLEBOX := preload("res://resources/chat_stylebox.tres")
const _CHAT_TOGGLE_ON_STYLEBOX := preload("res://resources/chat_toggle_on_stylebox.tres")
const _CHAT_PLAYER_CONTEXT_MENU := preload("res://cogs/chat_player_context_menu.gd")
const _PLAYER_LIST_POPUP := preload("res://cogs/player_list_popup.gd")
const _NAMETAG_STYLE_POPUP := preload("res://cogs/nametag_style_popup.gd")
const _PLAYER_LIST_ICON := preload("res://resources/icons/user-list-fill-16.svg")
const _ADMIN_ICON := preload("res://resources/icons/usershield.svg")

const InputLimits := preload("res://cogs/input_limits.gd")
const _CHAT_MENTION_MARKS := preload("res://cogs/chat_mention_marks.gd")
const _GLOBAL_CHAT_ICON := preload("res://resources/icons/globe-earth-bold.svg")
const _GLOBAL_CHAT_MESSAGE_ICON := preload("res://resources/icons/speaker.svg")
const _RECONNECT_ICON := preload("res://resources/icons/reload.svg")
const _AUDIO_ENABLED_ICON := preload("res://resources/icons/speaker-2-fill.svg")
const _AUDIO_MUTED_ICON := preload("res://resources/icons/speaker-slash-fill.svg")
const _STATUS_CONNECTED_ICON := preload("res://resources/icons/green-circle.svg")
const _STATUS_CONNECTING_ICON := preload("res://resources/icons/yellow-circle.svg")
const _STATUS_DISCONNECTED_ICON := preload("res://resources/icons/red-circle.svg")
const _STATUS_PRIVATE_ICON := preload("res://resources/icons/circle.svg")
const _GAME_UI_FONT := preload("res://resources/webpage_game_ui_font.tres")
const _CHAT_FIELD_NORMAL_STYLE := preload("res://resources/chat_stylebox.tres")
const _CHAT_FIELD_FOCUS_STYLE := preload("res://resources/chat_stylebox_focus.tres")
const _WEBPAGE_THEME_TEXT_RUNTIME := preload("res://cogs/webpage_theme_text_runtime.gd")
const _WEBPAGE_THEME_TOOLTIP_RUNTIME := preload("res://cogs/webpage_theme_tooltip_runtime.gd")
const _CHAT_SPOILERS := preload("res://cogs/chat_spoilers.gd")
const ChatMentions := preload("res://cogs/chat_mentions.gd")
const PlayerName := preload("res://cogs/chat_player_name.gd")
const _CHAT_SPOILER_LABEL := preload("res://cogs/chat_spoiler_label.gd")
const _CHAT_SELECTION_OVERLAY := preload("res://cogs/chat_selection_overlay.gd")
const _GAME_UI_SHADOW_COLOR := Color(0.0, 0.0, 0.0, 1.0)
const _CHAT_MAX_DESIGN_WIDTH := 320.0
const _LOCATION_TEXT_LAYOUT := preload("res://cogs/location_text_layout.gd")
const _CHAT_VISIBLE_LINE_LIMIT := 12
const _CHAT_OVERSCAN_LINE_LIMIT := 12
const _CHAT_SCROLLBAR_DESIGN_WIDTH := 6.0
const _CHAT_JUMP_ICON := preload("res://resources/icons/chat-jump-latest.svg")

var _chat_open = false
var _chat_background_geometry_sync_queued := false
var _location_width_queued := false
var _chat_background_viewport_size := Vector2.ZERO
var _chat_background_resize_sync_frames := 0
var _location_runtime: Node = null
var _display_language := "en"
var _current_location_has_localized := false
var _current_location_has_english := false
var _pending_room_chat_text := ""
var _pending_room_chat_mentions: Array = []
var _pending_room_chat_revision := 0
var _pending_global_chat_text := ""
var _pending_global_chat_mentions: Array = []
var _pending_global_chat_revision := -1
var _message_records: Array[Dictionary] = []
var _message_layouts: Array[Dictionary] = []
var _record_index_by_id: Dictionary = {}
var _next_message_id := 1
var _chat_render_width := 0.0
var _chat_viewport_height := 0.0
var _history_layout_serial := 0
var _history_layout_queued := false
var _history_layout_dirty := false
var _last_history_layout_frame := -1
const _CHAT_PREPARE_BUDGET_USEC := 2000
var _history_prepare_generation := 0
var _virtual_render_waiting := false
var _last_message_creation_frame := -1
var _restore_started_usec := 0
var _restore_first_visible := false
var _chat_lifecycle := 0
var _chat_paint_revision := 0
var _selection_history_dirty := true
var _history_geometry_commit_queued := false
var _layout_is_history := false
var _transient_scroll_offset := 0.0
var _history_render_queued := false
var _force_history_render := false
var _follow_latest := true
var _saved_history_follow_latest := true
var _saved_history_anchor: Dictionary = {}
var _pending_history_anchor: Dictionary = {}
var _pending_history_follow_latest := true
var _suppress_scroll_state := false
var _history_overflow := false
var _jump_latest_layer: Control = null
var _jump_latest_button: Button = null
var _jump_latest_background: ColorRect = null
var _jump_latest_flash_tween: Tween = null
var _jump_latest_flash_elapsed := -1.0
var _pending_jump_latest_mention_id := 0
var _history_scroll_bar: VScrollBar = null
var _theme_text_runtime: Node = null
var _theme_tooltip_runtime: Node = null
var _chat_background: Panel = null
var _nametag_preview_rect: TextureRect = null
var _nametag_preview_textures: Array = []
var _message_reflow_pending := false
var _chat_selection_commit_queued := false
var _player_context_menu: ChatPlayerContextMenu = null
var _player_list_popup: PlayerListPopup = null
var _nametag_style_popup: NametagStylePopup = null
var _nametag_engine: Node = null
var _nametag_mode := 2
var _multiplayer_enabled_context := false
var _privacy_desired := false
var _privacy_authoritative := false
var _privacy_transition_pending := false
var _total_player_count := -1
var _room_player_count := -1
var _last_moderation_display_second := -1
var _ui_normal_color := Color.WHITE
var _ui_strong_color := Color(1.0, 0.82, 0.28, 1.0)
var _ui_muted_color := Color(0.58, 0.58, 0.62, 1.0)
var _local_menu_theme_system_name := ""
var _local_menu_theme_initialized := false
var _suppress_player_list_open_on_release := false
var _suppress_nametag_open_on_release := false
# p4o-a7o: yes im aware that Tweens exist but i did not want to pause
# the tweens when the chat was open, so i did it in this very goofy way
# bde: if it works, it works :3
class FadeTween:
	var countdown: float = 5
	var t: float = 1
	var mention_elapsed: float = -1.0
var _fade_tweens: Array[FadeTween] = []

func _ready() -> void:
	# Native LineEdit shadows are opt-in; other inputs keep their original rendering.
	chat_text_field.add_theme_constant_override("shadow_enabled", 1)
	_local_theme = LocalMenuTheme.new()
	add_child(_local_theme)
	_local_theme.changed.connect(_on_local_theme_source_changed)
	_theme_text_runtime = _WEBPAGE_THEME_TEXT_RUNTIME.new()
	add_child(_theme_text_runtime)
	_install_chat_background()
	_install_chat_history_viewport()
	_install_chat_selection_overlay()
	MpEvents.on_chat_message.connect(add_chat_message)
	MpEvents.on_chat_record.connect(_append_message)
	MpEvents.on_chat_message_metadata.connect(add_chat_message_metadata)
	MpEvents.on_global_chat_message_raw.connect(add_global_chat_message)
	MpEvents.on_global_chat_message_metadata.connect(add_global_chat_message_metadata)
	chat_text_field.add_to_group("rpg_godo_chat_input")
	chat_text_field.max_length = 0 if chat_text_field.has_method("get_submission") else InputLimits.CHAT_MESSAGE_MAX_CHARACTERS
	chat_text_field.text_changed.connect(_on_chat_field_text_changed)
	chat_text_field.focus_entered.connect(_on_chat_field_focus_entered)
	chat_text_field.focus_exited.connect(_on_chat_field_focus_exited)
	global_chat_toggle.toggled.connect(_on_global_chat_toggled)
	global_chat_toggle.set_cooldown_source(_chat_cooldown_snapshot)
	reconnect_button.pressed.connect(_on_reconnect_pressed)
	privacy_mode_toggle.toggled.connect(_on_privacy_mode_toggled)
	nametag_style_button.pressed.connect(_on_nametag_style_pressed)
	nametag_style_button.button_up.connect(_clear_nametag_release_suppression, CONNECT_DEFERRED)
	audio_mute_toggle.toggled.connect(_on_audio_mute_toggled)
	fullscreen_button.pressed.connect(_on_fullscreen_pressed)
	WebpageThemeTooltipRuntime.set_control_tooltip(fullscreen_button, WindowModeController.TOOLTIP)
	player_list_button.pressed.connect(_on_player_list_pressed)
	player_list_button.button_up.connect(_clear_player_list_release_suppression, CONNECT_DEFERRED)
	player_list_button.icon = _PLAYER_LIST_ICON
	_update_global_chat_toggle_icon()
	_apply_chat_width_limit()
	reconnect_button.icon = _RECONNECT_ICON
	chat_selection.connect("link_clicked", _on_chat_message_meta_clicked)
	chat_selection.connect("spoiler_reveal_requested", _on_spoiler_reveal_requested)
	chat_selection.gui_input.connect(_on_chat_selection_gui_input)
	current_location_localized.meta_clicked.connect(_on_chat_message_meta_clicked)
	current_location_english.meta_clicked.connect(_on_chat_message_meta_clicked)
	get_viewport().size_changed.connect(_update_current_location_width)
	get_viewport().size_changed.connect(_schedule_chat_message_reflow)
	get_viewport().size_changed.connect(_apply_chat_width_limit)
	resized.connect(_apply_chat_width_limit)
	resized.connect(_update_current_location_width)
	if not UiScale.scale_changed.is_connected(_on_ui_scale_changed):
		UiScale.scale_changed.connect(_on_ui_scale_changed)
	chat_input_row.set_visible(false)
	_apply_game_ui_text_rendering(self)
	_apply_game_ui_icon_rendering()
	chat_text_field_frame.add_theme_stylebox_override("panel", _CHAT_FIELD_NORMAL_STYLE)
	_player_context_menu = _CHAT_PLAYER_CONTEXT_MENU.new()
	add_child(_player_context_menu)
	_player_context_menu.setup(mp_connection, chat_selection)
	_player_context_menu.mention_requested.connect(_on_player_mention_requested)
	_player_context_menu.right_click_released.connect(_open_chat_context_at)
	_player_list_popup = _PLAYER_LIST_POPUP.new()
	add_child(_player_list_popup)
	_player_list_popup.setup(mp_connection, self)
	_player_list_popup.popup_hide.connect(_on_player_list_popup_hidden)
	_player_list_popup.set_ui_theme_colors(
		_ui_normal_color, _ui_strong_color, _ui_muted_color)
	_nametag_style_popup = _NAMETAG_STYLE_POPUP.new()
	add_child(_nametag_style_popup)
	_nametag_style_popup.setup(mp_connection)
	_nametag_style_popup.set_nametag_mode(_nametag_mode)
	_nametag_style_popup.mode_selected.connect(_on_nametag_mode_selected)
	_nametag_style_popup.popup_hide.connect(_on_nametag_style_popup_hidden)
	_nametag_style_popup.visibility_changed.connect(_refresh_nametag_style_button)
	_refresh_player_list_button_style()
	_refresh_nametag_style_button()
	_update_current_location_width()
	_bind_multiplayer_connection()
	_bind_location_runtime()
	_refresh_current_location()
	_refresh_multiplayer_status_ui()
	_set_chat_enabled(chat_enabled)
	_local_theme.set_engine(_nametag_engine)
	UiScale.safe_area_changed.connect(_layout_corner_actions)
	_layout_corner_actions.call_deferred()


func get_theme_source() -> Node:
	return _local_theme if is_instance_valid(_local_theme) and _local_theme.active() else mp_connection


func refresh_local_theme() -> void:
	_local_theme.refresh()


func _on_local_theme_source_changed() -> void:
	_local_menu_theme_initialized = false
	_refresh_local_menu_theme()


func _layout_corner_actions() -> void:
	$TopLeftActions.position.y = UiScale.corner_top_inset(false)
	multiplayer_status_vbox.position.y = UiScale.corner_top_inset(true)


func _install_chat_selection_overlay() -> void:
	var legacy_selection := chat_selection as RichTextLabel
	if legacy_selection != null:
		legacy_selection.clear()
		legacy_selection.selection_enabled = false
		legacy_selection.context_menu_enabled = false
	chat_selection.set_script(_CHAT_SELECTION_OVERLAY)
	chat_selection.call("setup", chat_vbox, chat_history_scroll, _history_scroll_bar)


func _install_chat_history_viewport() -> void:
	chat_history_scroll.clip_contents = true
	chat_virtual_content.clip_contents = false
	for control in [chat_history_scroll, chat_virtual_content, chat_vbox, chat_selection]:
		UiScale.mark_geometry_physical(control)
	var scroll_bar := VScrollBar.new()
	_history_scroll_bar = scroll_bar
	scroll_bar.name = "ChatHistoryScrollBar"
	UiScale.mark_geometry_physical(scroll_bar)
	scroll_bar.custom_minimum_size.x = _chat_scrollbar_physical_width()
	scroll_bar.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var track := StyleBoxFlat.new()
	track.bg_color = Color(1.0, 1.0, 1.0, 0.08)
	var grabber := StyleBoxFlat.new()
	grabber.bg_color = Color(1.0, 1.0, 1.0, 0.55)
	grabber.corner_radius_top_left = 1
	grabber.corner_radius_top_right = 1
	grabber.corner_radius_bottom_left = 1
	grabber.corner_radius_bottom_right = 1
	scroll_bar.add_theme_stylebox_override("scroll", track)
	scroll_bar.add_theme_stylebox_override("scroll_focus", track)
	scroll_bar.add_theme_stylebox_override("grabber", grabber)
	scroll_bar.add_theme_stylebox_override("grabber_highlight", grabber)
	scroll_bar.add_theme_stylebox_override("grabber_pressed", grabber)
	scroll_bar.value_changed.connect(_on_chat_scroll_changed)
	_jump_latest_layer = Control.new()
	_jump_latest_layer.name = "ChatJumpLatestLayer"
	_jump_latest_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_jump_latest_layer.clip_contents = false
	_jump_latest_layer.z_index = 20
	UiScale.mark_geometry_physical(_jump_latest_layer)
	add_child(_jump_latest_layer)
	_jump_latest_layer.add_child(scroll_bar)
	scroll_bar.visible = false
	_jump_latest_button = Button.new()
	_jump_latest_button.name = "ChatJumpLatestButton"
	_jump_latest_button.icon = _CHAT_JUMP_ICON
	_jump_latest_button.expand_icon = true
	_jump_latest_button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_jump_latest_button.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_jump_latest_button.focus_mode = Control.FOCUS_NONE
	_jump_latest_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	UiScale.mark_geometry_physical(_jump_latest_button)
	_jump_latest_button.visible = false
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
		_jump_latest_button.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	_jump_latest_button.pressed.connect(_on_jump_latest_pressed)
	_jump_latest_button.gui_input.connect(_on_jump_latest_gui_input)
	_jump_latest_layer.add_child(_jump_latest_button)
	# Theme styling intentionally empties Button backgrounds. This surface has
	# no layout/input responsibility and remains behind the existing icon.
	_jump_latest_background = ColorRect.new()
	_jump_latest_background.name = "ChatJumpLatestBackground"
	_jump_latest_background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_jump_latest_background.show_behind_parent = true
	_jump_latest_background.use_parent_material = false
	UiScale.mark_geometry_physical(_jump_latest_background)
	_jump_latest_button.add_child(_jump_latest_background)
	_jump_latest_background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_set_jump_latest_flash_elapsed(-1.0)
	_apply_game_ui_text_rendering(_jump_latest_button)
	_WEBPAGE_THEME_TOOLTIP_RUNTIME.set_control_tooltip(
		_jump_latest_button, "跳转底端")


func _install_chat_background() -> void:
	var stack := chat_history_scroll.get_parent() as Control
	if stack == null:
		return
	var background_layer := Control.new()
	background_layer.name = "ChatMessageBackgroundLayer"
	background_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	background_layer.mouse_behavior_recursive = Control.MOUSE_BEHAVIOR_DISABLED
	stack.add_child(background_layer)
	stack.move_child(background_layer, 0)
	background_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background_layer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	background_layer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_chat_background = Panel.new()
	_chat_background.name = "ChatMessageBackground"
	_chat_background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_chat_background.add_theme_stylebox_override("panel", _CHAT_MESSAGE_STYLEBOX)
	_chat_background.visible = false
	background_layer.add_child(_chat_background)
	chat_vbox.resized.connect(_queue_chat_background_geometry_sync)
	stack.resized.connect(_queue_chat_background_geometry_sync)


func _new_chat_message_content_style() -> StyleBox:
	var style := _CHAT_MESSAGE_STYLEBOX.duplicate() as StyleBox
	if style is StyleBoxFlat:
		(style as StyleBoxFlat).bg_color = Color.TRANSPARENT
	style.content_margin_top = 0.0
	style.content_margin_bottom = 0.0
	return style


func _update_chat_background_visibility() -> void:
	_refresh_chat_message_presentation()
	_queue_chat_background_geometry_sync()


func _queue_chat_background_geometry_sync() -> void:
	if _chat_background_geometry_sync_queued:
		return
	_chat_background_geometry_sync_queued = true
	call_deferred("_sync_chat_background_geometry")


func _sync_chat_background_geometry() -> void:
	_chat_background_geometry_sync_queued = false
	if not is_instance_valid(_chat_background):
		return
	_align_chat_stack_to_row_bottom()
	_update_jump_latest_geometry()
	var background_layer := _chat_background.get_parent() as Control
	if not is_instance_valid(background_layer):
		return
	if _message_layouts.is_empty() or _chat_viewport_height <= 0.0:
		_chat_background.visible = false
		_chat_background.position = Vector2.ZERO
		_chat_background.size = Vector2.ZERO
		return
	var inverse := background_layer.get_global_transform_with_canvas().affine_inverse()
	var scroll_transform := chat_history_scroll.get_global_transform_with_canvas()
	var origin := inverse * (scroll_transform * Vector2.ZERO)
	var width_end := inverse * (
		scroll_transform * Vector2(_chat_message_layout_width(), 0.0))
	var height_end := inverse * (
		scroll_transform * Vector2(0.0, _chat_viewport_height))
	_chat_background.position = origin
	_chat_background.size = Vector2(
		absf(width_end.x - origin.x), absf(height_end.y - origin.y))


func _align_chat_stack_to_row_bottom() -> void:
	var stack := chat_history_scroll.get_parent() as Control
	if not is_instance_valid(stack):
		return
	var row := stack.get_parent() as Control
	if not is_instance_valid(row):
		return
	stack.position.y = maxf(0.0, row.size.y - stack.size.y)


func _set_chat_open_state(open: bool) -> void:
	if not open:
		_cancel_jump_latest_notice()
	if ClientPerformance.enabled:
		ClientPerformance.mark("T chat_open=" + str(open))
	if _chat_open == open:
		return
	if not open:
		_saved_history_anchor = _capture_scroll_anchor()
		_saved_history_follow_latest = _follow_latest
	else:
		_pending_history_anchor = _saved_history_anchor.duplicate(true)
		_pending_history_follow_latest = _saved_history_follow_latest
		_follow_latest = _saved_history_follow_latest
	_history_prepare_generation += 1
	_chat_open = open
	chat_open_changed.emit(open)
	if is_instance_valid(_jump_latest_layer):
		_jump_latest_layer.visible = open
		_jump_latest_layer.mouse_behavior_recursive = (
			Control.MOUSE_BEHAVIOR_ENABLED if open
			else Control.MOUSE_BEHAVIOR_DISABLED)
	if not open:
		if is_instance_valid(_history_scroll_bar):
			_history_scroll_bar.visible = false
		if is_instance_valid(_jump_latest_button):
			_jump_latest_button.visible = false
		if is_instance_valid(_player_context_menu):
			_player_context_menu.dismiss_context_menu()
	if not open and is_instance_valid(chat_selection):
		chat_selection.call("deselect")
		chat_selection.call("cancel_drag")
	_schedule_history_layout()


func _refresh_chat_message_presentation(
		delta: float = 0.0, advance_fades: bool = false) -> void:
	if not is_instance_valid(chat_vbox):
		return

	var fades_changed := false
	if advance_fades:
		for index in range(_fade_tweens.size() - 1, -1, -1):
			var fade: FadeTween = _fade_tweens[index]
			if fade.mention_elapsed >= 0.0:
				fade.mention_elapsed += delta
				if fade.mention_elapsed >= 0.8:
					fade.mention_elapsed = -1.0
			var was_visible: bool = fade.t > 0.0
			if fade.countdown > 0.0:
				fade.countdown = maxf(0.0, fade.countdown - delta)
			else:
				fade.t = maxf(0.0, fade.t - chat_fade_rate * delta)
			fades_changed = fades_changed or was_visible != (fade.t > 0.0)
			if fade.countdown <= 0.0 and fade.t <= 0.0:
				break
	if fades_changed and not _chat_open:
		_schedule_history_layout()

	var messages := chat_vbox.get_children()
	for node in messages:
		var message := node as Control
		if not is_instance_valid(message):
			continue
		var message_alpha := 1.0 if _chat_open else 0.0
		var message_id := int(message.get_meta("chat_message_id", 0))
		var record_index := int(_record_index_by_id.get(message_id, -1))
		if not _chat_open and record_index >= 0 and record_index < _fade_tweens.size():
			message_alpha = _fade_tweens[record_index].t
		message_alpha = clampf(message_alpha, 0.0, 1.0)
		message.modulate.a = message_alpha
		message.visible = record_index >= 0 and (_chat_open or message_alpha > 0.0)
		var style := message.get_theme_stylebox("panel") as StyleBoxFlat
		if style != null:
			var base := Color.TRANSPARENT if _chat_open else (
				_CHAT_MESSAGE_STYLEBOX as StyleBoxFlat).bg_color
			var flash := 0.0
			if record_index >= 0 and record_index < _fade_tweens.size():
				flash = _mention_flash_strength(_fade_tweens[record_index].mention_elapsed)
			var flash_color := Color.TRANSPARENT.lerp(
				(_CHAT_TOGGLE_ON_STYLEBOX as StyleBoxFlat).bg_color, flash)
			var color := base.blend(flash_color)
			if style.bg_color != color:
				style.bg_color = color

	if is_instance_valid(chat_selection):
		var selection_should_show := _chat_open and not _message_records.is_empty()
		chat_selection.visible = selection_should_show

	if is_instance_valid(_chat_background):
		_chat_background.modulate.a = 1.0
		_chat_background.visible = _chat_open and not _message_layouts.is_empty()


func _mention_flash_strength(elapsed: float) -> float:
	if elapsed < 0.0 or elapsed >= 0.8:
		return 0.0
	var phase := fmod(elapsed, 0.4)
	return phase / 0.16 if phase < 0.16 else (0.4 - phase) / 0.24


func _bind_multiplayer_connection() -> void:
	_local_menu_theme_initialized = false
	# Connection lifetime is independent of whether its theme colors changed.
	if is_instance_valid(_theme_text_runtime):
		_theme_text_runtime.clear_caches()
	if is_instance_valid(_theme_tooltip_runtime):
		_theme_tooltip_runtime.configure(get_theme_source(), _theme_text_runtime)
	if is_instance_valid(_player_context_menu):
		_player_context_menu.set_multiplayer_connection(mp_connection)
	if not is_instance_valid(mp_connection):
		_reset_multiplayer_status_snapshot()
		_refresh_multiplayer_status_ui()
		_refresh_local_menu_theme()
		return
	for signal_name in MULTIPLAYER_SIGNAL_METHODS:
		var callback := Callable(self, MULTIPLAYER_SIGNAL_METHODS[signal_name])
		if not mp_connection.is_connected(signal_name, callback):
			mp_connection.connect(signal_name, callback)
	if is_instance_valid(_player_list_popup):
		_player_list_popup.set_multiplayer_connection(mp_connection)
	_privacy_desired = mp_connection.is_privacy_enabled()
	_privacy_authoritative = mp_connection.is_privacy_active()
	_privacy_transition_pending = mp_connection.is_privacy_transition_pending()
	_total_player_count = mp_connection.get_total_player_count()
	_room_player_count = mp_connection.get_room_player_count()
	var privacy_cooldown := mp_connection.privacy_cooldown_remaining()
	if privacy_cooldown > 0.0:
		privacy_mode_toggle.start_pending(privacy_cooldown)
	else:
		privacy_mode_toggle.clear_pending()
	var reconnect_cooldown := mp_connection.manual_reconnect_cooldown_remaining()
	if reconnect_cooldown > 0.0:
		reconnect_button.start_cooldown(reconnect_cooldown)
	else:
		reconnect_button.clear_cooldown()
	_refresh_local_menu_theme()
	_refresh_multiplayer_status_ui()


func _unbind_multiplayer_connection() -> void:
	if not is_instance_valid(mp_connection):
		return
	for signal_name in MULTIPLAYER_SIGNAL_METHODS:
		var callback := Callable(self, MULTIPLAYER_SIGNAL_METHODS[signal_name])
		if mp_connection.is_connected(signal_name, callback):
			mp_connection.disconnect(signal_name, callback)
	_pending_global_chat_text = ""
	_pending_room_chat_text = ""
	if is_instance_valid(_player_context_menu):
		_player_context_menu.set_multiplayer_connection(null)
	if is_instance_valid(_player_list_popup):
		_player_list_popup.set_multiplayer_connection(null)
		_player_list_popup.dismiss()
	if is_instance_valid(_nametag_style_popup):
		_nametag_style_popup.set_multiplayer_connection(null)
		_nametag_style_popup.dismiss()
	if is_node_ready():
		reconnect_button.clear_cooldown()
		privacy_mode_toggle.clear_pending()
		_reset_multiplayer_status_snapshot()
		_refresh_multiplayer_status_ui()


func _chat_cooldown_snapshot() -> Array[int]:
	if not is_instance_valid(mp_connection):
		return [0, 0]
	return mp_connection.chat_cooldown_snapshot(global_chat_toggle.button_pressed)


func _on_chat_readiness_changed(_ready: bool) -> void:
	_refresh_multiplayer_status_ui()
	global_chat_toggle.queue_redraw()


func _on_global_chat_cooldown_started(duration_seconds: float) -> void:
	global_chat_toggle.start_cooldown(duration_seconds)


func _on_global_chat_accepted(_duration_seconds: float) -> void:
	var accepted_text := _pending_global_chat_text
	var submission := _chat_submission()
	_pending_global_chat_text = ""
	# Do not erase a newer draft typed while the acknowledgement was in flight.
	if (not bool(chat_text_field.get("external_editing")) and not accepted_text.is_empty() and str(submission.text) == accepted_text
			and submission.mentions == _pending_global_chat_mentions
			and int(submission.revision) == _pending_global_chat_revision
			and global_chat_toggle.button_pressed):
		_reset_chat_draft()
		close_chat_input()


func _on_global_chat_rejected(remaining_seconds: float) -> void:
	_pending_global_chat_text = ""
	if remaining_seconds > 0.0:
		global_chat_toggle.start_cooldown(remaining_seconds)


func _on_room_chat_cooldown_started(_duration_seconds: float) -> void:
	global_chat_toggle.queue_redraw()


func _on_room_chat_accepted(_duration_seconds: float) -> void:
	var accepted_text := _pending_room_chat_text
	var submission := _chat_submission()
	_pending_room_chat_text = ""
	# Do not erase a newer draft typed while the acknowledgement was in flight.
	if (not bool(chat_text_field.get("external_editing")) and not accepted_text.is_empty() and str(submission.text) == accepted_text
			and submission.mentions == _pending_room_chat_mentions
			and int(submission.revision) == _pending_room_chat_revision
			and not global_chat_toggle.button_pressed):
		_reset_chat_draft()
		close_chat_input()


func _on_room_chat_rejected(remaining_seconds: float) -> void:
	_pending_room_chat_text = ""
	if remaining_seconds > 0.0:
		global_chat_toggle.queue_redraw()


func _on_multiplayer_connection_state_changed(state: int) -> void:
	if state != EasyMultiplayer.ConnectionState.CONNECTED:
		_pending_global_chat_text = ""
		_pending_room_chat_text = ""
		global_chat_toggle.clear_cooldown()
	_refresh_multiplayer_status_ui()


func _on_presence_changed(total_count: int, room_count: int, _room_id: int) -> void:
	_total_player_count = total_count
	_room_player_count = room_count
	_refresh_multiplayer_status_ui()


func _on_privacy_state_changed(
		desired_enabled: bool,
		authoritative_enabled: bool,
		transition_pending: bool) -> void:
	var desired_changed := _privacy_desired != desired_enabled
	_privacy_desired = desired_enabled
	_privacy_authoritative = authoritative_enabled
	_privacy_transition_pending = transition_pending
	_update_privacy_toggle_display()
	if desired_changed:
		privacy_mode_desired_changed.emit(_privacy_desired)
	_refresh_multiplayer_status_ui()


func _on_privacy_cooldown_started(duration_seconds: float) -> void:
	privacy_mode_toggle.start_pending(duration_seconds)
	_refresh_multiplayer_status_ui()


func _on_privacy_server_ready_changed(_ready: bool) -> void:
	_refresh_multiplayer_status_ui()


func _on_reconnect_cooldown_started(duration_seconds: float) -> void:
	reconnect_button.start_cooldown(duration_seconds)
	_refresh_multiplayer_status_ui()


func _on_reconnect_ready_changed(_ready: bool) -> void:
	_refresh_multiplayer_status_ui()


func _on_moderation_status_changed(_muted_until: int, _banned_until: int) -> void:
	_last_moderation_display_second = -1
	_refresh_multiplayer_status_ui()


func _refresh_local_menu_theme() -> void:
	var colors: Dictionary = {}
	var source := get_theme_source()
	if is_instance_valid(source):
		colors = source.get_current_menu_theme_colors()
	_on_local_menu_theme_changed(colors)


func _on_local_menu_theme_changed(colors: Dictionary) -> void:
	var normal: Color = colors.get("normal", Color.WHITE)
	var strong: Color = colors.get("strong", Color(1.0, 0.82, 0.28, 1.0))
	var muted: Color = colors.get("muted", Color(0.58, 0.58, 0.62, 1.0))
	var system_name := ""
	if is_instance_valid(get_theme_source()):
		var snapshot: Dictionary = get_theme_source().get_local_player_snapshot()
		if snapshot is Dictionary:
			system_name = str(snapshot.get("system_name", ""))
	var changed := (
		not _local_menu_theme_initialized
		or _local_menu_theme_system_name != system_name
		or not _ui_normal_color.is_equal_approx(normal)
		or not _ui_strong_color.is_equal_approx(strong)
		or not _ui_muted_color.is_equal_approx(muted)
	)
	_ui_normal_color = normal
	_ui_strong_color = strong
	_ui_muted_color = muted
	_local_menu_theme_system_name = system_name
	_local_menu_theme_initialized = true
	if not changed:
		return
	if is_instance_valid(_theme_text_runtime):
		_theme_text_runtime.clear_caches()
	if not is_instance_valid(_theme_tooltip_runtime):
		_theme_tooltip_runtime = _WEBPAGE_THEME_TOOLTIP_RUNTIME.new()
		add_child(_theme_tooltip_runtime)
	_theme_tooltip_runtime.configure(get_theme_source(), _theme_text_runtime)
	_apply_game_ui_text_rendering(self)
	_apply_game_ui_icon_rendering()
	if is_instance_valid(_player_context_menu):
		_player_context_menu.dismiss()
		_player_context_menu.set_theme_source(get_theme_source())
		_player_context_menu.set_ui_theme_colors(normal, strong, muted)
	if is_instance_valid(_player_list_popup):
		_player_list_popup.set_theme_source(get_theme_source())
		_player_list_popup.set_ui_theme_colors(normal, strong, muted)
	if is_instance_valid(_nametag_style_popup):
		_nametag_style_popup.set_theme_source(get_theme_source())
		_nametag_style_popup.set_multiplayer_connection(mp_connection)
	if is_node_ready():
		_refresh_current_location()
		_rerender_message_history()
		location_presentation_changed.emit()


func set_multiplayer_enabled_context(enabled: bool) -> void:
	_multiplayer_enabled_context = enabled
	if is_node_ready():
		_refresh_multiplayer_status_ui()


func set_nametag_engine(engine_node: Node) -> void:
	_nametag_engine = engine_node
	if is_instance_valid(_local_theme):
		_local_theme.set_engine(engine_node)
	_nametag_preview_textures.clear()
	if is_node_ready():
		_apply_nametag_mode()


func set_nametag_mode(mode: int, emit_change: bool = false) -> void:
	_nametag_mode = clampi(mode, 0, 3)
	if is_instance_valid(_nametag_style_popup):
		_nametag_style_popup.set_nametag_mode(_nametag_mode)
	_apply_nametag_mode()
	if emit_change:
		nametag_mode_changed.emit(_nametag_mode)


func _apply_nametag_mode() -> void:
	if (is_instance_valid(_nametag_engine)
			and _nametag_engine.has_method("is_running")
			and bool(_nametag_engine.call("is_running"))):
		_nametag_engine.call("mp_set_nametag_mode", _nametag_mode)
	_refresh_nametag_style_button()


func set_privacy_mode_desired(enabled: bool) -> void:
	_privacy_desired = enabled
	if is_node_ready():
		_update_privacy_toggle_display()
		_refresh_multiplayer_status_ui()


func _on_reconnect_pressed() -> void:
	if not _multiplayer_enabled_context or not is_instance_valid(mp_connection):
		return
	mp_connection.request_reconnect()
	_refresh_multiplayer_status_ui()


func _on_privacy_mode_toggled(enabled: bool) -> void:
	if not _multiplayer_enabled_context or not is_instance_valid(mp_connection):
		_update_privacy_toggle_display()
		return
	if not mp_connection.set_privacy_enabled(enabled):
		_privacy_desired = mp_connection.is_privacy_enabled()
		_update_privacy_toggle_display()
		_refresh_multiplayer_status_ui()
		return
	var desired_changed := _privacy_desired != mp_connection.is_privacy_enabled()
	_privacy_desired = mp_connection.is_privacy_enabled()
	_update_privacy_toggle_display()
	if desired_changed:
		privacy_mode_desired_changed.emit(_privacy_desired)
	_refresh_multiplayer_status_ui()


func _reset_multiplayer_status_snapshot() -> void:
	_privacy_authoritative = false
	_privacy_transition_pending = false
	_total_player_count = -1
	_room_player_count = -1


func _update_privacy_toggle_display() -> void:
	var banned := (
		is_instance_valid(mp_connection) and mp_connection.is_moderation_banned())
	privacy_mode_toggle.set_banned_mode_display(banned)
	if not banned:
		privacy_mode_toggle.set_private_mode_display(_privacy_desired)


func _refresh_multiplayer_status_ui() -> void:
	if not is_node_ready():
		return
	audio_mute_toggle.visible = _chat_open
	fullscreen_button.visible = _chat_open and %WindowModeController.desktop_controls_enabled()
	multiplayer_status_vbox.visible = _chat_open and _multiplayer_enabled_context
	_update_privacy_toggle_display()
	_refresh_privacy_mode_icon_style()
	server_player_count.text = "服务器总人数 %s" % _format_player_count(
		_total_player_count
	)
	world_player_count.text = "当前地图人数 %s" % _format_player_count(
		_room_player_count
	)
	if not _multiplayer_enabled_context:
		privacy_mode_toggle.visible = false
		nametag_style_button.visible = false
		if player_list_button.visible:
			player_list_button.visible = false
		privacy_mode_toggle.set_interaction_enabled(false)
		server_player_count_panel.visible = false
		world_player_count_panel.visible = false
		if is_instance_valid(_player_list_popup):
			_player_list_popup.dismiss()
		if is_instance_valid(_nametag_style_popup):
			_nametag_style_popup.dismiss()
		_refresh_chat_moderation_display()
		return

	reconnect_button.visible = true
	privacy_mode_toggle.visible = _chat_open
	nametag_style_button.visible = _chat_open
	var connection_state := EasyMultiplayer.ConnectionState.DISCONNECTED
	if is_instance_valid(mp_connection):
		connection_state = mp_connection.get_connection_state()
		_privacy_desired = mp_connection.is_privacy_enabled()
		_privacy_authoritative = mp_connection.is_privacy_active()
		_privacy_transition_pending = mp_connection.is_privacy_transition_pending()
		_update_privacy_toggle_display()

	var public_connected := false
	var banned := (
		is_instance_valid(mp_connection) and mp_connection.is_moderation_banned())
	match connection_state:
		EasyMultiplayer.ConnectionState.DISCONNECTED:
			_set_connection_status(_STATUS_DISCONNECTED_ICON, "未连接")
		EasyMultiplayer.ConnectionState.CONNECTING:
			_set_connection_status(_STATUS_CONNECTING_ICON, "连接中")
		EasyMultiplayer.ConnectionState.CONNECTED:
			if banned:
				var ban_time := (
					"永久" if mp_connection.is_moderation_ban_permanent()
					else _format_remaining_time(
						mp_connection.moderation_ban_remaining_seconds()))
				_set_connection_status(
					_STATUS_PRIVATE_ICON,
					"封禁中 %s" % ban_time)
			elif mp_connection.is_legacy_privacy_hold():
				_set_connection_status(_STATUS_PRIVATE_ICON, "服务器不支持隐身")
			elif _privacy_authoritative:
				_set_connection_status(_STATUS_PRIVATE_ICON, "隐身")
			elif _privacy_transition_pending or not mp_connection.is_room_ready():
				_set_connection_status(_STATUS_CONNECTING_ICON, "连接中")
			else:
				_set_connection_status(_STATUS_CONNECTED_ICON, "已连接")
				public_connected = true

	var reconnect_cooling := false
	var reconnect_available := false
	if is_instance_valid(mp_connection):
		reconnect_cooling = mp_connection.manual_reconnect_cooldown_remaining() > 0.0
		reconnect_available = mp_connection.can_request_reconnect()
	var reconnect_busy := (
		reconnect_cooling or
		(connection_state == EasyMultiplayer.ConnectionState.CONNECTING
			and not reconnect_available)
	)
	reconnect_button.disabled = reconnect_busy or not reconnect_available

	var privacy_interaction_enabled := false
	if (is_instance_valid(mp_connection)
			and connection_state == EasyMultiplayer.ConnectionState.CONNECTED):
		var supports_privacy := mp_connection.supports_privacy()
		privacy_interaction_enabled = (
			(not supports_privacy and _privacy_desired) or
			(supports_privacy and mp_connection.is_privacy_server_ready()
				and not mp_connection.is_privacy_transition_pending())
		)
	privacy_mode_toggle.set_interaction_enabled(
		privacy_interaction_enabled and not banned)
	server_player_count_panel.visible = public_connected
	world_player_count_panel.visible = public_connected
	var player_list_should_show := (
		_chat_open and public_connected and is_instance_valid(mp_connection)
		and mp_connection.supports_player_list()
	)
	if player_list_button.visible != player_list_should_show:
		player_list_button.visible = player_list_should_show
	if not public_connected and is_instance_valid(_player_list_popup):
		_player_list_popup.dismiss()
	_refresh_chat_moderation_display()


func _set_connection_status(status_icon: Texture2D, status_text: String) -> void:
	connection_status_icon.texture = status_icon
	connection_status_icon.set_meta("webpage_theme_icon_size", 16.0)
	connection_status_text.text = status_text
	if not is_instance_valid(_theme_text_runtime):
		return
	_theme_text_runtime.clear_icon_style(connection_status_icon)


func _format_player_count(count: int) -> String:
	return str(count) if count >= 0 else "—"


func _format_remaining_time(total_seconds: int) -> String:
	var remaining := maxi(0, total_seconds)
	var days := int(remaining / 86400)
	var hours := int((remaining % 86400) / 3600)
	var minutes := int((remaining % 3600) / 60)
	var seconds := remaining % 60
	if days > 0:
		return "%d天 %02d:%02d:%02d" % [days, hours, minutes, seconds]
	if hours > 0:
		return "%02d:%02d:%02d" % [hours, minutes, seconds]
	return "%02d:%02d" % [minutes, seconds]


func _refresh_chat_moderation_display() -> void:
	var muted := (
		is_instance_valid(mp_connection) and mp_connection.is_moderation_muted())
	chat_text_field.editable = not muted
	global_chat_toggle.disabled = muted
	if muted:
		if not chat_text_field.text.is_empty():
			_reset_chat_draft()
		var mute_time := (
			"永久" if mp_connection.is_moderation_mute_permanent()
			else _format_remaining_time(
				mp_connection.moderation_mute_remaining_seconds()))
		chat_text_field.placeholder_text = "禁言中 %s" % mute_time
		chat_text_field.alignment = HORIZONTAL_ALIGNMENT_CENTER
	else:
		chat_text_field.placeholder_text = "触摸点击以开始输入" if touch_chat else ""
		chat_text_field.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_refresh_touch_chat_placeholder()


func set_location_runtime(runtime: Node) -> void:
	if _location_runtime == runtime:
		if is_node_ready():
			_refresh_current_location()
			_rerender_message_history()
		return
	_unbind_location_runtime()
	_location_runtime = runtime
	if not is_node_ready():
		return
	_bind_location_runtime()
	_refresh_current_location()
	_rerender_message_history()


func _bind_location_runtime() -> void:
	if not is_instance_valid(_location_runtime):
		_set_display_language("en")
		return
	_set_display_language(str(_location_runtime.call("get_language_code")) if _location_runtime.has_method("get_language_code") else "en")
	var current_location_callback := Callable(self, "_on_current_location_changed")
	if (
		_location_runtime.has_signal("current_location_changed") and
		not _location_runtime.is_connected("current_location_changed", current_location_callback)
	):
		_location_runtime.connect("current_location_changed", current_location_callback)
	var language_callback := Callable(self, "_on_location_language_changed")
	if (
		_location_runtime.has_signal("language_changed") and
		not _location_runtime.is_connected("language_changed", language_callback)
	):
		_location_runtime.connect("language_changed", language_callback)


func _unbind_location_runtime() -> void:
	if not is_instance_valid(_location_runtime):
		return
	var current_location_callback := Callable(self, "_on_current_location_changed")
	if (
		_location_runtime.has_signal("current_location_changed") and
		_location_runtime.is_connected("current_location_changed", current_location_callback)
	):
		_location_runtime.disconnect("current_location_changed", current_location_callback)
	var language_callback := Callable(self, "_on_location_language_changed")
	if (
		_location_runtime.has_signal("language_changed") and
		_location_runtime.is_connected("language_changed", language_callback)
	):
		_location_runtime.disconnect("language_changed", language_callback)


func _input(event: InputEvent) -> void:
	# Retire keys already claimed by this shortcut even if Ctrl was released
	# first or a modal/editor took focus after the initial press.
	var key := event as InputEventKey
	if key != null:
		var source := _KEYBOARD_MAPPING.event_source(key)
		if _chat_toggle_sources.has(source):
			if not key.pressed or key.echo:
				get_viewport().set_input_as_handled()
				if not key.pressed:
					_chat_toggle_sources.erase(source)
				return
			_chat_toggle_sources.erase(source)
	if touch_chat and touch_input_available.is_valid() and not touch_input_available.call():
		return
	if key != null and key.is_action_pressed("game_chat_toggle", false, true):
		if not _chat_toggle_editing_active():
			_chat_toggle_sources[_KEYBOARD_MAPPING.event_source(key)] = true
			_set_chat_enabled(not chat_enabled)
			get_viewport().set_input_as_handled()
		return
	if not chat_enabled:
		return
	if _chat_open and _is_empty_chat_enter(event):
		_reset_chat_draft()
		close_chat_input()
		get_viewport().set_input_as_handled()
		return
	if not _chat_open:
		return
	if event.is_action_pressed("game_chat_release"):
		close_chat_input()
		get_viewport().set_input_as_handled()
	elif (
		event.is_action_pressed("game_chat_focus") and
		not chat_text_field.has_focus()
	):
		# Clicking/selecting chat history moves focus away from the LineEdit.
		# Pressing T again should return focus to the existing open draft, not
		# propagate into the running RPG as a text key.
		if touch_chat:
			native_focus_requested.emit()
		else:
			chat_text_field.grab_focus()
		get_viewport().set_input_as_handled()


func _chat_toggle_editing_active() -> bool:
	if LimboConsole.is_open() or bool(chat_text_field.get("external_editing")) \
			or chat_text_field.has_ime_text():
		return true
	var focus := get_viewport().gui_get_focus_owner()
	if _is_active_text_editor(focus):
		return true
	# Launcher fields live in a separate viewport, whose GUI focus does not
	# appear in the root viewport. Inspect it only for a candidate shortcut.
	for container: SubViewportContainer in get_tree().root.find_children("*", "SubViewportContainer", true, false):
		if not container.is_visible_in_tree():
			continue
		for child in container.get_children():
			if child is Viewport and _is_active_text_editor(child.gui_get_focus_owner()):
				return true
	return false


func _is_active_text_editor(control: Control) -> bool:
	return control != null and control.is_visible_in_tree() and (
		(control is LineEdit and control.editable)
		or (control is TextEdit and control.editable))


func _is_empty_chat_enter(event: InputEvent) -> bool:
	var key_event := event as InputEventKey
	if key_event == null or not key_event.pressed or key_event.echo:
		return false
	if key_event.keycode != KEY_ENTER and key_event.keycode != KEY_KP_ENTER:
		return false
	return not bool(chat_text_field.get("external_editing")) and not chat_text_field.has_ime_text() and chat_text_field.text.strip_edges().is_empty()


func _unhandled_input(event: InputEvent) -> void:
	if touch_chat and touch_input_available.is_valid() and not touch_input_available.call():
		return
	if not chat_enabled:
		return
	if event.is_action_pressed("game_chat_focus"):
		chat_input_row.set_visible(true)
		if not touch_chat:
			chat_text_field.grab_focus()
		_set_chat_open_state(true)
		_set_chat_interaction_enabled(true)
		_update_current_location_visibility()
		_refresh_multiplayer_status_ui()
		if touch_chat:
			native_focus_requested.emit()
			get_viewport().set_input_as_handled()
		return


func _set_chat_enabled(enabled: bool) -> void:
	if not enabled:
		_cancel_jump_latest_notice()
	if ClientPerformance.enabled:
		# Keep the existing capture marker understood by performance reports.
		ClientPerformance.mark("H chat_enabled=" + str(enabled))
	if chat_enabled != enabled:
		_invalidate_chat_callbacks()
		if enabled:
			_restore_started_usec = ClientPerformance.begin()
			_restore_first_visible = false
	chat_enabled = enabled
	if not enabled:
		chat_vbox.visible = false
	chat_overlay_layer.visible = enabled
	visible = enabled
	mouse_behavior_recursive = (
		Control.MOUSE_BEHAVIOR_ENABLED if enabled
		else Control.MOUSE_BEHAVIOR_DISABLED
	)
	_set_chat_interaction_enabled(enabled and _chat_open)
	if enabled:
		_last_moderation_display_second = -1
		_refresh_local_menu_theme()
		_refresh_multiplayer_status_ui()
		_schedule_history_layout()
		return
	chat_selection.mouse_default_cursor_shape = Control.CURSOR_ARROW
	if is_instance_valid(_player_context_menu):
		_player_context_menu.dismiss()
	if is_instance_valid(_player_list_popup):
		_player_list_popup.dismiss()
	close_chat_input()


func _set_chat_interaction_enabled(enabled: bool) -> void:
	var interaction_filter := (
		Control.MOUSE_FILTER_STOP if enabled else Control.MOUSE_FILTER_IGNORE
	)
	var recursive_behavior := (
		Control.MOUSE_BEHAVIOR_ENABLED if enabled
		else Control.MOUSE_BEHAVIOR_DISABLED
	)
	for label in [chat_selection, current_location_localized, current_location_english]:
		if not is_instance_valid(label):
			continue
		label.mouse_filter = (
			Control.MOUSE_FILTER_PASS
			if enabled and label == chat_selection
			else interaction_filter)
		label.mouse_behavior_recursive = recursive_behavior
	chat_selection.focus_mode = Control.FOCUS_CLICK if enabled else Control.FOCUS_NONE
	if is_instance_valid(chat_history_scroll):
		chat_history_scroll.mouse_filter = interaction_filter
		chat_history_scroll.mouse_behavior_recursive = recursive_behavior
	if is_instance_valid(_history_scroll_bar):
		_history_scroll_bar.mouse_filter = interaction_filter
		_history_scroll_bar.mouse_behavior_recursive = recursive_behavior


func _apply_game_ui_text_rendering(
		root: Node, system_name: String = "", final_role: int = -1) -> void:
	var perf_start := ClientPerformance.begin() if final_role >= 0 else 0
	if root is Control:
		var control := root as Control
		if is_instance_valid(chat_selection) and control == chat_selection:
			return
		if final_role >= 0:
			control.begin_bulk_theme_override()
		var needs_nearest: bool = (
			control is Label
			or control is RichTextLabel
			or control is LineEdit
		)
		if control is Button:
			var button := control as Button
			needs_nearest = not button.text.is_empty() and button.icon == null
			if is_instance_valid(_theme_text_runtime):
				_theme_text_runtime.style_button(button)
		if needs_nearest:
			control.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		control.add_theme_font_override("font", _GAME_UI_FONT)
		control.add_theme_font_override("normal_font", _GAME_UI_FONT)
		control.add_theme_color_override("font_color", _ui_normal_color)
		control.add_theme_color_override("font_hover_color", _ui_normal_color)
		control.add_theme_color_override("font_pressed_color", _ui_normal_color)
		control.add_theme_color_override("font_focus_color", _ui_normal_color)
		control.add_theme_color_override("font_selected_color", _ui_normal_color)
		control.add_theme_color_override("font_disabled_color", _ui_muted_color)
		control.add_theme_color_override("font_placeholder_color", _ui_muted_color)
		control.add_theme_color_override("font_uneditable_color", _ui_muted_color)
		if control is RichTextLabel:
			control.add_theme_color_override("default_color", _ui_normal_color)
		control.add_theme_color_override(
			"font_shadow_color", _GAME_UI_SHADOW_COLOR)
		control.add_theme_color_override("font_outline_color", Color.TRANSPARENT)
		control.add_theme_constant_override("shadow_offset_x", 1)
		control.add_theme_constant_override("shadow_offset_y", 1)
		control.add_theme_constant_override("shadow_outline_size", 0)
		control.add_theme_constant_override("outline_size", 0)
		if is_instance_valid(_theme_text_runtime):
			var role := int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_NORMAL)
			if control == chat_text_field and global_chat_toggle.button_pressed:
				role = int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG)
			if final_role >= 0:
				role = final_role
				# Preserve the former local-pass fallback colors for a missing
				# remote System, without allocating its temporary shader material.
				if (not system_name.is_empty()
						and _theme_text_runtime.get_theme_data(get_theme_source(), system_name).is_empty()
						and not _theme_text_runtime.get_theme_data(get_theme_source(), "").is_empty()):
					_theme_text_runtime._apply_colors(control,
						_WEBPAGE_THEME_TEXT_RUNTIME.NORMAL_MARKER,
						_WEBPAGE_THEME_TEXT_RUNTIME.MUTED_MARKER,
						_WEBPAGE_THEME_TEXT_RUNTIME.SHADOW_MARKER)
			_theme_text_runtime.style_control(
				control, get_theme_source(), system_name, role)
		if final_role >= 0:
			UiScale.declare_control_overrides(control,
				PackedStringArray(["shadow_offset_x", "shadow_offset_y", "shadow_outline_size", "outline_size"]),
				PackedStringArray(["normal", "focus"]) if control is RichTextLabel else PackedStringArray())
			control.end_bulk_theme_override()
			ClientPerformance.count_event(&"chat.text_controls_created")
		if control == chat_text_field:
			_restore_native_chat_field_rendering()
	for child in root.get_children():
		_apply_game_ui_text_rendering(child)
	if final_role >= 0:
		ClientPerformance.end(&"chat.text_initialize", perf_start)


func _apply_game_ui_icon_rendering() -> void:
	if not is_instance_valid(_theme_text_runtime):
		return
	_refresh_player_list_button_style()
	_theme_text_runtime.style_icon(
		reconnect_button, get_theme_source(), "",
		int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_NORMAL), true, 14.0)
	_refresh_privacy_mode_icon_style()
	_refresh_nametag_style_button()
	_update_global_chat_toggle_icon()
	_refresh_audio_mute_style()
	_theme_text_runtime.style_icon(
		fullscreen_button, get_theme_source(), "", int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_NORMAL), true, 20.0)


func _refresh_player_list_button_style() -> void:
	if not is_instance_valid(_theme_text_runtime):
		return
	var active: bool = is_instance_valid(_player_list_popup) and _player_list_popup.visible
	_theme_text_runtime.style_icon(
		player_list_button, get_theme_source(), "",
		int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG) if active
		else int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_NORMAL),
		false, 20.0)


func _on_fullscreen_pressed() -> void:
	%WindowModeController.toggle_fullscreen()


func _refresh_privacy_mode_icon_style() -> void:
	if not is_instance_valid(_theme_text_runtime):
		return
	_theme_text_runtime.style_icon(
		privacy_mode_toggle, get_theme_source(), "",
		int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG)
		if privacy_mode_toggle.button_pressed
		else int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_NORMAL),
		false, 20.0)


func set_audio_muted(enabled: bool) -> void:
	_audio_muted = enabled
	if is_instance_valid(audio_mute_toggle):
		_refresh_audio_mute_style()


func _on_audio_mute_toggled(enabled: bool) -> void:
	_audio_muted = enabled
	_refresh_audio_mute_style()
	audio_muted_changed.emit(enabled)


func _refresh_audio_mute_style() -> void:
	var muted := _audio_muted
	audio_mute_toggle.set_pressed_no_signal(muted)
	audio_mute_toggle.icon = _AUDIO_MUTED_ICON if muted else _AUDIO_ENABLED_ICON
	WebpageThemeTooltipRuntime.set_control_tooltip(
		audio_mute_toggle, "取消静音" if muted else "静音")
	if not is_instance_valid(_theme_text_runtime):
		return
	var role := int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG if muted
		else _WEBPAGE_THEME_TEXT_RUNTIME.ROLE_NORMAL)
	if not _theme_text_runtime.style_icon(
			audio_mute_toggle, get_theme_source(), "", role, false, 20.0):
		var color := _ui_strong_color if muted else _ui_normal_color
		for color_name in ["icon_normal_color", "icon_hover_color", "icon_pressed_color",
				"icon_hover_pressed_color", "icon_focus_color", "icon_disabled_color"]:
			audio_mute_toggle.add_theme_color_override(color_name, color)


func _refresh_nametag_style_button() -> void:
	if not is_instance_valid(nametag_style_button):
		return
	WebpageThemeTooltipRuntime.set_control_tooltip(
		nametag_style_button, "头顶昵称样式")
	_ensure_nametag_preview_control()
	if (is_instance_valid(_nametag_engine)
			and _nametag_engine.has_method("is_running")
			and bool(_nametag_engine.call("is_running"))):
		_load_nametag_preview_textures()
	var preview: Texture2D = null
	if _nametag_mode >= 0 and _nametag_mode < _nametag_preview_textures.size():
		preview = _nametag_preview_textures[_nametag_mode] as Texture2D
	_nametag_preview_rect.texture = preview
	_nametag_preview_rect.visible = preview != null
	_layout_nametag_preview()
	if is_instance_valid(_theme_text_runtime) and preview != null:
		var active := (is_instance_valid(_nametag_style_popup)
			and _nametag_style_popup.visible)
		_theme_text_runtime.style_pixel_texture(
			_nametag_preview_rect, get_theme_source(), "",
			int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG)
			if active else int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_NORMAL),
			true)


func _ensure_nametag_preview_control() -> void:
	if is_instance_valid(_nametag_preview_rect):
		return
	nametag_style_button.icon = null
	_nametag_preview_rect = TextureRect.new()
	_nametag_preview_rect.name = "NametagModePreview"
	_nametag_preview_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_nametag_preview_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_nametag_preview_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_nametag_preview_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	nametag_style_button.add_child(_nametag_preview_rect)
	nametag_style_button.resized.connect(_layout_nametag_preview)


func _load_nametag_preview_textures() -> void:
	if _nametag_preview_textures.size() == 4:
		return
	_nametag_preview_textures.resize(4)
	for mode in 4:
		_nametag_preview_textures[mode] = _nametag_engine.call(
			"mp_render_nametag_mode_preview", mode) as Texture2D


func _nametag_preview_size(texture: Texture2D) -> Vector2:
	if texture == null:
		return Vector2.ZERO
	var source_size := texture.get_size()
	if source_size.x <= 0.0 or source_size.y <= 0.0:
		return Vector2.ZERO
	var target_height := UiScale.physical_value(20.0)
	var target_width := target_height * source_size.x / source_size.y
	var maximum_width := UiScale.physical_value(64.0)
	if target_width > maximum_width:
		target_height *= maximum_width / target_width
		target_width = maximum_width
	return Vector2(maxf(1.0, roundf(target_width)), maxf(1.0, roundf(target_height)))


func _layout_nametag_preview() -> void:
	if not is_instance_valid(_nametag_preview_rect):
		return
	var reserved_width := 0.0
	for texture_value in _nametag_preview_textures:
		reserved_width = maxf(
			reserved_width,
			_nametag_preview_size(texture_value as Texture2D).x)
	nametag_style_button.custom_minimum_size = Vector2(
		maxf(UiScale.physical_value(32.0), reserved_width + UiScale.physical_value(8.0)),
		UiScale.physical_value(32.0))
	var preview_size := _nametag_preview_size(_nametag_preview_rect.texture)
	_nametag_preview_rect.size = preview_size
	_nametag_preview_rect.position = (
		nametag_style_button.size - preview_size) * 0.5


func _on_chat_field_focus_entered() -> void:
	chat_text_field_frame.add_theme_stylebox_override("panel", _CHAT_FIELD_FOCUS_STYLE)


func _on_chat_field_focus_exited() -> void:
	chat_text_field_frame.add_theme_stylebox_override("panel", _CHAT_FIELD_NORMAL_STYLE)


func _physics_process(delta: float) -> void:
	var viewport_size := get_viewport().get_visible_rect().size
	if viewport_size != _chat_background_viewport_size:
		_chat_background_viewport_size = viewport_size
		_chat_background_resize_sync_frames = 3
	if _chat_background_resize_sync_frames > 0:
		_queue_chat_background_geometry_sync()
		_chat_background_resize_sync_frames -= 1
	if not chat_enabled:
		return
	_refresh_context_menu_skins()
	var display_second := int(Time.get_ticks_msec() / 1000)
	if display_second != _last_moderation_display_second:
		_last_moderation_display_second = display_second
		_refresh_multiplayer_status_ui()
	_refresh_chat_message_presentation(delta, true)

func _delete_old_messages() -> void:
	var deleted_message := false
	while _message_records.size() > chat_history_limit:
		_message_records.pop_front()
		if not _fade_tweens.is_empty():
			_fade_tweens.pop_front()
		deleted_message = true
	if deleted_message:
		# This is a model index, not a rendered-layout index. Fades/mentions may
		# run while a multi-frame preparation still holds the previous geometry.
		_record_index_by_id.clear()
		for index in _message_records.size():
			_record_index_by_id[int(_message_records[index].message_id)] = index
		_selection_history_dirty = true
		chat_selection.call("begin_layout_update")
	_schedule_history_layout()


func _schedule_history_layout() -> void:
	if not is_node_ready():
		return
	if _chat_open and _layout_is_history and _pending_history_anchor.is_empty():
		_pending_history_anchor = _capture_scroll_anchor()
		_pending_history_follow_latest = _follow_latest
	_history_layout_serial += 1
	_history_layout_dirty = true
	ClientPerformance.count_event(&"chat.layout_requests")
	if not chat_enabled:
		return
	if _history_layout_queued:
		return
	_history_layout_queued = true
	call_deferred("_perform_history_layout", _chat_lifecycle)


func _perform_history_layout(lifecycle: int) -> void:
	if lifecycle != _chat_lifecycle:
		return
	if not chat_enabled or not is_node_ready():
		_history_layout_queued = false
		return
	if _last_history_layout_frame == Engine.get_process_frames():
		_resume_history_layout(lifecycle)
		return
	if not _history_layout_dirty:
		_history_layout_queued = false
		return
	_last_history_layout_frame = Engine.get_process_frames()
	_prepare_history_layout(lifecycle)


func _prepare_history_layout(lifecycle: int) -> void:
	# Appends do not cancel this job. IDs survive eviction while we yield; a
	# changed width/theme/mode cancels preparation, never commits stale geometry.
	var generation := _history_prepare_generation
	var requested_serial := _history_layout_serial
	var width := _chat_message_layout_width()
	var history: bool = _chat_open
	var records: Array[Dictionary] = []
	for index in _presented_record_indices():
		records.append(_message_records[index])
	if not history:
		records.reverse() # Closed chat needs only the visible tail, not 250 records.
	var ids: Array[int] = []
	var height := 0.0
	var needed_height := _chat_history_maximum_height() + _chat_line_height() * _CHAT_OVERSCAN_LINE_LIMIT
	var slice_start := Time.get_ticks_usec()
	for record in records:
		var metrics := _record_visual_metrics(record, width)
		ids.append(int(record.message_id))
		height += float(metrics.get("height", _chat_line_height()))
		if not history and height >= needed_height:
			break
		if Time.get_ticks_usec() - slice_start >= _CHAT_PREPARE_BUDGET_USEC:
			_record_prepare_slice(slice_start)
			await get_tree().process_frame
			if lifecycle != _chat_lifecycle:
				return
			if (not chat_enabled or generation != _history_prepare_generation
					or history != _chat_open or not is_equal_approx(width, _chat_message_layout_width())):
				_history_layout_queued = false
				_schedule_history_layout()
				return
			slice_start = Time.get_ticks_usec()
	_record_prepare_slice(slice_start)
	if not history:
		ids.reverse()
	var current: Dictionary = {}
	for index in _message_records.size():
		current[int(_message_records[index].message_id)] = index
	var indices: Array[int] = []
	for id in ids:
		if current.has(id):
			var index: int = current[id]
			if history or (index < _fade_tweens.size() and _fade_tweens[index].t > 0.0):
				indices.append(index)
	_history_layout_dirty = requested_serial != _history_layout_serial
	_history_layout_queued = false
	var perf_start := ClientPerformance.begin()
	_perform_history_layout_measured(requested_serial, indices)
	ClientPerformance.end(&"chat.layout_inclusive", perf_start)
	if _history_layout_dirty:
		_schedule_history_layout()


func _record_prepare_slice(start: int) -> void:
	if not ClientPerformance.enabled:
		return
	var elapsed := Time.get_ticks_usec() - start
	ClientPerformance.record(&"chat.prepare", elapsed)
	# Preserve the inclusive total across preparation slices; never count await time.
	ClientPerformance.record(&"chat.layout_inclusive", elapsed)
	ClientPerformance.gauge(&"chat.prepare_slice_us", elapsed)
	if elapsed > _CHAT_PREPARE_BUDGET_USEC:
		ClientPerformance.count_event(&"chat.prepare_budget_overruns")


func _resume_history_layout(lifecycle: int) -> void:
	await get_tree().process_frame
	if lifecycle != _chat_lifecycle:
		return
	_history_layout_queued = false
	_schedule_history_layout()


func _invalidate_chat_callbacks() -> void:
	_cancel_jump_latest_notice()
	# A resize already queued for the old lifetime still invalidates cached paint.
	if _message_reflow_pending or _force_history_render:
		_chat_paint_revision += 1
		for record in _message_records:
			record.erase("_metrics_key")
			record.erase("_metrics")
	_force_history_render = false
	_chat_lifecycle += 1
	_history_prepare_generation += 1
	_virtual_render_waiting = false
	_restore_started_usec = 0
	_restore_first_visible = false
	_history_layout_queued = false
	_history_geometry_commit_queued = false
	_chat_selection_commit_queued = false
	_history_render_queued = false
	_message_reflow_pending = false
	_history_layout_dirty = true


func _perform_history_layout_measured(_requested_serial: int, indices: Array[int]) -> void:
	_history_layout_queued = false
	if not is_node_ready():
		return
	chat_selection.call("begin_layout_update")
	var anchor := _pending_history_anchor.duplicate(true)
	var restore_follow := _pending_history_follow_latest
	_pending_history_anchor.clear()
	var full_width := _chat_message_layout_width()
	var maximum_height := _chat_history_maximum_height()
	var layouts := _build_message_layouts(indices, full_width)
	var total_height := _layouts_total_height(layouts)
	if _chat_open:
		_history_overflow = total_height > maximum_height + 0.5
	_layout_is_history = _chat_open
	_chat_render_width = full_width
	_message_layouts = layouts
	_chat_viewport_height = minf(total_height, maximum_height)
	var stack := chat_history_scroll.get_parent() as Control
	_set_physical_minimum_width(stack, full_width)
	stack.custom_minimum_size.y = _chat_viewport_height
	stack.size = Vector2(full_width, _chat_viewport_height)
	stack.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	stack.clip_contents = false
	chat_history_scroll.custom_minimum_size = Vector2(full_width, _chat_viewport_height)
	chat_history_scroll.size = Vector2(full_width, _chat_viewport_height)
	chat_virtual_content.custom_minimum_size = Vector2(
		_chat_render_width, _chat_viewport_height)
	chat_virtual_content.size = Vector2(
		_chat_render_width, maxf(total_height, _chat_viewport_height))
	chat_selection.custom_minimum_size = Vector2(
		_chat_render_width, _chat_viewport_height)
	chat_selection.size = chat_virtual_content.size
	chat_selection.position = Vector2.ZERO
	chat_selection.call("set_auto_scroll_line_height", _chat_line_height())
	chat_history_scroll.update_minimum_size()
	stack.update_minimum_size()
	var layout_parent := stack.get_parent()
	while layout_parent is Container:
		(layout_parent as Container).update_minimum_size()
		(layout_parent as Container).queue_sort()
		layout_parent = layout_parent.get_parent()
	stack.queue_redraw()
	_apply_history_scroll_state(anchor, restore_follow, total_height)
	_update_current_location_width()
	_render_virtual_window()
	_update_jump_latest_geometry()
	_update_jump_latest_visibility()
	_queue_chat_background_geometry_sync()
	if not _history_geometry_commit_queued:
		_history_geometry_commit_queued = true
		call_deferred("_finish_history_layout", _chat_lifecycle)


func _finish_history_layout(lifecycle: int) -> void:
	await get_tree().process_frame
	if lifecycle != _chat_lifecycle:
		return
	_history_geometry_commit_queued = false
	if not is_node_ready() or not chat_enabled:
		return
	var perf_start := ClientPerformance.begin()
	_align_chat_stack_to_row_bottom()
	_update_jump_latest_geometry()
	_update_jump_latest_visibility()
	ClientPerformance.end(&"chat.geometry_commit", perf_start)
	_update_current_location_width()
	_consume_jump_latest_notice(true)


func _apply_history_scroll_state(
		anchor: Dictionary, restore_follow: bool, total_height: float) -> void:
	var scroll_bar := _history_scroll_bar
	if not _chat_open:
		_transient_scroll_offset = maxf(0.0, total_height - _chat_viewport_height)
		scroll_bar.visible = false
		_apply_virtual_scroll_position()
		return
	_suppress_scroll_state = true
	scroll_bar.max_value = maxf(total_height, _chat_viewport_height)
	scroll_bar.page = _chat_viewport_height
	scroll_bar.visible = _history_overflow
	if restore_follow:
		scroll_bar.value = maxf(
			0.0, total_height - _chat_viewport_height)
		_follow_latest = true
	else:
		_restore_scroll_anchor(anchor)
		_follow_latest = _is_chat_at_bottom()
	_saved_history_follow_latest = _follow_latest
	_suppress_scroll_state = false
	_apply_virtual_scroll_position()


func _presented_record_indices() -> Array[int]:
	var indices: Array[int] = []
	if _chat_open:
		for index in _message_records.size():
			indices.append(index)
		return indices
	for index in _message_records.size():
		if index < _fade_tweens.size() and _fade_tweens[index].t > 0.0:
			indices.append(index)
	return indices


func _build_message_layouts(indices: Array[int], width: float) -> Array[Dictionary]:
	var layouts: Array[Dictionary] = []
	var y := 0.0
	for record_index in indices:
		if record_index < 0 or record_index >= _message_records.size():
			continue
		var record := _message_records[record_index]
		var metrics := _record_visual_metrics(record, width)
		var line_count := int(metrics.get("line_count", 1))
		var height := maxf(1.0, float(metrics.get("height", _chat_line_height())))
		layouts.append({
			"message_id": int(record.get("message_id", 0)),
			"record_index": record_index,
			"y": y,
			"height": height,
			"line_count": line_count,
			"line_height": _chat_line_height(),
			"render_width": width,
			"metrics": metrics,
		})
		y += height
	return layouts


func _layouts_total_height(layouts: Array[Dictionary]) -> float:
	if layouts.is_empty():
		return 0.0
	var last: Dictionary = layouts.back()
	return float(last.get("y", 0.0)) + float(last.get("height", 0.0))


func _record_visual_metrics(record: Dictionary, width: float) -> Dictionary:
	var admin := bool(record.get("sender_is_admin", false))
	var key := Vector3(width, _chat_font_size(), 1.0 if admin else 0.0)
	if record.get("_metrics_key", Vector3(-1, -1, -1)) == key:
		ClientPerformance.count_event(&"chat.measure_cache_hits")
		return record["_metrics"]
	var perf_start := ClientPerformance.begin()
	var metrics := _measure_record_visual_metrics(record, width)
	record["_metrics_key"] = key
	record["_metrics"] = metrics
	ClientPerformance.count_event(&"chat.records_measured")
	ClientPerformance.end(&"chat.measure", perf_start)
	return metrics


func _measure_record_visual_metrics(record: Dictionary, width: float) -> Dictionary:
	var available_width := _chat_message_content_width_for_width(width)
	var line_height := _chat_line_height()
	var player_width := _visual_text_width(PlayerName.display(str(record.get("display_name", "")), _display_language, true))
	var timestamp := str(record.get("timestamp", ""))
	if bool(record.get("sender_is_admin", false)):
		player_width += UiScale.physical_value(16.0)
	if str(record.get("kind", "room")) != "global":
		var prefix_width := player_width + _visual_text_width(" ")
		var room_lines := _wrap_message_lines(
			_record_body_text(record), available_width, available_width)
		var timestamp_new_line := (
			not timestamp.is_empty()
			and prefix_width + _visual_text_width(timestamp) > available_width + 0.01)
		var header_count := 2 if timestamp_new_line else 1
		var room_line_count := header_count + room_lines.size()
		return {
			"line_count": room_line_count,
			"height": room_line_count * line_height,
			"room_lines": room_lines,
			"timestamp_new_line": timestamp_new_line,
		}
	var header_segments := _global_prefix_segments(record)
	var header_text := _visual_segments_text(header_segments)
	var header_prefix_width := UiScale.physical_value(16.0) + player_width
	var header_lines := _wrap_message_lines(
		header_text, available_width - header_prefix_width, available_width)
	var body_lines := _wrap_message_lines(
		_record_body_text(record), available_width, available_width)
	var header_count := maxi(1, header_lines.size())
	var timestamp_new_line := _timestamp_requires_new_line(
		header_lines, header_prefix_width, available_width, timestamp)
	if timestamp_new_line:
		header_count += 1
	var body_count := body_lines.size()
	return {
		"line_count": header_count + body_count,
		"height": (header_count + body_count) * line_height,
		"header_segments": header_segments,
		"header_lines": header_lines,
		"body_lines": body_lines,
		"timestamp_new_line": timestamp_new_line,
	}


func _timestamp_requires_new_line(
		lines: Array, first_prefix_width: float,
		available_width: float, timestamp: String) -> bool:
	if timestamp.is_empty():
		return false
	var last_index := maxi(0, lines.size() - 1)
	var used_width := first_prefix_width if last_index == 0 else 0.0
	if not lines.is_empty():
		used_width += _visual_text_width(str(lines[last_index]))
	return used_width + _visual_text_width(timestamp) > available_width + 0.01


func _timestamp_slot_width(
		lines: Array, first_prefix_width: float,
		available_width: float, timestamp: String) -> float:
	var last_index := maxi(0, lines.size() - 1)
	var used_width := first_prefix_width if last_index == 0 else 0.0
	if not lines.is_empty():
		used_width += _visual_text_width(str(lines[last_index]))
	return maxf(_visual_text_width(timestamp), available_width - used_width)


func _record_visual_line_count(record: Dictionary, width: float) -> int:
	return int(_record_visual_metrics(record, width).get("line_count", 1))


func _record_selection_text(record: Dictionary) -> String:
	var result := PlayerName.display(str(record.get("display_name", "")), _display_language, true)
	record["selection_name_length"] = result.length()
	record["selection_source_name_length"] = PlayerName.display(str(record.get("display_name", "")), "en", true).length()
	var timestamp := str(record.get("timestamp", ""))
	if str(record.get("kind", "room")) != "global":
		if not timestamp.is_empty():
			result += " " + timestamp
		record["body_selection_offset"] = result.length() + 1
		return result + "\n" + _record_body_text(record)
	var location_segments := _global_location_segments(record)
	if not location_segments.is_empty():
		result += " @ " + _visual_segments_text(location_segments)
	if not timestamp.is_empty():
		result += " " + timestamp
	record["body_selection_offset"] = result.length() + 1
	return result + "\n" + _record_body_text(record)


func _chat_line_height() -> float:
	return maxf(1.0, _GAME_UI_FONT.get_height(_chat_font_size()))


func _chat_history_maximum_height() -> float:
	var line_limit := _chat_line_height() * _CHAT_VISIBLE_LINE_LIMIT
	var viewport_height := UiScale.safe_rect_for(get_viewport()).end.y
	var top_safe := 0.0
	for control in [privacy_mode_toggle, nametag_style_button, audio_mute_toggle, fullscreen_button, player_list_button]:
		if is_instance_valid(control) and control.is_visible_in_tree():
			top_safe = maxf(top_safe, control.get_global_rect().end.y)
	var bottom_reserve := 0.0
	if chat_input_row.visible:
		bottom_reserve = chat_input_row.get_combined_minimum_size().y
	var available := viewport_height - top_safe - bottom_reserve - UiScale.physical_value(4.0)
	return maxf(_chat_line_height(), minf(line_limit, available))


func _capture_scroll_anchor() -> Dictionary:
	if not _layout_is_history or _message_layouts.is_empty():
		return {}
	var top := float(_history_scroll_bar.value)
	for layout in _message_layouts:
		var y := float(layout.get("y", 0.0))
		var height := float(layout.get("height", 0.0))
		if y + height > top:
			return {
				"message_id": int(layout.get("message_id", 0)),
				"line_offset": maxf(0.0, top - y) / maxf(
					1.0, float(layout.get("line_height", _chat_line_height()))),
			}
	return {
		"message_id": int(_message_layouts.back().get("message_id", 0)),
		"line_offset": 0.0,
	}


func _restore_scroll_anchor(anchor: Dictionary) -> void:
	var target := 0.0
	var wanted_id := int(anchor.get("message_id", 0))
	var found := false
	for layout in _message_layouts:
		if int(layout.get("message_id", 0)) == wanted_id:
			var offset := float(anchor.get("offset", 0.0))
			if anchor.has("line_offset"):
				offset = float(anchor.get("line_offset", 0.0)) * _chat_line_height()
			offset = clampf(offset, 0.0, maxf(
				0.0, float(layout.get("height", 0.0)) - _chat_line_height()))
			target = float(layout.get("y", 0.0)) + offset
			found = true
			break
	if not found and not _message_layouts.is_empty():
		target = float(_message_layouts[0].get("y", 0.0))
	_history_scroll_bar.value = clampf(
		target, 0.0,
		maxf(0.0, _layouts_total_height(_message_layouts) - _chat_viewport_height))
	_apply_virtual_scroll_position()


func _on_chat_scroll_changed(_value: float) -> void:
	if _suppress_scroll_state or not _chat_open:
		return
	_apply_virtual_scroll_position()
	_queue_virtual_render()
	_follow_latest = _is_chat_at_bottom()
	_saved_history_follow_latest = _follow_latest
	if _follow_latest:
		_cancel_jump_latest_notice()
	_saved_history_anchor = _capture_scroll_anchor()
	if is_instance_valid(_player_context_menu):
		_player_context_menu.dismiss_context_menu()
	_update_jump_latest_visibility()
	_consume_jump_latest_notice()


func _is_chat_at_bottom() -> bool:
	var maximum := maxf(
		0.0, _layouts_total_height(_message_layouts) - _chat_viewport_height)
	return float(_history_scroll_bar.value) >= maximum - 1.0


func _queue_virtual_render(force: bool = false) -> void:
	_force_history_render = _force_history_render or force
	if not chat_enabled:
		_history_layout_dirty = true
		return
	if _history_render_queued:
		return
	_history_render_queued = true
	call_deferred("_render_queued_virtual_window", _chat_lifecycle)


func _render_queued_virtual_window(lifecycle: int) -> void:
	if lifecycle != _chat_lifecycle:
		return
	_history_render_queued = false
	var force := _force_history_render
	_force_history_render = false
	_render_virtual_window(force)


func _render_virtual_window(_force: bool = false) -> void:
	var perf_start := ClientPerformance.begin()
	_render_virtual_window_measured(_force)
	ClientPerformance.end(&"chat.virtual_inclusive", perf_start)


func _render_virtual_window_measured(_force: bool = false) -> void:
	if not is_node_ready() or not chat_enabled:
		return
	chat_vbox.visible = true
	chat_selection.call("begin_layout_update")
	if _message_layouts.is_empty():
		for child in chat_vbox.get_children():
			chat_vbox.remove_child(child)
			child.queue_free()
		chat_vbox.position = Vector2.ZERO
		chat_vbox.custom_minimum_size = Vector2(_chat_render_width, 0.0)
		chat_vbox.size = chat_vbox.custom_minimum_size
		_rebuild_chat_selection()
		_refresh_chat_message_presentation()
		_note_restore_progress(not _history_layout_dirty and not _history_layout_queued)
		return
	var top := _display_scroll_offset()
	var overscan := _chat_line_height() * _CHAT_OVERSCAN_LINE_LIMIT
	var render_top := maxf(0.0, top - overscan)
	var render_bottom := top + _chat_viewport_height + overscan
	var desired_ids: Dictionary = {}
	var desired_layouts: Array[Dictionary] = []
	for layout in _message_layouts:
		var y := float(layout.get("y", 0.0))
		var height := float(layout.get("height", 0.0))
		if y + height < render_top or y > render_bottom:
			continue
		var message_id := int(layout.get("message_id", 0))
		desired_ids[message_id] = true
		desired_layouts.append(layout)
	for child in chat_vbox.get_children():
		if not desired_ids.has(int(child.get_meta("chat_message_id", 0))):
			chat_vbox.remove_child(child)
			child.queue_free()
	var existing: Dictionary = {}
	for child in chat_vbox.get_children():
		existing[int(child.get_meta("chat_message_id", 0))] = child
	if desired_layouts.is_empty():
		_rebuild_chat_selection()
		return
	var first_y := float(desired_layouts[0].get("y", 0.0))
	var pending_nodes := false
	var placed := 0
	var current_records := _record_index_by_id
	# Restore the actually visible edge before overscan, rather than painting
	# oldest-first and leaving the newest message blank for several frames.
	var priority_layouts := desired_layouts.duplicate()
	if not _chat_open or _follow_latest:
		priority_layouts.reverse()
	var create_id := -1
	for candidate in priority_layouts:
		var id := int(candidate.message_id)
		var index := int(current_records.get(id, -1))
		if index < 0:
			continue
		var existing_message := existing.get(id) as PanelContainer
		if (not is_instance_valid(existing_message) or _force
				or not is_equal_approx(float(existing_message.get_meta("chat_render_width", -1.0)), float(candidate.render_width))
				or existing_message.get_meta("chat_visual_revision", Vector2i(-1, -1)) != _record_visual_revision(_message_records[index])):
			create_id = id
			if float(candidate.y) + float(candidate.height) >= top and float(candidate.y) <= top + _chat_viewport_height:
				break
	for order in desired_layouts.size():
		var layout := desired_layouts[order]
		var message_id := int(layout.get("message_id", 0))
		var message := existing.get(message_id) as PanelContainer
		var record_index := int(current_records.get(message_id, -1))
		var render_width := float(layout.get("render_width", _chat_render_width))
		if record_index < 0:
			if is_instance_valid(message):
				chat_vbox.remove_child(message)
				message.queue_free()
			continue
		if (is_instance_valid(message) and (_force
				or not is_equal_approx(float(message.get_meta("chat_render_width", -1.0)), render_width)
				or (record_index >= 0 and message.get_meta("chat_visual_revision", Vector2i(-1, -1))
					!= _record_visual_revision(_message_records[record_index])))):
			chat_vbox.remove_child(message)
			message.queue_free()
			ClientPerformance.count_event(&"chat.nodes_replaced")
			message = null
		if not is_instance_valid(message) and record_index >= 0:
			if message_id != create_id or _last_message_creation_frame == Engine.get_process_frames():
				pending_nodes = true
				continue
			_last_message_creation_frame = Engine.get_process_frames()
			message = _new_chat_message(_message_records[record_index], layout)
			chat_vbox.add_child(message)
			UiScale.mark_geometry_physical(message)
			UiScale.apply_control(message)
		if not is_instance_valid(message):
			continue
		var message_height := float(layout.get("height", 0.0))
		message.position = Vector2(
			0.0, float(layout.get("y", 0.0)) - first_y)
		message.custom_minimum_size = Vector2(_chat_render_width, message_height)
		message.size = message.custom_minimum_size
		chat_vbox.move_child(message, placed)
		placed += 1
	var last_layout: Dictionary = desired_layouts.back()
	var rendered_height := (
		float(last_layout.get("y", 0.0))
		+ float(last_layout.get("height", 0.0)) - first_y)
	chat_vbox.position = Vector2(0.0, first_y)
	chat_vbox.custom_minimum_size = Vector2(
		_chat_render_width, minf(rendered_height, _chat_viewport_height))
	chat_vbox.size = Vector2(_chat_render_width, rendered_height)
	_rebuild_chat_selection()
	_refresh_chat_message_presentation()
	if pending_nodes:
		_resume_virtual_render(_chat_lifecycle)
	_note_restore_progress(not pending_nodes and not _history_layout_dirty and not _history_layout_queued)


func _resume_virtual_render(lifecycle: int) -> void:
	if _virtual_render_waiting:
		return
	_virtual_render_waiting = true
	await get_tree().process_frame
	if lifecycle != _chat_lifecycle:
		return
	_virtual_render_waiting = false
	_queue_virtual_render()


func _note_restore_progress(complete: bool) -> void:
	if _restore_started_usec == 0:
		return
	if not ClientPerformance.enabled:
		_restore_started_usec = 0
		_restore_first_visible = false
		return
	if not _restore_first_visible and chat_vbox.get_child_count() > 0:
		_restore_first_visible = true
		ClientPerformance.gauge(&"chat.restore_first_us", Time.get_ticks_usec() - _restore_started_usec)
		ClientPerformance.mark("chat_restore_first_visible")
	if complete:
		ClientPerformance.gauge(&"chat.restore_complete_us", Time.get_ticks_usec() - _restore_started_usec)
		ClientPerformance.mark("chat_restore_complete")
		_restore_started_usec = 0


func _refresh_rendered_message_widths() -> void:
	_queue_virtual_render()


func _chat_scrollbar_physical_width() -> float:
	return float(UiScale.physical_int(_CHAT_SCROLLBAR_DESIGN_WIDTH))


func _update_jump_latest_geometry() -> void:
	if not is_instance_valid(_jump_latest_button):
		return
	var height := maxf(1.0, floorf(_chat_line_height() * 0.5))
	var scroll_width := _chat_scrollbar_physical_width()
	var transform := (
		get_global_transform_with_canvas().affine_inverse()
		* chat_history_scroll.get_global_transform_with_canvas())
	var origin := transform * Vector2.ZERO
	var end := transform * Vector2(_chat_render_width, _chat_viewport_height)
	var extent := (end - origin).abs()
	if is_instance_valid(_jump_latest_layer):
		_jump_latest_layer.position = origin
		_jump_latest_layer.size = extent + Vector2(scroll_width, 0.0)
	if is_instance_valid(_history_scroll_bar):
		_history_scroll_bar.custom_minimum_size.x = scroll_width
		_history_scroll_bar.position = Vector2(extent.x, 0.0)
		_history_scroll_bar.size = Vector2(scroll_width, extent.y)
	_jump_latest_button.add_theme_constant_override(
		"icon_max_width", maxi(1, floori(height * 2.0)))
	_jump_latest_button.position = Vector2(0.0, maxf(0.0, extent.y - height))
	_jump_latest_button.size = Vector2(extent.x, height)


func _update_jump_latest_visibility() -> void:
	if not is_instance_valid(_jump_latest_button):
		return
	var should_show := chat_enabled and _chat_open and _history_overflow and not _is_chat_at_bottom()
	_jump_latest_button.visible = should_show
	if not should_show:
		_stop_jump_latest_flash()
		# A not-yet-committed history view is not an acknowledgement. Keep its
		# pending notice until geometry commits or the user explicitly cancels.
		if not chat_enabled or not _chat_open:
			_pending_jump_latest_mention_id = 0


func _on_jump_latest_pressed() -> void:
	_cancel_jump_latest_notice()
	chat_selection.call("cancel_drag")
	_follow_latest = true
	_saved_history_follow_latest = true
	_suppress_scroll_state = true
	_history_scroll_bar.value = maxf(
		0.0, _layouts_total_height(_message_layouts) - _chat_viewport_height)
	_suppress_scroll_state = false
	_apply_virtual_scroll_position()
	_saved_history_anchor = _capture_scroll_anchor()
	_queue_virtual_render(true)
	_update_jump_latest_visibility()


func _flash_jump_latest() -> void:
	if not is_instance_valid(_jump_latest_button) or not _jump_latest_button.is_visible_in_tree():
		return
	_stop_jump_latest_flash()
	_set_jump_latest_flash_elapsed(0.0)
	_jump_latest_flash_tween = create_tween()
	_jump_latest_flash_tween.tween_method(_set_jump_latest_flash_elapsed, 0.0, 0.8, 0.8)
	_jump_latest_flash_tween.tween_callback(_finish_jump_latest_flash)


func _set_jump_latest_flash_elapsed(elapsed: float) -> void:
	_jump_latest_flash_elapsed = elapsed
	if not is_instance_valid(_jump_latest_background):
		return
	var base := (_CHAT_FIELD_NORMAL_STYLE as StyleBoxFlat).bg_color
	var flash := Color.TRANSPARENT.lerp(
		(_CHAT_TOGGLE_ON_STYLEBOX as StyleBoxFlat).bg_color,
		_mention_flash_strength(elapsed))
	_jump_latest_background.color = base.blend(flash)


func _finish_jump_latest_flash() -> void:
	_jump_latest_flash_tween = null
	_set_jump_latest_flash_elapsed(-1.0)


func _stop_jump_latest_flash() -> void:
	if is_instance_valid(_jump_latest_flash_tween):
		_jump_latest_flash_tween.kill()
	_finish_jump_latest_flash()
	if is_instance_valid(_jump_latest_button):
		_jump_latest_button.modulate = Color.WHITE


func _cancel_jump_latest_notice() -> void:
	_pending_jump_latest_mention_id = 0
	_stop_jump_latest_flash()


func _consume_jump_latest_notice(geometry_committed: bool = false) -> void:
	if _pending_jump_latest_mention_id <= 0:
		return
	if not chat_enabled or not _chat_open or not is_visible_in_tree():
		_cancel_jump_latest_notice()
		return
	var index := int(_record_index_by_id.get(_pending_jump_latest_mention_id, -1))
	if index < 0:
		_pending_jump_latest_mention_id = 0
		return
	if not _layout_is_history or _history_geometry_commit_queued:
		return
	if _jump_latest_button.is_visible_in_tree():
		_pending_jump_latest_mention_id = 0
		_flash_jump_latest()
	elif geometry_committed and _is_chat_at_bottom():
		# Resizing/clamping can expose the newest message before a pending
		# banner notice starts. Use the existing record animation in that case.
		_pending_jump_latest_mention_id = 0
		_fade_tweens[index].mention_elapsed = 0.0


func _apply_virtual_scroll_position() -> void:
	if not is_instance_valid(chat_virtual_content) or not is_instance_valid(_history_scroll_bar):
		return
	chat_virtual_content.position.y = -_display_scroll_offset()


func _display_scroll_offset() -> float:
	return float(_history_scroll_bar.value) if _chat_open else _transient_scroll_offset


func _on_jump_latest_gui_input(event: InputEvent) -> void:
	var mouse := event as InputEventMouseButton
	if mouse == null or not mouse.pressed or not is_instance_valid(_history_scroll_bar):
		return
	if mouse.button_index == MOUSE_BUTTON_WHEEL_UP:
		_history_scroll_bar.value -= _chat_line_height() * 3.0
		_jump_latest_button.accept_event()
	elif mouse.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_history_scroll_bar.value += _chat_line_height() * 3.0
		_jump_latest_button.accept_event()

func add_chat_message(display_name: String, text: String) -> void:
	_append_message({
		"kind": "room",
		"sender_id": 0,
		"display_name": display_name,
		"system_name": "",
		"system_stretch": 1,
		"mention_target_pid": 0,
		"text": text,
	})


func add_chat_message_metadata(
		sender_id: int,
		display_name: String,
		system_name: String,
		mention_target_pid: int,
		text: String) -> void:
	_append_message({
		"kind": "room",
		"sender_id": sender_id,
		"display_name": display_name,
		"system_name": system_name,
		"system_stretch": _player_system_stretch(sender_id, system_name),
		"mention_target_pid": mention_target_pid,
		"text": text,
	})


func add_global_chat_message(
		sender_id: int,
		display_name: String,
		map_id: int,
		previous_map_id: int,
		x: int,
		y: int,
		text: String) -> void:
	_append_message({
		"kind": "global",
		"sender_id": sender_id,
		"display_name": display_name,
		"system_name": "",
		"system_stretch": 1,
		"mention_target_pid": 0,
		"map_id": map_id,
		"previous_map_id": previous_map_id,
		"x": x,
		"y": y,
		"text": text,
	})


func add_global_chat_message_metadata(
		sender_id: int,
		display_name: String,
		system_name: String,
		map_id: int,
		previous_map_id: int,
		x: int,
		y: int,
		mention_target_pid: int,
		text: String) -> void:
	_append_message({
		"kind": "global",
		"sender_id": sender_id,
		"display_name": display_name,
		"system_name": system_name,
		"system_stretch": _player_system_stretch(sender_id, system_name),
		"mention_target_pid": mention_target_pid,
		"map_id": map_id,
		"previous_map_id": previous_map_id,
		"x": x,
		"y": y,
		"text": text,
	})


func _player_system_stretch(sender_id: int, system_name: String) -> int:
	if (not is_instance_valid(mp_connection)
			or not mp_connection.has_method("get_player_system_stretch")):
		return 1
	return clampi(int(mp_connection.call(
		"get_player_system_stretch", sender_id, system_name)), 0, 1)


func _project_record_body(record: Dictionary) -> void:
	var parsed := _CHAT_SPOILERS.parse(str(record.get("text", "")))
	var base_mentions := _CHAT_SPOILERS.display_mentions(record.get("mentions", []), parsed.raw_to_display)
	var projected := ChatMentions.to_display(str(parsed.text), base_mentions, _display_language)
	record["display_text"] = projected.text
	record["display_mentions"] = projected.mentions
	record["body_source_to_display"] = projected.mapping
	record["body_display_to_source"] = projected.inverse
	for span: Dictionary in parsed.ranges:
		span.start = ChatMentions.mapped_offset(projected.mapping, int(span.start))
		span.end = ChatMentions.mapped_offset(projected.mapping, int(span.end))
	record["spoilers"] = parsed.ranges


func _append_message(record: Dictionary) -> void:
	var perf_start := ClientPerformance.begin()
	_append_message_measured(record)
	ClientPerformance.end(&"chat.append", perf_start)


func _append_message_measured(record: Dictionary) -> void:
	var stored_record: Dictionary = record.duplicate(true)
	_project_record_body(stored_record)
	stored_record["spoiler_revealed"] = {}
	# New packets carry server-owned facts. Legacy records take a one-time
	# best-effort snapshot, never a live role lookup during layout or painting.
	if not stored_record.has("sender_is_admin"):
		stored_record["sender_is_admin"] = (is_instance_valid(mp_connection)
			and mp_connection.is_player_admin(int(stored_record.get("sender_id", 0))))
	if not stored_record.has("subject_group_id") and is_instance_valid(mp_connection):
		stored_record["subject_group_id"] = mp_connection.get_admin_subject_group_for_pid(
			int(stored_record.get("sender_id", 0)))
	stored_record["message_id"] = _next_message_id
	_next_message_id += 1
	var received_time := Time.get_time_dict_from_system()
	stored_record["timestamp"] = "%02d:%02d" % [
		int(received_time.get("hour", 0)),
		int(received_time.get("minute", 0)),
	]
	stored_record["selection_text"] = _record_selection_text(stored_record)
	var mentioned := bool(stored_record.get("mentioned_local", false)) or (
		is_instance_valid(mp_connection)
		and int(stored_record.get("mention_target_pid", 0)) > 0
		and int(stored_record.get("mention_target_pid", 0)) == mp_connection.get_my_pid())
	_message_records.append(stored_record)
	_record_index_by_id[int(stored_record.message_id)] = _message_records.size() - 1
	_selection_history_dirty = true
	var fade := FadeTween.new()
	if mentioned and not (_chat_open and not _follow_latest):
		fade.mention_elapsed = 0.0
	_fade_tweens.append(fade)
	_delete_old_messages()
	if mentioned and chat_enabled and _chat_open and not _follow_latest:
		_pending_jump_latest_mention_id = int(stored_record["message_id"])
		_consume_jump_latest_notice()


func _flash_mentioned_message(chat_message: PanelContainer) -> void:
	var message_id := int(chat_message.get_meta("chat_message_id", 0))
	var index := int(_record_index_by_id.get(message_id, -1))
	if index >= 0 and index < _fade_tweens.size():
		_fade_tweens[index].mention_elapsed = 0.0


func _resolve_record_location(record: Dictionary) -> Dictionary:
	if (
		not is_instance_valid(_location_runtime) or
		not _location_runtime.has_method("resolve_location")
	):
		return {}
	var resolved: Variant = _location_runtime.call(
		"resolve_location",
		int(record.get("map_id", 0)),
		int(record.get("previous_map_id", 0)),
		int(record.get("x", -1)),
		int(record.get("y", -1))
	)
	return resolved if resolved is Dictionary else {}


func _new_chat_message(record: Dictionary, layout: Dictionary) -> PanelContainer:
	var perf_start := ClientPerformance.begin()
	var chat_message := PanelContainer.new()
	chat_message.set_meta("chat_message_id", int(record.get("message_id", 0)))
	chat_message.set_meta("chat_visual_revision", _record_visual_revision(record))
	var render_width := float(layout.get(
		"render_width",
		_chat_render_width if _chat_render_width > 0.0 else _chat_message_layout_width()))
	chat_message.set_meta("chat_render_width", render_width)
	_set_physical_minimum_width(chat_message, render_width)
	chat_message.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chat_message.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chat_message.add_theme_stylebox_override("panel", _new_chat_message_content_style())
	UiScale.declare_control_overrides(chat_message, PackedStringArray(), PackedStringArray(["panel"]))
	var metrics: Dictionary = layout.get("metrics", {})
	if str(record.get("kind", "room")) == "global":
		_build_global_visual_message(chat_message, record, metrics)
	else:
		_build_room_visual_message(chat_message, record, metrics)
	ClientPerformance.count_event(&"chat.nodes_created")
	ClientPerformance.end(&"chat.node_build", perf_start)
	return chat_message


func _record_visual_revision(record: Dictionary) -> Vector2i:
	return Vector2i(_chat_paint_revision, int(record.get("_visual_revision", 0)))


func _build_room_visual_message(
		root: PanelContainer, record: Dictionary, metrics: Dictionary) -> void:
	var content := VBoxContainer.new()
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 0)
	UiScale.declare_control_overrides(content, PackedStringArray(["separation"]), PackedStringArray())
	root.add_child(content)
	var available_width := _chat_message_content_width(root)
	var header := _new_visual_row()
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_set_physical_minimum_width(header, available_width)
	var prefix_width := _append_visual_player_name(header, record)
	var separator := _new_visual_label(
		" ", "", int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG))
	header.add_child(separator)
	prefix_width += _visual_text_width(" ")
	var timestamp := str(record.get("timestamp", ""))
	var timestamp_new_line := bool(metrics.get("timestamp_new_line", false))
	if not timestamp.is_empty() and not timestamp_new_line:
		_append_right_aligned_timestamp(
			header, timestamp, maxf(1.0, available_width - prefix_width))
	content.add_child(header)
	if not timestamp.is_empty() and timestamp_new_line:
		var timestamp_row := _new_visual_row()
		timestamp_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_set_physical_minimum_width(timestamp_row, available_width)
		_append_right_aligned_timestamp(timestamp_row, timestamp, available_width)
		content.add_child(timestamp_row)
	var lines: Array = metrics.get("room_lines", [])
	if lines.is_empty() and not _record_body_text(record).is_empty():
		lines = _wrap_message_lines(
			_record_body_text(record), available_width, available_width)
	var body_offset := 0
	for index in lines.size():
		_append_body_line(content, str(lines[index]), record, body_offset, available_width)
		body_offset = _next_body_line_offset(record, body_offset + str(lines[index]).length())


func _build_global_visual_message(
		root: PanelContainer, record: Dictionary, metrics: Dictionary) -> void:
	var content := VBoxContainer.new()
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 0)
	UiScale.declare_control_overrides(content, PackedStringArray(["separation"]), PackedStringArray())
	root.add_child(content)
	var header := _new_visual_row()
	content.add_child(header)
	var header_rows: Array[HBoxContainer] = [header]
	var icon := TextureRect.new()
	icon.texture = _GLOBAL_CHAT_MESSAGE_ICON
	icon.custom_minimum_size = Vector2(16, 16)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if is_instance_valid(_theme_text_runtime):
		_theme_text_runtime.style_icon(
			icon, get_theme_source(), "", int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_NORMAL),
			false, 16.0, false)
	header.add_child(icon)
	var header_prefix_width := UiScale.physical_value(16.0)
	header_prefix_width += _append_visual_player_name(header, record)
	var header_segments: Array[Dictionary] = []
	var measured_segments: Variant = metrics.get("header_segments", [])
	if measured_segments is Array:
		for segment: Variant in measured_segments:
			if segment is Dictionary:
				header_segments.append(segment as Dictionary)
	if header_segments.is_empty():
		header_segments = _global_prefix_segments(record)
	var available_width := _chat_message_content_width(root)
	_set_physical_minimum_width(header, available_width)
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var header_text := _visual_segments_text(header_segments)
	var header_lines: Array = metrics.get("header_lines", [])
	if header_lines.is_empty():
		header_lines = _wrap_message_lines(
			header_text,
			available_width - header_prefix_width,
			available_width)
	var segment_offset := 0
	for line_index in header_lines.size():
		var line_text := str(header_lines[line_index])
		var line_row := header if line_index == 0 else _new_visual_row()
		if line_index > 0:
			_set_physical_minimum_width(line_row, available_width)
			line_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			content.add_child(line_row)
			header_rows.append(line_row)
		_append_visual_segment_range(
			line_row, header_segments, segment_offset, line_text.length())
		segment_offset += line_text.length()
	var timestamp := str(record.get("timestamp", ""))
	if not timestamp.is_empty():
		if bool(metrics.get("timestamp_new_line", false)):
			var timestamp_row := _new_visual_row()
			_set_physical_minimum_width(timestamp_row, available_width)
			timestamp_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_append_right_aligned_timestamp(timestamp_row, timestamp, available_width)
			content.add_child(timestamp_row)
		else:
			_append_right_aligned_timestamp(
				header_rows.back(),
				timestamp,
				_timestamp_slot_width(
					header_lines, header_prefix_width, available_width, timestamp))
	var lines: Array = metrics.get("body_lines", [])
	if lines.is_empty() and not _record_body_text(record).is_empty():
		lines = _wrap_message_lines(
			_record_body_text(record), available_width, available_width)
	var body_offset := 0
	for index in lines.size():
		_append_body_line(content, str(lines[index]), record, body_offset, available_width)
		body_offset = _next_body_line_offset(record, body_offset + str(lines[index]).length())


func _append_body_line(content: VBoxContainer, body: String, record: Dictionary, offset: int, width: float) -> void:
	var label := _new_body_label(body, record, offset)
	_set_physical_minimum_width(label, width)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if label is RichTextLabel:
		# RichTextLabel uses shaped height; ordinary Label pads to font-chain height.
		# Reuse the header's baseline helper and keep the measured body line height.
		var row := _new_visual_row()
		_set_physical_minimum_width(row, width)
		row.custom_minimum_size.y = _chat_line_height()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		content.add_child(row)
		row.add_child(label)
	else:
		content.add_child(label)
	_attach_mention_marks(label, record, offset)


func _record_body_text(record: Dictionary) -> String:
	return str(record.get("display_text", record.get("text", "")))


func _new_body_label(body: String, record: Dictionary, offset: int) -> Control:
	var label: Control
	var needs_spoiler := false
	for span: Dictionary in record.get("spoilers", []):
		if offset < int(span.end) and offset + body.length() > int(span.start):
			needs_spoiler = true
			break
	if needs_spoiler:
		var rich := _CHAT_SPOILER_LABEL.new()
		rich.fit_content = true
		rich.scroll_active = false
		rich.autowrap_mode = TextServer.AUTOWRAP_OFF
		rich.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		rich.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
		rich.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		_apply_game_ui_text_rendering(rich, "", int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_NORMAL))
		rich.configure(body, offset, record)
		label = rich
	else:
		label = _new_visual_label(body)
	label.set_meta("chat_select_record_offset", int(record.get("body_selection_offset", 0)) + offset)
	return label


func _on_spoiler_reveal_requested(message_id: int, segment: int) -> void:
	var index := int(_record_index_by_id.get(message_id, -1))
	if index < 0 or index >= _message_records.size():
		return
	var record := _message_records[index]
	if segment < 0 or segment >= (record.get("spoilers", []) as Array).size():
		return
	var revealed: Dictionary = record.spoiler_revealed
	if revealed.has(segment):
		return
	revealed[segment] = true
	# History owns reveal state; repaint only existing lines of this message.
	for message in chat_vbox.get_children():
		if int(message.get_meta("chat_message_id", 0)) == message_id:
			_refresh_spoiler_lines(message, segment)


func _refresh_spoiler_lines(node: Node, segment: int) -> void:
	if node.has_method("reveal_segment"):
		node.call("reveal_segment", segment)
	for child in node.get_children():
		_refresh_spoiler_lines(child, segment)


func _next_body_line_offset(record: Dictionary, offset: int) -> int:
	var body := _record_body_text(record)
	while offset < body.length() and body.substr(offset, 1) in ["\r", "\n"]:
		offset += 1
	return offset


func _attach_mention_marks(label: Control, record: Dictionary, offset: int) -> void:
	var ranges: Array[Vector2i] = []
	for span in record.get("display_mentions", record.get("mentions", [])):
		var start := maxi(offset, int(span.start))
		var end := mini(offset + str(label.get_meta("chat_select_text", "")).length(), int(span.start) + int(span.length))
		if end > start:
			ranges.append(Vector2i(start - offset, end - offset))
	if ranges.is_empty():
		return
	var marks := _CHAT_MENTION_MARKS.new()
	marks.host = label
	marks.ranges = ranges
	label.add_child(marks)


func _new_visual_segment(
		text: String,
		url: String = "",
		role: int = int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_NORMAL)) -> Dictionary:
	return {"text": text, "url": url, "role": role}


func _global_prefix_segments(record: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var location_segments := _global_location_segments(record)
	if not location_segments.is_empty():
		result.append(_new_visual_segment(
			" @ ", "", int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG)))
		result.append_array(location_segments)
	result.append(_new_visual_segment(
		" ", "", int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG)))
	return result


func _global_location_segments(record: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var location := _resolve_record_location(record)
	var localized_entries := _get_visible_location_entries(
		location, "localized_available", "localized_entries")
	var english_entries := _get_visible_location_entries(
		location, "english_available", "english_entries")
	if (bool(location.get("hidden", false))
			or (localized_entries.is_empty() and english_entries.is_empty())):
		return result
	if localized_entries.is_empty():
		_append_visual_location_segments(result, english_entries)
	elif english_entries.is_empty():
		_append_visual_location_segments(result, localized_entries)
	else:
		_append_visual_location_segments(result, localized_entries)
		result.append(_new_visual_segment(
			" (", "", int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG)))
		_append_visual_location_segments(result, english_entries)
		result.append(_new_visual_segment(
			")", "", int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG)))
	return result


func _append_visual_location_segments(
		result: Array[Dictionary],
		entries: Array[Dictionary]) -> void:
	for index in entries.size():
		if index > 0:
			result.append(_new_visual_segment(
				" | ", "", int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG)))
		var entry := entries[index]
		var title := str(entry.get("title", "")).strip_edges()
		var url := str(entry.get("url", "")).strip_edges()
		if not _is_location_url_allowed(url):
			url = ""
		result.append(_new_visual_segment(
			title, url, int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG)))


func _visual_segments_text(segments: Array[Dictionary]) -> String:
	var result := ""
	for segment in segments:
		result += str(segment.get("text", ""))
	return result


func _append_visual_segment_range(
		row: HBoxContainer,
		segments: Array[Dictionary],
		start_offset: int,
		length: int) -> void:
	var range_end := start_offset + length
	var segment_start := 0
	for segment in segments:
		var text := str(segment.get("text", ""))
		var segment_end := segment_start + text.length()
		var overlap_start := maxi(start_offset, segment_start)
		var overlap_end := mini(range_end, segment_end)
		if overlap_end > overlap_start:
			var piece := text.substr(
				overlap_start - segment_start, overlap_end - overlap_start)
			var url := str(segment.get("url", ""))
			var role := int(segment.get(
				"role", int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_NORMAL)))
			if url.is_empty():
				row.add_child(_new_visual_label(piece, "", role))
			else:
				row.add_child(_new_visual_link_piece(piece, url, role))
		segment_start = segment_end
		if segment_start >= range_end:
			break


func _new_visual_link_piece(text: String, url: String, role: int) -> RichTextLabel:
	var label := RichTextLabel.new()
	label.fit_content = true
	label.scroll_active = false
	label.autowrap_mode = TextServer.AUTOWRAP_OFF
	label.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	label.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_apply_game_ui_text_rendering(label, "", role)
	label.push_meta(url, RichTextLabel.META_UNDERLINE_ALWAYS, url)
	label.add_text(text)
	label.pop()
	label.set_meta("chat_select_text", text)
	label.set_meta("chat_link_url", url)
	return label


func _new_visual_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	preload("res://cogs/ui_text_baseline.gd").install(row, true)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 0)
	UiScale.declare_control_overrides(row, PackedStringArray(["separation"]), PackedStringArray())
	return row


func _append_right_aligned_timestamp(
		row: HBoxContainer, timestamp: String, slot_width: float) -> void:
	var timestamp_label := _new_visual_label(
		timestamp, "", int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG))
	_set_physical_minimum_width(timestamp_label, slot_width)
	timestamp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(timestamp_label)
	timestamp_label.position.x = maxf(
		0.0, row.custom_minimum_size.x - slot_width)


func _append_visual_player_name(row: HBoxContainer, record: Dictionary) -> float:
	var total_width := 0.0
	var raw_name := str(record.get("display_name", ""))
	var opening := "<" if raw_name.is_empty() else "["
	var closing := ">" if raw_name.is_empty() else "]"
	var display_name := PlayerName.label(raw_name, _display_language)
	var opening_bracket := _new_visual_label(
		opening, "", int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG))
	row.add_child(opening_bracket)
	total_width += _visual_text_width(opening)
	var name_label := _new_visual_label(
		display_name, str(record.get("system_name", "")))
	if int(record.get("sender_id", 0)) > 0:
		name_label.set_meta("chat_player_meta", {
			"chat_player": true,
			"public_chat_id": str(record.get("public_chat_id", "")),
			"subject_group_id": str(record.get("subject_group_id", "")),
			"sender_id": int(record.get("sender_id", 0)),
			"display_name": str(record.get("display_name", "")),
			"system_name": str(record.get("system_name", "")),
			"system_stretch": int(record.get("system_stretch", 1)),
			"message_kind": str(record.get("kind", "room")),
		})
	row.add_child(name_label)
	total_width += _visual_text_width(display_name)
	if bool(record.get("sender_is_admin", false)):
		if is_instance_valid(_theme_text_runtime):
			var badge := _theme_text_runtime.make_text_glyph_icon(
				_ADMIN_ICON,
				get_theme_source(),
				str(record.get("system_name", "")),
				int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_NORMAL),
				12,
				16) as Control
			badge.name = "PlayerAdminBadge"
			if name_label.has_meta("chat_player_meta"):
				badge.set_meta("chat_player_meta", name_label.get_meta("chat_player_meta"))
			WebpageThemeTooltipRuntime.set_control_tooltip(badge, "管理员")
			row.add_child(badge)
			total_width += UiScale.physical_value(16.0)
	var closing_bracket := _new_visual_label(
		closing, "", int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG))
	row.add_child(closing_bracket)
	total_width += _visual_text_width(closing)
	return total_width


func _new_visual_label(
		text: String, system_name: String = "", role: int = 0,
		wrap: bool = false) -> Label:
	var label := Label.new()
	label.text = text
	label.set_meta("chat_select_text", text)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	if wrap:
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_apply_game_ui_text_rendering(label, system_name, role)
	return label


func _visual_text_width(text: String) -> float:
	if text.is_empty():
		return 0.0
	return _GAME_UI_FONT.get_string_size(
		text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, _chat_font_size()).x


func _chat_message_layout_width() -> float:
	var viewport := get_viewport()
	if viewport == null:
		return UiScale.physical_value(_CHAT_MAX_DESIGN_WIDTH)
	var half_viewport := floorf(viewport.get_visible_rect().size.x * 0.5)
	var design_cap := floorf(UiScale.physical_value(_CHAT_MAX_DESIGN_WIDTH))
	return maxf(1.0, minf(half_viewport, design_cap))


func _chat_message_content_width(panel: PanelContainer) -> float:
	var _unused_panel := panel
	var width := _chat_render_width if _chat_render_width > 0.0 else _chat_message_layout_width()
	return _chat_message_content_width_for_width(width)


func _chat_message_content_width_for_width(width: float) -> float:
	var horizontal_margin := (
		_CHAT_MESSAGE_STYLEBOX.get_minimum_size().x * UiScale.get_ui_scale())
	return maxf(1.0, width - horizontal_margin)


func _set_physical_minimum_width(control: Control, width: float) -> void:
	if not is_instance_valid(control):
		return
	UiScale.mark_geometry_physical(control)
	control.custom_minimum_size.x = maxf(0.0, width)


func _apply_chat_width_limit() -> void:
	var width := _chat_message_layout_width()
	var stack := chat_history_scroll.get_parent() as Control
	if stack != null:
		_set_physical_minimum_width(stack, width)
		stack.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		stack.clip_contents = false
	chat_history_scroll.custom_minimum_size.x = width
	_schedule_history_layout()


func _wrap_message_lines(text: String, first_width: float, full_width: float) -> Array[String]:
	var lines: Array[String] = []
	if text.is_empty():
		lines.append("")
		return lines
	var remaining := text
	var font_size := _chat_font_size()
	if first_width > 1.0:
		var first_character_width := _GAME_UI_FONT.get_string_size(
			remaining.substr(0, 1), HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x
		if first_character_width <= first_width:
			var first_count := _first_paragraph_line_length(remaining, first_width)
			if first_count > 0:
				lines.append(_visible_message_line(remaining.substr(0, first_count)))
				remaining = remaining.substr(first_count)
	if lines.is_empty():
		lines.append("")
	while not remaining.is_empty():
		var count := _first_paragraph_line_length(remaining, full_width)
		if count <= 0:
			count = 1
		lines.append(_visible_message_line(remaining.substr(0, count)))
		remaining = remaining.substr(count)
	return lines


func _first_paragraph_line_length(text: String, width: float) -> int:
	if text.is_empty():
		return 0
	var resolved_width := maxf(1.0, floorf(width))
	var adaptive_length := _paragraph_first_line_length(
		text,
		resolved_width,
		TextServer.BREAK_MANDATORY
		| TextServer.BREAK_WORD_BOUND
		| TextServer.BREAK_ADAPTIVE)
	if adaptive_length > 0:
		if _message_prefix_fits(text, adaptive_length, resolved_width):
			return adaptive_length
	var grapheme_length := _paragraph_first_line_length(
		text,
		resolved_width,
		TextServer.BREAK_MANDATORY
		| TextServer.BREAK_GRAPHEME_BOUND)
	while grapheme_length > 0:
		if _message_prefix_fits(text, grapheme_length, resolved_width):
			return grapheme_length
		grapheme_length -= 1
	return 0


func _message_prefix_fits(text: String, length: int, width: float) -> bool:
	if length <= 0:
		return false
	var candidate := _visible_message_line(text.substr(0, length))
	return _visual_text_width(candidate) <= width + 0.01


func _paragraph_first_line_length(text: String, width: float, break_flags: int) -> int:
	var paragraph := TextParagraph.new()
	paragraph.break_flags = break_flags
	paragraph.width = maxf(1.0, floorf(width))
	paragraph.add_string(text, _GAME_UI_FONT, _chat_font_size())
	if paragraph.get_line_count() <= 0:
		return text.length()
	var line_range := paragraph.get_line_range(0)
	return clampi(line_range.y, 0, text.length())


func _visible_message_line(text: String) -> String:
	var visible := text
	while visible.ends_with("\n") or visible.ends_with("\r"):
		visible = visible.left(-1)
	return visible


func _schedule_chat_message_reflow() -> void:
	if _message_reflow_pending:
		return
	_message_reflow_pending = true
	call_deferred("_perform_chat_message_reflow", _chat_lifecycle)


func _perform_chat_message_reflow(lifecycle: int) -> void:
	if lifecycle != _chat_lifecycle:
		return
	_message_reflow_pending = false
	if is_node_ready():
		_rerender_message_history()
		call_deferred("_restore_chat_overlay_layout", _chat_lifecycle)


func _restore_chat_overlay_layout(lifecycle: int) -> void:
	if lifecycle != _chat_lifecycle or not is_node_ready() or not chat_enabled:
		return
	var bottom_layout := chat_input_row.get_parent() as Control
	if bottom_layout != null:
		bottom_layout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		if bottom_layout is Container:
			(bottom_layout as Container).queue_sort()
	var location_row := chat_history_scroll.get_parent().get_parent() as Container
	if location_row != null:
		location_row.queue_sort()
	var stack := chat_history_scroll.get_parent() as Container
	if stack != null:
		stack.queue_sort()


func _restore_native_chat_field_rendering() -> void:
	if not is_instance_valid(chat_text_field):
		return
	_refresh_touch_chat_placeholder()


func _refresh_touch_chat_placeholder() -> void:
	if not touch_chat:
		return
	chat_text_field.add_theme_color_override("font_placeholder_color",
		ThemeDB.get_default_theme().get_color("font_placeholder_color", "LineEdit"))
	if chat_text_field.editable:
		chat_text_field.alignment = (
			HORIZONTAL_ALIGNMENT_CENTER if chat_text_field.text.is_empty()
			else HORIZONTAL_ALIGNMENT_LEFT)


func _refresh_chat_field_theme_role() -> void:
	if not is_instance_valid(chat_text_field) or not is_instance_valid(_theme_text_runtime):
		return
	_theme_text_runtime.style_control(
		chat_text_field,
		get_theme_source(),
		"",
		int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG)
		if global_chat_toggle.button_pressed
		else int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_NORMAL))
	_restore_native_chat_field_rendering()


func _get_visible_location_entries(
		location: Dictionary,
		available_key: String,
		entries_key: String) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	if bool(location.get("hidden", false)) or not bool(location.get(available_key, false)):
		return entries
	var raw_entries: Variant = location.get(entries_key, [])
	if not raw_entries is Array:
		return entries
	for raw_entry: Variant in raw_entries:
		if not raw_entry is Dictionary:
			continue
		var entry: Dictionary = raw_entry
		if str(entry.get("title", "")).strip_edges().is_empty():
			continue
		entries.append(entry)
	return entries


func _append_location_entries(
		label: RichTextLabel,
		entries: Array[Dictionary],
		interactive: bool = true) -> void:
	for index in entries.size():
		if index > 0:
			label.add_text(" | ")
		var entry := entries[index]
		var title := str(entry.get("title", "")).strip_edges()
		var url := str(entry.get("url", "")).strip_edges()
		if _is_location_url_allowed(url):
			var show_strong_color := label != chat_selection
			if show_strong_color:
				var strong_color := _ui_strong_color
				if is_instance_valid(_theme_text_runtime):
					strong_color = _theme_text_runtime.role_color(
						get_theme_source(), "", _WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG,
						_ui_strong_color)
				label.push_color(strong_color)
			if interactive:
				label.push_meta(url, RichTextLabel.META_UNDERLINE_ALWAYS, url)
			label.add_text(title)
			if interactive:
				label.pop()
			if show_strong_color:
				label.pop()
		else:
			label.add_text(title)


func _rebuild_chat_selection() -> void:
	var perf_start := ClientPerformance.begin()
	_rebuild_chat_selection_measured()
	ClientPerformance.end(&"chat.selection", perf_start)


func _rebuild_chat_selection_measured() -> void:
	if not is_node_ready():
		return
	if _selection_history_dirty:
		chat_selection.call("set_history", _message_records)
		_selection_history_dirty = false
		ClientPerformance.count_event(&"chat.selection_history_updates")
	if _chat_selection_commit_queued:
		return
	_chat_selection_commit_queued = true
	call_deferred(
		"_commit_chat_selection_geometry", _chat_lifecycle)


func _commit_chat_selection_geometry(lifecycle: int) -> void:
	await get_tree().process_frame
	if lifecycle != _chat_lifecycle:
		return
	_chat_selection_commit_queued = false
	if not is_node_ready() or not chat_enabled:
		return
	var perf_start := ClientPerformance.begin()
	chat_selection.custom_minimum_size = Vector2(
		_chat_render_width, _chat_viewport_height)
	chat_selection.size = chat_virtual_content.size
	chat_selection.position = Vector2.ZERO
	chat_selection.call("commit_layout_update")
	if _chat_open and is_instance_valid(_player_context_menu):
		_player_context_menu.notify_chat_layout_changed()
	ClientPerformance.end(&"chat.selection_geometry", perf_start)


func _rerender_message_history() -> void:
	if not is_node_ready():
		return
	_chat_paint_revision += 1
	_history_prepare_generation += 1
	for record in _message_records:
		_project_record_body(record)
		record.erase("_metrics_key")
		record.erase("_metrics")
		var selection_text := _record_selection_text(record)
		if selection_text != str(record.get("selection_text", "")):
			record["selection_text"] = selection_text
			_selection_history_dirty = true
	ClientPerformance.count_event(&"chat.full_invalidations")
	_schedule_history_layout()


func _refresh_current_location() -> void:
	if not is_node_ready():
		return
	var location: Dictionary = {}
	if (
		is_instance_valid(_location_runtime) and
		_location_runtime.has_method("get_current_location")
	):
		var resolved: Variant = _location_runtime.call("get_current_location")
		if resolved is Dictionary:
			location = resolved
	_render_current_location(location)


func _render_current_location(location: Dictionary) -> void:
	current_location_localized.clear()
	current_location_english.clear()
	var localized_entries := _get_visible_location_entries(
		location,
		"localized_available",
		"localized_entries"
	)
	var english_entries := _get_visible_location_entries(
		location,
		"english_available",
		"english_entries"
	)
	var show_localized := not localized_entries.is_empty()
	var show_english := not english_entries.is_empty()
	_current_location_has_localized = show_localized
	_current_location_has_english = show_english
	current_location_localized.visible = show_localized
	current_location_english.visible = show_english
	if show_localized:
		_append_location_entries(current_location_localized, localized_entries)
	if show_english:
		_append_location_entries(current_location_english, english_entries)
	_update_current_location_width()
	_update_current_location_visibility()


func _update_current_location_width() -> void:
	if not is_node_ready() or _location_width_queued:
		return
	_location_width_queued = true
	_commit_current_location_width.call_deferred()


func _commit_current_location_width() -> void:
	_location_width_queued = false
	if not is_node_ready():
		return
	# The row's minimum can be enlarged by the labels themselves. Use the
	# externally sized ChatControl (the safe rectangle on Android), never that
	# self-influenced row size. Empty chat still reserves its message column.
	var message_width := _chat_message_layout_width()
	var scroll_width := _chat_scrollbar_physical_width() if (
		_chat_open and is_instance_valid(_history_scroll_bar)
		and _history_scroll_bar.visible) else 0.0
	var maximum_width := maxf(1.0, minf(
		_LOCATION_TEXT_LAYOUT.width_limit(self), size.x - message_width - scroll_width))
	UiScale.mark_geometry_physical(current_location_modules)
	current_location_modules.custom_minimum_size.x = 0.0
	_fit_current_location_label(current_location_localized, maximum_width)
	_fit_current_location_label(current_location_english, maximum_width)


func _fit_current_location_label(label: RichTextLabel, maximum_width: float) -> void:
	UiScale.mark_geometry_physical(label)
	if not label.visible:
		label.custom_minimum_size.x = 0.0
		return
	var font := label.get_theme_font("normal_font")
	var font_size := label.get_theme_font_size("normal_font_size")
	var text_width := font.get_string_size(
		label.get_parsed_text(),
		HORIZONTAL_ALIGNMENT_LEFT,
		-1.0,
		font_size
	).x
	var normal_style := label.get_theme_stylebox("normal")
	var horizontal_margins := 0.0
	if normal_style != null:
		horizontal_margins = normal_style.get_minimum_size().x
	var width := clampf(
		ceilf(text_width + horizontal_margins),
		1.0,
		maximum_width
	)
	if not is_equal_approx(label.custom_minimum_size.x, width):
		label.custom_minimum_size.x = width


func is_chat_open() -> bool:
	return _chat_open


func render_location_notification(label: RichTextLabel, entries: Array[Dictionary], prepare_theme := true) -> void:
	# Share the Wiki's text, wrapping and background, without link metadata.
	if prepare_theme:
		var empty := StyleBoxEmpty.new()
		for side: Side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
			empty.set_content_margin(side, _CHAT_MESSAGE_STYLEBOX.get_content_margin(side))
		UiScale.apply_physical_stylebox(label, &"normal", _CHAT_MESSAGE_STYLEBOX)
		UiScale.apply_physical_stylebox(label, &"focus", empty)
		_apply_game_ui_text_rendering(label)
	label.clear()
	_append_location_entries(label, entries, false)
	_fit_current_location_label(label, _LOCATION_TEXT_LAYOUT.width_limit(self))


func _chat_font_size() -> int:
	return UiScale.physical_font_size(16)


func _on_ui_scale_changed(_ui_scale: float) -> void:
	_layout_corner_actions.call_deferred()
	_apply_chat_width_limit()
	_update_current_location_width()
	_schedule_chat_message_reflow()
	_refresh_nametag_style_button()
	location_presentation_changed.emit()


func _update_current_location_visibility() -> void:
	if not is_node_ready():
		return
	current_location_modules.visible = (
		_chat_open and
		(_current_location_has_localized or _current_location_has_english)
	)
	_update_current_location_width()


func _on_current_location_changed(location: Dictionary) -> void:
	if is_node_ready():
		_render_current_location(location)


func _set_display_language(language: String) -> void:
	_display_language = PlayerName.LocationResolver.normalize_language_code(language)
	if chat_text_field.has_method("set_display_language"):
		chat_text_field.call("set_display_language", _display_language)
	if is_instance_valid(_player_context_menu):
		_player_context_menu.set_display_language(_display_language)


func _on_location_language_changed(language: String) -> void:
	_set_display_language(language)
	_refresh_current_location()
	_rerender_message_history()


func _is_location_url_allowed(url: String) -> bool:
	if url.is_empty() or not url.to_lower().begins_with("https://"):
		return false
	if (
		not is_instance_valid(_location_runtime) or
		not _location_runtime.has_method("is_url_allowed")
	):
		return false
	return bool(_location_runtime.call("is_url_allowed", url))


func _on_chat_message_meta_clicked(meta: Variant) -> void:
	if not chat_enabled or not visible:
		return
	if meta is Dictionary:
		return
	var url := str(meta).strip_edges()
	if not _is_location_url_allowed(url):
		Log.warn("[chat_overlay] blocked unexpected chat link")
		return
	var error := OS.shell_open(url)
	if error != OK:
		Log.warn("[chat_overlay] could not open location link: %s" % error_string(error))


func _on_chat_selection_gui_input(event: InputEvent) -> void:
	var mouse_event := event as InputEventMouseButton
	if (not chat_enabled or not visible
			or mouse_event == null
			or mouse_event.button_index != MOUSE_BUTTON_RIGHT
			or not is_instance_valid(_player_context_menu)):
		return
	chat_selection.accept_event()
	if _player_context_menu.handle_right_click(mouse_event):
		_open_chat_context_at(mouse_event.global_position)


func _open_chat_context_at(position: Vector2) -> void:
	if (not chat_enabled or not visible or not _chat_open
			or not chat_selection.get_global_rect().has_point(position)
			or not chat_history_scroll.get_global_rect().has_point(position)):
		return
	var player_meta := _find_visual_player_meta_at(chat_vbox, position)
	if player_meta.is_empty():
		_player_context_menu.open_text_menu(position)
		return
	_player_context_menu.open_player_menu(player_meta, position)


func _find_visual_player_meta_at(root: Node, global_position: Vector2) -> Dictionary:
	if (root == chat_vbox and is_instance_valid(chat_history_scroll)
			and not chat_history_scroll.get_global_rect().has_point(global_position)):
		return {}
	if root is Control:
		var control := root as Control
		if (not control.is_visible_in_tree()
				or (control.clip_contents and not control.get_global_rect().has_point(global_position))):
			return {}
		var hit_rect := control.get_global_rect()
		var row := control.get_parent() as Control
		if ((control is Label or control is RichTextLabel)
				and row != null and row.has_meta("chat_baseline_row")):
			hit_rect.position.y = row.get_global_rect().position.y
			hit_rect.size.y = row.get_global_rect().size.y
		if control.has_meta("chat_player_meta") and hit_rect.has_point(global_position):
			var meta: Variant = control.get_meta("chat_player_meta")
			if meta is Dictionary:
				return (meta as Dictionary).duplicate(true)
	for child in root.get_children():
		var found := _find_visual_player_meta_at(child, global_position)
		if not found.is_empty():
			return found
	return {}


func _on_player_mention_requested(player_meta: Dictionary) -> bool:
	if not is_instance_valid(mp_connection) or not chat_text_field.has_method("insert_mention"):
		return false
	var target := mp_connection.get_chat_mention_target(player_meta)
	if target.is_empty():
		return false
	if not bool(chat_text_field.call("insert_mention", str(target.public_chat_id), str(target.display_name))):
		return false
	chat_input_row.set_visible(true)
	if not touch_chat:
		chat_text_field.grab_focus()
	_set_chat_open_state(true)
	_set_chat_interaction_enabled(true)
	_update_current_location_visibility()
	_refresh_multiplayer_status_ui()
	return true


func mention_player(player_meta: Dictionary) -> bool:
	return _on_player_mention_requested(player_meta)


func _reset_chat_draft() -> void:
	native_close_requested.emit(true)
	if chat_text_field.has_method("reset_draft"):
		chat_text_field.call("reset_draft")
	else:
		chat_text_field.clear()

func clear_chat():
	_invalidate_chat_callbacks()
	_selection_history_dirty = true
	dismiss_chat_popups()
	close_chat_input()
	_reset_chat_draft()
	_pending_global_chat_text = ""
	for item in chat_vbox.get_children():
		chat_vbox.remove_child(item)
		item.queue_free()
	chat_selection.call("reset_selection")
	_message_records.clear()
	_message_layouts.clear()
	_layout_is_history = false
	_transient_scroll_offset = 0.0
	_history_overflow = false
	_record_index_by_id.clear()
	_fade_tweens.clear()
	_follow_latest = true
	_saved_history_follow_latest = true
	_saved_history_anchor.clear()
	_pending_history_anchor.clear()
	chat_virtual_content.custom_minimum_size.y = 0.0
	_schedule_history_layout()
	global_chat_toggle.set_pressed_no_signal(false)
	_update_global_chat_toggle_icon()
	global_chat_toggle.clear_cooldown()


func _on_chat_field_text_changed(new_text: String) -> void:
	_refresh_touch_chat_placeholder()
	if chat_text_field.has_method("get_mentions"):
		return
	var limited_text := InputLimits.truncate_chat_message(new_text)
	if limited_text != new_text:
		var previous_caret := chat_text_field.caret_column
		chat_text_field.text = limited_text
		chat_text_field.caret_column = mini(previous_caret, limited_text.length())

func _chat_submission() -> Dictionary:
	if chat_text_field.has_method("get_submission"):
		return chat_text_field.call("get_submission")
	return {"text": InputLimits.truncate_chat_message(chat_text_field.text), "mentions": [], "revision": 0}


func _on_chat_field_text_submitted(_new_text: String) -> void:
	var submission := _chat_submission()
	var limited_text := str(submission.text)
	if not is_instance_valid(mp_connection):
		return
	var sent := false
	var is_global_chat := global_chat_toggle.button_pressed
	var mentions: Array = submission.mentions
	if is_global_chat:
		sent = mp_connection.send_global_chat(limited_text, 0, mentions)
	else:
		sent = mp_connection.send_room_chat(limited_text, 0, mentions)
	if not sent:
		return
	if is_global_chat and mp_connection.uses_authoritative_global_chat():
		# Keep the exact submitted draft visible until the server confirms that it
		# was accepted. A rejection or disconnect therefore cannot lose user text.
		_pending_global_chat_text = limited_text
		_pending_global_chat_mentions = mentions.duplicate(true)
		_pending_global_chat_revision = int(submission.revision)
		return
	if not is_global_chat and mp_connection.uses_authoritative_room_chat():
		_pending_room_chat_text = limited_text
		_pending_room_chat_mentions = mentions.duplicate(true)
		_pending_room_chat_revision = int(submission.revision)
		return
	_reset_chat_draft()
	close_chat_input()


func _on_global_chat_toggled(_toggled_on: bool) -> void:
	if chat_text_field.has_method("get_mentions"):
		chat_text_field.set("revision", int(chat_text_field.get("revision")) + 1)
		chat_text_field.set("content_revision", int(chat_text_field.get("content_revision")) + 1)
	_update_global_chat_toggle_icon()
	global_chat_toggle.queue_redraw()
	chat_input_row.set_visible(true)
	if not touch_chat:
		chat_text_field.grab_focus()
	_set_chat_open_state(true)
	_set_chat_interaction_enabled(true)
	_update_current_location_visibility()
	_refresh_multiplayer_status_ui()


func _update_global_chat_toggle_icon() -> void:
	global_chat_toggle.icon = _GLOBAL_CHAT_ICON
	if not is_instance_valid(_theme_text_runtime):
		return
	_theme_text_runtime.style_icon(
		global_chat_toggle, get_theme_source(), "",
		int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_STRONG)
		if global_chat_toggle.button_pressed
		else int(_WEBPAGE_THEME_TEXT_RUNTIME.ROLE_NORMAL),
		false, 20.0)
	global_chat_toggle.add_theme_stylebox_override(
		"pressed", _CHAT_TOGGLE_ON_STYLEBOX)
	global_chat_toggle.add_theme_stylebox_override(
		"hover_pressed", _CHAT_TOGGLE_ON_STYLEBOX)
	_refresh_chat_field_theme_role()


func close_chat_input() -> void:
	if bool(chat_text_field.get("external_editing")):
		native_close_requested.emit(false)
		return
	chat_input_row.set_visible(false)
	chat_text_field.release_focus()
	_set_chat_open_state(false)
	_set_chat_interaction_enabled(false)
	_update_current_location_visibility()
	_refresh_multiplayer_status_ui()


func reveal_chat() -> void:
	if not chat_enabled:
		return
	chat_input_row.show()
	_set_chat_open_state(true)
	_set_chat_interaction_enabled(true)
	_update_current_location_visibility()
	_refresh_multiplayer_status_ui()


func dismiss_chat_popups() -> void:
	for popup in [_player_context_menu, _player_list_popup, _nametag_style_popup]:
		if is_instance_valid(popup):
			popup.dismiss()


func handle_touch_back() -> bool:
	if is_instance_valid(_player_list_popup) and _player_list_popup.visible:
		return _player_list_popup.handle_touch_back()
	if is_instance_valid(_player_context_menu) and _player_context_menu.handle_touch_back():
		return true
	if is_instance_valid(_nametag_style_popup) and _nametag_style_popup.visible:
		_nametag_style_popup.dismiss()
		return true
	if is_chat_open():
		close_chat_input()
		return true
	return false


func has_touch_modal() -> bool:
	return (is_instance_valid(_player_list_popup) and _player_list_popup.visible) \
		or (is_instance_valid(_nametag_style_popup) and _nametag_style_popup.visible) \
		or (is_instance_valid(_player_context_menu) and _player_context_menu.has_touch_modal())


func open_touch_history_menu(position: Vector2) -> void:
	var player_meta := _find_visual_player_meta_at(chat_vbox, position)
	if player_meta.is_empty():
		_player_context_menu.open_text_menu(position)
	else:
		_player_context_menu.open_player_menu(player_meta, position)


func _on_player_list_pressed() -> void:
	if not is_instance_valid(_player_list_popup) or not is_instance_valid(mp_connection):
		return
	if _suppress_player_list_open_on_release:
		_suppress_player_list_open_on_release = false
		_refresh_player_list_button_style()
		return
	if _player_list_popup.visible:
		_player_list_popup.dismiss()
		_refresh_player_list_button_style()
		return
	if is_instance_valid(_nametag_style_popup):
		_nametag_style_popup.dismiss()
	_player_list_popup.set_location_runtime(_location_runtime)
	_player_list_popup.open_player_list()
	_refresh_player_list_button_style()


func _on_player_list_popup_hidden() -> void:
	var closed_by_player_list_button := (
		player_list_button.is_pressed()
		or (Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
			and player_list_button.get_global_rect().has_point(
				get_viewport().get_mouse_position())))
	if closed_by_player_list_button:
		_suppress_player_list_open_on_release = true
		_clear_player_list_release_suppression.call_deferred()
	_refresh_player_list_button_style()


func _on_nametag_style_pressed() -> void:
	if not is_instance_valid(_nametag_style_popup):
		return
	if _suppress_nametag_open_on_release:
		_suppress_nametag_open_on_release = false
		_refresh_nametag_style_button()
		return
	if _nametag_style_popup.visible:
		_nametag_style_popup.dismiss()
		_refresh_nametag_style_button()
		return
	if is_instance_valid(_player_list_popup):
		_player_list_popup.dismiss()
	_nametag_style_popup.set_multiplayer_connection(mp_connection)
	_nametag_style_popup.set_nametag_mode(_nametag_mode)
	_nametag_style_popup.open_popup()
	_refresh_nametag_style_button()


func _on_nametag_mode_selected(mode: int) -> void:
	set_nametag_mode(mode, true)


func _on_nametag_style_popup_hidden() -> void:
	var closed_by_nametag_button := (
		nametag_style_button.is_pressed()
		or (Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
			and nametag_style_button.get_global_rect().has_point(
				get_viewport().get_mouse_position())))
	if closed_by_nametag_button:
		_suppress_nametag_open_on_release = true
		_clear_nametag_release_suppression.call_deferred()
	_refresh_nametag_style_button()


func _clear_player_list_release_suppression() -> void:
	# Mouse outside-press dismissal can precede Button GUI handling; emulated
	# touch dismisses after it. Retain either marker until that button releases.
	if not player_list_button.is_pressed():
		_suppress_player_list_open_on_release = false


func _clear_nametag_release_suppression() -> void:
	if not nametag_style_button.is_pressed():
		_suppress_nametag_open_on_release = false


func prepare_for_shutdown() -> void:
	_set_chat_interaction_enabled(false)
	chat_input_row.set_visible(false)
	chat_text_field.release_focus()
	_set_chat_open_state(false)
	if is_instance_valid(_player_context_menu):
		_player_context_menu.dismiss()
	if is_instance_valid(_player_list_popup):
		_player_list_popup.dismiss()
	if is_instance_valid(_nametag_style_popup):
		_nametag_style_popup.dismiss()
	visible = false
	chat_overlay_layer.visible = false


func _on_player_list_received(_players: Array) -> void:
	var perf_start := ClientPerformance.begin()
	_on_player_list_received_measured(_players)
	ClientPerformance.end(&"chat.player_list_inclusive", perf_start)


func _on_player_list_received_measured(_players: Array) -> void:
	# List data itself is unrelated to historical chat. Roles have a delta signal.
	pass


func _on_admin_authentication_changed(
		authenticated: bool, _admin_id: String, _error: String) -> void:
	if is_instance_valid(mp_connection):
		mp_connection.request_player_list()
	if is_instance_valid(_player_list_popup):
		_player_list_popup.refresh_access()


func _refresh_context_menu_skins() -> void:
	# Each popup owns a two-layer System skin. Reapplying a full-window texture
	# here would scale the eight-pixel border after dynamic sizing.
	return
