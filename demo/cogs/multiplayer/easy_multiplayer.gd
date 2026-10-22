class_name EasyMultiplayer
extends Node

const InputLimits := preload("res://cogs/input_limits.gd")
const ResourceNameRules := preload("res://cogs/multiplayer/resource_name_rules.gd")
const SystemThemePaletteScript := preload("res://cogs/system_theme_palette.gd")
const ClientIdentityStoreScript := preload(
	"res://cogs/multiplayer/client_identity_store.gd")
const GLOBAL_CHAT_COOLDOWN_SECONDS := 2.0
const GLOBAL_CHAT_COOLDOWN_MSEC := 2000
const ROOM_CHAT_COOLDOWN_SECONDS := 2.0
const ROOM_CHAT_COOLDOWN_MSEC := 2000
const PRIVACY_COOLDOWN_SECONDS := 1.0
const PRIVACY_COOLDOWN_MSEC := 1000
const MANUAL_RECONNECT_COOLDOWN_SECONDS := 3.0
const MANUAL_RECONNECT_COOLDOWN_MSEC := 3000
const CONNECTION_ATTEMPT_TIMEOUT_MSEC := 10_000
const ROOM_OPERATION_TIMEOUT_MSEC := 70_000
const MAX_CONNECTION_ATTEMPTS := 4
const MAX_ROOM_ID := 2147483647
const MAX_COORDINATE := 2147483647
const MAX_REMOTE_PLAYERS := 2048
const PLAYER_TOMBSTONE_RESYNC_THRESHOLD := MAX_REMOTE_PLAYERS
const MAX_PLAYER_SYSTEM_THEME_HISTORY := MAX_REMOTE_PLAYERS * 2
const MAX_ADMIN_PID_HISTORY := MAX_REMOTE_PLAYERS * 2
const UNKNOWN_PLAYER_COUNT := -1
const PROTOCOL_WARNING_INTERVAL_MSEC := 5000
const RECONNECT_DELAY_SECONDS := 3.0
const MAX_ATTEMPT_SEQUENCE := 2147483647
const SESSION_REPLACED_CLOSE_CODE := 4001
const IDENTITY_REQUIRED_CLOSE_CODE := 4003
const IDENTITY_INVALID_CLOSE_CODE := 4004
const CAPABILITY_PRESENCE := "presence1"
const CAPABILITY_GLOBAL_CHAT_ACK := "gchat_ack1"
const CAPABILITY_ROOM_CHAT_ACK := "chat_ack1"
const CAPABILITY_ROOM_BARRIER := "room_barrier1"
const CAPABILITY_SESSION_RESUME := "session_resume1"
const CAPABILITY_INSTALL_IDENTITY := "install_identity1"
const CAPABILITY_PRIVACY := "privacy1"
const CAPABILITY_ADMIN := "admin3"
const CAPABILITY_CHAT_METADATA := "chat_meta1"
const CAPABILITY_CHAT_MENTIONS := "chat_mentions1"
const CAPABILITY_CHAT_SNAPSHOT := "chat_snapshot1"
const CAPABILITY_UNNAMED_CHAT := "unnamed_chat1"
const ChatMentions := preload("res://cogs/chat_mentions.gd")
const CAPABILITY_MODERATION := "moderation3"
const CAPABILITY_PLAYER_LIST := "player_list1"
const CAPABILITY_LIST_QUERY := "list_query1"
const LIST_QUERY_IDLE_MSEC := 10000
const LIST_QUERY_TOTAL_MSEC := 60000
const CAPABILITY_SYSTEM_THEME := "system_theme1"
const CAPABILITY_SYSTEM_THEME_SYNC := "system_theme2"
const _SYSTEM_COLOR_CELL_SIZE := 16
const _SYSTEM_COLOR_SAMPLE_X := 0
const _SYSTEM_COLOR_SAMPLE_Y := 8
const _SYSTEM_COLOR_TABLE_Y := 48
const _SYSTEM_COLOR_NORMAL := 0
const _SYSTEM_COLOR_MUTED := 3
const _SYSTEM_COLOR_STRONG := 1

const _PRIVACY_BLOCKED_PACKETS := {
	"d": true, "m": true, "jmp": true, "f": true, "spd": true,
	"spr": true, "fl": true, "rfl": true, "rrfl": true, "tr": true,
	"h": true, "sys": true, "sys2": true, "se": true, "name": true, "chat": true,
	"chat2": true, "chat3": true, "gchat": true, "gchat2": true, "gchat3": true,
	"gchat4": true, "gchat5": true, "chat4": true, "chat5": true, "gchat6": true, "c": true,
	"plist_begin": true, "plist_item": true, "plist_item2": true, "plist_end": true,
}

enum ConnectionState {
	DISCONNECTED,
	CONNECTING,
	CONNECTED,
}

signal global_chat_cooldown_started(duration_seconds: float)
signal global_chat_submission_pending()
signal global_chat_accepted(duration_seconds: float)
signal global_chat_rejected(remaining_seconds: float)
signal global_chat_server_ready_changed(ready: bool)
signal room_chat_cooldown_started(duration_seconds: float)
signal room_chat_submission_pending()
signal room_chat_accepted(duration_seconds: float)
signal room_chat_rejected(remaining_seconds: float)
signal room_chat_server_ready_changed(ready: bool)
signal current_map_changed(map_id: int)
signal connection_state_changed(state: ConnectionState)
signal room_ready_changed(ready: bool)
signal presence_changed(total_count: int, room_count: int, room_id: int)
signal resume_state_changed(token: String, attempt_sequence: int)
signal admin_credential_accepted()
signal privacy_state_changed(
	desired_enabled: bool,
	authoritative_enabled: bool,
	transition_pending: bool
)
signal privacy_cooldown_started(duration_seconds: float)
signal privacy_server_ready_changed(ready: bool)
signal reconnect_cooldown_started(duration_seconds: float)
signal reconnect_ready_changed(ready: bool)
signal admin_authentication_changed(authenticated: bool, admin_id: String, error: String)
signal admin_roster_received(players: Array)
signal admin_bans_received(bans: Array)
signal admin_action_result(
	request_id: int, action: String, success: bool, code: String, detail: String)
signal server_notice_received(kind: String, text: String)
signal moderation_status_changed(muted_until: int, banned_until: int)
signal local_menu_theme_changed(colors: Dictionary)
signal player_list_received(players: Array)
signal list_query_failed(kind: String, request_id: int, code: String)
signal player_roles_changed(pids: Array[int])
signal player_profile_sprite_changed(pid: int, sprite_name: String, sprite_index: int)

@export var server_url: String = "ws://127.0.0.1:42424"
@export var engine: NodePath
@export var chat_ctrl: Control

@export var player_name: String = ""

@export var enable_sounds: bool = true
@export var enable_chat: bool = false
@export var mute_audio: bool = false
@export var moving_queue_limit: int = 4

var _conn: EasyConnection = null
var _engine: Node = null

var _room_id: int = -1
var _current_map_id: int = 0
var _previous_map_id: int = 0
var _location_runtime: Node = null
var _my_pid: int = -1
var _my_public_chat_id := ""
var _chat_public_profiles: Dictionary = {}
var _session_active: bool = false
var _session_connected: bool = false
var _server_global_vars_active: bool = false
var _switching_room: bool = true
var _switched_room: bool = false
var _reconnecting: bool = false
var _reconnect_waiting: bool = false
var _reconnect_wait_nonce: int = 0
var _connection_generation: int = 0
var _active_socket_generation: int = 0
var _socket_epoch: int = 0
var _connection_state: ConnectionState = ConnectionState.DISCONNECTED
var _last_disconnect_reason: String = ""
var _room_ready: bool = false
var _global_chat_ready_at_msec: int = 0
var _global_chat_duration_msec: int = 0
var _global_chat_pending: bool = false
var _server_global_chat_raw_ready: bool = false
var _global_chat_server_ready: bool = false
var _room_chat_ready_at_msec: int = 0
var _room_chat_duration_msec: int = 0
var _room_chat_pending: bool = false
var _server_room_chat_raw_ready: bool = false
var _room_chat_server_ready: bool = false
var _server_capabilities: Dictionary = {}
var _presence_revision: int = -1
var _total_player_count: int = UNKNOWN_PLAYER_COUNT
var _room_player_count: int = UNKNOWN_PLAYER_COUNT
var _presence_room_id: int = -1
var _protocol_warning_times: Dictionary = {}
var _protocol_warning_suppressed: Dictionary = {}
var _last_sent_previous_map_id: int = -1
var _resume_token: String = ""
var _resume_attempt_sequence: int = 0
var _active_attempt_sequence: int = 0
var _accepted_attempt_sequence: int = 0
var _resume_handshake_pending: bool = false
var _server_hello_received: bool = false
var _installation_secret: PackedByteArray = PackedByteArray()
var _identity_persistence_ready: bool = false
var _identity_challenge_pending: bool = false
var _identity_response_pending: bool = false
var _identity_handshake_accepted: bool = false
var _privacy_desired: bool = false
var _privacy_authoritative: bool = false
var _privacy_transition_pending: bool = false
var _privacy_request_in_flight: bool = false
var _privacy_sequence: int = 0
var _privacy_pending_sequence: int = 0
var _privacy_ready_at_msec: int = 0
var _privacy_server_ready: bool = false
var _privacy_room_join_queued_sequence: int = 0
var _cu_player_count_seen: bool = false
var _manual_reconnect_ready_at_msec: int = 0
var _manual_reconnect_ready: bool = false
var _connection_attempts: int = 0
var _last_physical_open_msec: int = -1
var _application_resume_generation: int = -1
var _connection_stopped: bool = false
var _establishing_connection: bool = false
var _attempt_deadline_msec: int = 0
var _attempt_deadline_generation: int = -1
var _attempt_deadline_socket_epoch: int = -1
var _admin_credential: String = ""
var _admin_authenticated: bool = false
var _admin_id: String = ""
var _admin_request_sequence: int = 0
var _admin_roster_pending: Dictionary = {}
var _admin_roster_snapshot: Array = []
var _admin_bans_pending: Dictionary = {}
var _admin_punishments_snapshot: Array = []
var _admin_subject_by_pid_history: Dictionary = {}
var _admin_current_pid_by_subject: Dictionary = {}
var _list_queries: Dictionary = {}
var _plist_live_touches: Dictionary = {}
var _plist_skip_history := false
var _player_list_pending: Dictionary = {}
var _player_list_request_sequence: int = 0
var _known_admin_pids: Dictionary = {}
var _last_identity_request_msec: int = 0
const IDENTITY_REFRESH_MSEC := 5000
var _identity_snapshot_msec := -1
var _known_player_roles: Dictionary = {}
var _player_list_in_flight := 0
var _player_list_sent_msec := -1
var _moderation_server_unix: int = 0
var _moderation_synced_msec: int = 0
var _muted_until_unix: int = 0
var _banned_until_unix: int = 0
var _muted_duration_mode := "finite"
var _banned_duration_mode := "finite"

var _players: Dictionary = {}
var _player_system_themes: Dictionary = {}
var _pending_spawn: Array = []
var _pre_spawn_identity: Dictionary = {}
var _room_epoch: int = 0
var _disconnected_player_tombstones: Dictionary = {}
var _tombstone_resync_pending: bool = false

class OtherPlayer:
	var id: int = -1
	var display_name: String = ""
	var sprite_name: String = ""
	var sprite_index: int = 0
	var facing: int = 2 # DOWN (RPGMaker default)
	var speed: int = 4 # normal speed
	var transparency: int = 0
	var hidden: bool = false
	var system_name: String = ""
	var system_stretch: int = 1
	var x: int = 0
	var y: int = 0

# every sound from this list has a reduced distance attenuation
const _INST_SET: Dictionary = {
	"kalimba_c3": true, "kalimba_c#3": true, "kalimba_d3": true,
	"kalimba_d#3": true, "kalimba_e3": true, "kalimba_f3": true,
	"kalimba_f#3": true, "kalimba_g3": true, "kalimba_g#3": true,
	"kalimba_a3": true, "kalimba_a#3": true, "kalimba_b3": true,
	"kalimba_c4": true, "kalimba_c#4": true, "kalimba_d4": true,
	"kalimba_d#4": true, "kalimba_e4": true, "kalimba_f4": true,
	"kalimba_f#4": true, "kalimba_g4": true, "kalimba_g#4": true,
	"kalimba_a4": true, "kalimba_a#4": true, "kalimba_b4": true,
	"kalimba_c5": true, "kalimba_c#5": true, "kalimba_d5": true,
	"kalimba_d#5": true, "kalimba_e5": true,
}

var _sync_switches: Array = []
var _sync_vars: Array = []
var _sync_events: Array = []
var _sync_action_events: Array = []
var _sync_picture_names: Array = []
var _global_sync_pic_names: Array = []
var _global_sync_pic_pfx: Array = []
var _sync_battle_anim_ids: Array = []
var _sync_picture_cache: Dictionary = {}

var _frame_index: int = 0
var _last_flash_frame_index: int = -1
var _last_frame_flash: Array = []
var _repeating_flashes: Dictionary = {}

# local player state (from RPGMakerPlayer signals)
var _local_x: int = 0
var _local_y: int = 0
var _local_speed: int = 4
var _local_sprite_name: String = ""
var _local_sprite_index: int = 0
var _local_facing: int = 2
var _local_hidden: bool = false
var _local_transparency: int = 0
var _local_system_name: String = ""
var _local_system_stretch: int = 1
var _player_profile_texture_cache: Dictionary = {}
var _player_profile_cache_game_path := ""

func _ready() -> void:
	_initialize_client_identity()
	_conn = EasyConnection.new()
	_conn.connected.connect(_on_ws_connected)
	_conn.disconnected_with_reason.connect(_on_ws_disconnected_with_reason)
	_conn.packet_received.connect(_on_packet)
	_conn.transport_stalled.connect(_on_transport_stalled)
	_socket_epoch = _conn.get_socket_epoch()
	
	if engine:
		_engine = get_node(engine)
		if _engine:
			_wire_player_signals()
			Log.info("[EasyMultiplayer] wired to RPGMakerPlayer '%s'" % _engine.name)
		else:
			Log.error("[EasyMultiplayer] engine NodePath did not resolve: " + str(engine))


func _initialize_client_identity() -> void:
	if _installation_secret.size() == ClientIdentityStoreScript.SECRET_BYTES:
		_identity_persistence_ready = true
		return
	var identity_store := ClientIdentityStoreScript.new()
	if not identity_store.load_or_create():
		_identity_persistence_ready = false
		Log.error("[EasyMultiplayer] multiplayer disabled: %s" % identity_store.last_error)
		return
	_installation_secret = identity_store.get_instance_secret()
	_identity_persistence_ready = (
		_installation_secret.size() == ClientIdentityStoreScript.SECRET_BYTES)
	if not _identity_persistence_ready:
		Log.error("[EasyMultiplayer] multiplayer disabled: invalid local identity secret")


func set_installation_secret(secret: PackedByteArray) -> bool:
	if _session_active or secret.size() != ClientIdentityStoreScript.SECRET_BYTES:
		return false
	_installation_secret = secret.duplicate()
	_identity_persistence_ready = true
	return true


func set_admin_credential(credential: String) -> void:
	var normalized := credential
	if normalized.length() > 160:
		normalized = ""
	_admin_credential = normalized
	if _admin_credential.is_empty():
		if _conn != null and _conn.is_connected_to_server() and _admin_authenticated:
			_conn.send_packet("adm_logout")
		_set_admin_authentication(false, "", "")
	elif _session_connected:
		authenticate_admin()


func clear_admin_credential() -> void:
	set_admin_credential("")


func get_admin_credential() -> String:
	return _admin_credential


func authenticate_admin() -> bool:
	if (_conn == null or not _conn.is_connected_to_server() or not _session_connected
			or _admin_credential.is_empty()
			or not _server_capabilities.has(CAPABILITY_ADMIN)):
		return false
	_conn.send_packet("adm_auth", [_encode_admin_credential(_admin_credential)])
	return true


func _encode_admin_credential(credential: String) -> String:
	var encoded := Marshalls.raw_to_base64(credential.to_utf8_buffer())
	encoded = encoded.replace("+", "-").replace("/", "_")
	while encoded.ends_with("="):
		encoded = encoded.left(-1)
	return encoded


func is_admin_authenticated() -> bool:
	return _admin_authenticated


func get_admin_id() -> String:
	return _admin_id


func request_admin_roster() -> int:
	return _send_admin_query("adm_roster")


func request_admin_bans() -> int:
	return _send_admin_query("adm_bans")


func request_admin_context_snapshot() -> void:
	request_admin_roster()
	request_admin_bans()


func admin_mute(
		target_pid: int, duration_seconds: int, duration_mode: String = "finite",
		include_network: bool = false) -> int:
	return _send_admin_action(
		"mute", str(target_pid), duration_seconds, duration_mode, include_network)


func admin_unmute(target_pid: int) -> int:
	return _send_admin_action("unmute", str(target_pid), 0)


func admin_ban(
		target_pid: int, duration_seconds: int, duration_mode: String = "finite",
		include_network: bool = false) -> int:
	return _send_admin_action(
		"ban", str(target_pid), duration_seconds, duration_mode, include_network)


func admin_unban(ban_id: String) -> int:
	return _send_admin_action("unban", ban_id, 0)


func admin_revoke_punishment(punishment_id: String) -> int:
	return _send_admin_action("unban", punishment_id, 0)


func admin_change_punishment_duration(
		punishment_id: String, duration_seconds: int) -> int:
	var include_network := false
	for record_value in _admin_punishments_snapshot:
		var record := record_value as Dictionary
		if str(record.get("ban_id", "")) == punishment_id:
			include_network = str(record.get("scope", "installation")) in [
				"installation_network", "network"]
			break
	return admin_update_punishment(
		punishment_id, duration_seconds, "finite", include_network)


func admin_update_punishment(
		punishment_id: String, duration_seconds: int, duration_mode: String,
		include_network: bool) -> int:
	return _send_admin_action(
		"punishment_update", punishment_id, duration_seconds,
		duration_mode, include_network)


func admin_set_mute(
		target_pid: int, duration_seconds: int, duration_mode: String = "finite",
		include_network: bool = false) -> int:
	return _send_admin_action(
		"set_mute", str(target_pid), duration_seconds, duration_mode, include_network)


func admin_set_ban(
		target_pid: int, duration_seconds: int, duration_mode: String = "finite",
		include_network: bool = false) -> int:
	return _send_admin_action(
		"set_ban", str(target_pid), duration_seconds, duration_mode, include_network)


func admin_revoke_mute(target_pid: int) -> int:
	return _send_admin_action("revoke_mute", str(target_pid), 0)


func admin_revoke_ban_for_player(target_pid: int) -> int:
	return _send_admin_action("revoke_ban", str(target_pid), 0)


func get_admin_punishments_snapshot() -> Array:
	return _admin_punishments_snapshot.duplicate(true)


func get_admin_subject_group_for_pid(pid: int) -> String:
	if not _admin_subject_by_pid_history.has(pid):
		return ""
	var group_id := str(_admin_subject_by_pid_history[pid])
	_admin_subject_by_pid_history.erase(pid)
	_admin_subject_by_pid_history[pid] = group_id
	return group_id


func can_admin_target_use_network(player_meta: Dictionary) -> bool:
	return bool(get_admin_network_scope_state(player_meta).get("available", false))


func get_admin_network_scope_state(player_meta: Dictionary, record: Dictionary = {}) -> Dictionary:
	if not is_admin_authenticated():
		return {"available": false, "reason": "管理员认证已失效"}
	if _admin_roster_snapshot.is_empty():
		return {"available": false, "reason": "尚未取得管理员玩家列表，暂时无法确认IP处罚范围"}
	var network_label := ""
	var existing_network := str(record.get("scope", "installation")) in ["network", "installation_network"]
	if existing_network:
		# An existing record may still punish an older IP after its owner reconnects.
		network_label = str(record.get("network_label", ""))
	var original_pid := int(player_meta.get(
		"sender_id", player_meta.get("pid", player_meta.get("online_pid", 0))))
	var group_id := str(player_meta.get("subject_group_id", ""))
	var resolved_pid := resolve_admin_target_pid(original_pid, group_id)
	if not existing_network:
		for item_value in _admin_roster_snapshot:
			var item := item_value as Dictionary
			if int(item.get("pid", 0)) == resolved_pid:
				network_label = str(item.get("network_label", ""))
				break
	if network_label in ["", "unavailable"]:
		return {"available": false, "reason": "该玩家的IP不可用或当前不在线"}
	for item_value in _admin_roster_snapshot:
		var item := item_value as Dictionary
		if str(item.get("network_label", "")) == network_label and bool(item.get("is_admin", false)):
			return {"available": false, "reason": "该IP下有在线管理员，不能新增或延长IP处罚"}
	return {"available": true, "reason": ""}


func resolve_admin_target_pid(pid: int, subject_group_id: String = "") -> int:
	var group_id := subject_group_id
	if group_id.is_empty():
		group_id = get_admin_subject_group_for_pid(pid)
	if not group_id.is_empty():
		return int(_admin_current_pid_by_subject.get(group_id, 0))
	# A forgotten historical PID is not proof of a currently available target.
	# Keep direct actions for targets present in the authenticated roster.
	for item_value in _admin_roster_snapshot:
		var item := item_value as Dictionary
		if pid > 0 and int(item.get("pid", 0)) == pid:
			return pid
	return 0


func get_active_admin_punishment(player_meta: Dictionary, kind: String) -> Dictionary:
	if kind not in ["mute", "ban"]:
		return {}
	var original_pid := int(player_meta.get(
		"sender_id", player_meta.get("pid", player_meta.get("online_pid", 0))))
	var group_id := str(player_meta.get("subject_group_id", ""))
	if group_id.is_empty():
		group_id = get_admin_subject_group_for_pid(original_pid)
	var resolved_pid := resolve_admin_target_pid(original_pid, group_id)
	var now_unix := int(get_estimated_server_unix_msec() / 1000)
	var best: Dictionary = {}
	for value in _admin_punishments_snapshot:
		var record := value as Dictionary
		if (str(record.get("kind", "")) != kind
				or (str(record.get("duration_mode", "finite")) != "permanent"
					and int(record.get("expires_at", 0)) <= now_unix)):
			continue
		var record_group := str(record.get("subject_group_id", ""))
		var matches := not group_id.is_empty() and record_group == group_id
		if group_id.is_empty():
			var online_pid := int(record.get("online_pid", 0))
			matches = online_pid > 0 and online_pid == resolved_pid
		if (matches and (best.is_empty()
				or str(record.get("duration_mode", "finite")) == "permanent"
				or (str(best.get("duration_mode", "finite")) != "permanent"
					and int(record.get("expires_at", 0)) > int(best.get("expires_at", 0))))):
			best = record
	return best.duplicate(true) if not best.is_empty() else {}


func admin_announce(text: String) -> int:
	if text.length() > 100:
		return 0
	return _send_admin_action("announce", text, 0)


func admin_logout() -> void:
	if _conn != null and _conn.is_connected_to_server():
		_conn.send_packet("adm_logout")
	_set_admin_authentication(false, "", "")


func _send_admin_query(packet_name: String) -> int:
	if not _admin_authenticated or _conn == null or not _conn.is_connected_to_server():
		return 0
	var kind := packet_name.trim_prefix("adm_")
	if _list_queries.has(kind):
		return int(_list_queries[kind].id)
	var request_id := _next_admin_request_id()
	_begin_list_query(kind, request_id)
	_conn.send_packet(packet_name, [str(request_id)])
	return request_id


func _send_admin_action(
		action: String, subject: String, duration_seconds: int,
		duration_mode: String = "finite", include_network: bool = false) -> int:
	if (not _admin_authenticated or _conn == null or not _conn.is_connected_to_server()
			or duration_seconds < 0 or duration_mode not in ["finite", "permanent"]):
		return 0
	var request_id := _next_admin_request_id()
	_conn.send_packet("adm_act", [
		str(request_id), action, subject, str(duration_seconds), duration_mode,
		"1" if include_network else "0"])
	return request_id


func _next_admin_request_id() -> int:
	if _admin_request_sequence >= MAX_ATTEMPT_SEQUENCE:
		_admin_request_sequence = 0
	_admin_request_sequence += 1
	return _admin_request_sequence

func _process(_delta: float) -> void:
	# Android recovery applies only to this first normal network check. A healthy
	# socket must not leave a fast-retry allowance for an unrelated later failure.
	var resume_generation := _application_resume_generation
	_application_resume_generation = -1
	_refresh_current_map_id()
	# Map ID 0 represents the title/main-menu state. The socket is closed by
	# _suspend_for_map_zero(), and returning here ensures it cannot be polled or
	# dispatch an already-buffered packet in the transition frame.
	if _current_map_id == 0:
		return
	_check_attempt_deadline()
	if _conn:
		_conn.poll()
	_try_application_resume_reconnect(resume_generation)
	_check_list_query_deadlines(Time.get_ticks_msec())
	if _session_active:
		_update_frame()
	# cap/resume are connection-scoped handshake packets and must leave while
	# gameplay transmission is still gated on resume_ok.
	if _conn and _conn.is_connected_to_server():
		_conn.flush_queue()
	_retry_pending_spawns()
	_refresh_global_chat_server_ready()
	_refresh_privacy_server_ready()
	_refresh_reconnect_ready()

func connect_to_room(map_id: int, room_switch: bool = false) -> void:
	if map_id < 0 or map_id > MAX_ROOM_ID:
		Log.warn("[EasyMultiplayer] refused out-of-range room id: %d" % map_id)
		return
	Log.info("[EasyMultiplayer] connect_to_room id=%d room_switch=%s" % [map_id, str(room_switch)])
	var reuse_ready_socket := (_conn != null and _conn.is_connected_to_server()
		and _session_connected)
	_switching_room = true
	_set_room_ready(false)
	_set_current_map_id(map_id)
	_room_id = map_id
	if map_id == 0:
		_suspend_for_map_zero()
		return
	if _connection_stopped:
		return
	_session_active = true
	if not reuse_ready_socket:
		_set_connection_state(ConnectionState.CONNECTING)
	if room_switch:
		_switched_room = false
		_set_room_presence_unknown()
	if reuse_ready_socket and _privacy_blocks_public_data():
		# An in-flight privacy request is independent of the room target and must
		# retain its position as a transport barrier. Only payload queued for the
		# previous room becomes stale in that case; a steady private room switch can
		# discard and replace its old sr barrier as usual.
		if _privacy_request_in_flight:
			_on_chat_queue_discarded(_conn.clear_room_payload_queue())
		else:
			_on_chat_queue_discarded(_conn.clear_room_queue())
		# An accepted privacy target may already have queued a join for the old
		# room. Allow the current target to replace it below.
		if _privacy_transition_pending and not _privacy_request_in_flight:
			_privacy_room_join_queued_sequence = 0
		_begin_privacy_room_epoch()
	else:
		_initialize(false)
	
	if _engine and _engine.is_running():
		_engine.mp_set_session_active(true)
		_engine.mp_set_room_id(map_id)
	
	if _conn.is_connected_to_server():
		if not reuse_ready_socket:
			Log.debug("[EasyMultiplayer] room target updated during connection handshake")
			return
		Log.debug("[EasyMultiplayer] already connected — queuing room join state")
		# Refresh local state without allowing callbacks to precede the new room
		# barrier. Public initialization has already gated them; a steady private
		# room switch needs the same short synchronous gate here.
		_refresh_local_player_snapshot_without_sending()
		_set_session_connected(true)
		if _privacy_request_in_flight:
			Log.debug("[EasyMultiplayer] privacy transition already owns the room join")
		elif _privacy_transition_pending:
			_queue_room_join_after_privacy_accept(_privacy_pending_sequence)
		elif _privacy_authoritative:
			_send_private_room_join_state()
		else:
			_send_room_join_state()
	else:
		if _reconnect_waiting:
			Log.debug("[EasyMultiplayer] room target updated during reconnect backoff")
			return
		if (_connection_state == ConnectionState.CONNECTING
				and _active_socket_generation == _connection_generation):
			Log.debug("[EasyMultiplayer] physical connection attempt already in progress")
			return
		_start_physical_connection()


func notify_application_resumed() -> void:
	# Called only by the Android lifecycle adapter, not ordinary focus changes.
	if _conn != null and _session_active and not _connection_stopped and _current_map_id != 0:
		_application_resume_generation = _connection_generation


func _try_application_resume_reconnect(resume_generation: int) -> void:
	if (resume_generation < 0 or resume_generation != _connection_generation
			or _conn == null or not _session_active or _connection_stopped
			or _current_map_id == 0 or not _reconnect_waiting
			or _connection_attempts != 0 or _last_physical_open_msec < 0):
		return
	# A completed session resets attempts to zero; the first new open consumes
	# that allowance. Repeated pause/resume cannot accelerate later failures.
	if Time.get_ticks_msec() - _last_physical_open_msec < int(RECONNECT_DELAY_SECONDS * 1000.0):
		return
	Log.info("[EasyMultiplayer] application resume skips the first reconnect wait")
	_cancel_reconnect_wait()
	_start_physical_connection()


func request_reconnect() -> bool:
	if not can_request_reconnect():
		return false
	_start_manual_reconnect_cooldown()
	_connection_attempts = 0
	_connection_stopped = false
	if _reconnect_waiting:
		Log.info("[EasyMultiplayer] manual reconnect skips the pending backoff")
		_cancel_reconnect_wait()
		_reconnecting = true
		_start_physical_connection()
		return true
	Log.info("[EasyMultiplayer] manual reconnect requested")
	if not _session_active:
		_session_active = true
		if _engine and _engine.is_running():
			_engine.mp_set_session_active(true)
	_reconnecting = true
	_set_connection_state(ConnectionState.CONNECTING)
	_switching_room = true
	_initialize(true)
	_reset_socket_protocol_state()
	_conn.close()
	_socket_epoch = _conn.get_socket_epoch()
	_start_physical_connection()
	return true


func can_request_reconnect() -> bool:
	if (_current_map_id == 0 or _conn == null
			or manual_reconnect_cooldown_remaining() > 0.0):
		return false
	if _reconnect_waiting or is_legacy_privacy_hold():
		return true
	if not _session_active:
		return _connection_state == ConnectionState.DISCONNECTED
	# Repeated requests while a physical socket, resume negotiation, privacy
	# transition, or room barrier is already in flight belong to that attempt.
	return not (_connection_state == ConnectionState.CONNECTING or _reconnecting
		or _switching_room or not _session_connected)


func manual_reconnect_cooldown_remaining() -> float:
	var remaining := _manual_reconnect_ready_at_msec - Time.get_ticks_msec()
	return maxf(0.0, float(remaining) / 1000.0)


static func normalize_server_endpoint(value: String) -> String:
	var raw := value.strip_edges()
	var scheme_separator := raw.find("://")
	if scheme_separator <= 0:
		return ""
	var scheme := raw.left(scheme_separator).to_lower()
	if scheme not in ["ws", "wss"]:
		return ""
	var remainder := raw.substr(scheme_separator + 3)
	if (remainder.is_empty() or remainder.find("?") >= 0
			or remainder.find("#") >= 0 or remainder.find("@") >= 0):
		return ""
	var path_start := remainder.find("/")
	var authority := remainder if path_start < 0 else remainder.left(path_start)
	var path := "" if path_start < 0 else remainder.substr(path_start)
	if authority.is_empty():
		return ""

	var host := authority
	var port := -1
	if authority.begins_with("["):
		var closing_bracket := authority.find("]")
		if closing_bracket <= 1:
			return ""
		host = authority.substr(0, closing_bracket + 1).to_lower()
		var suffix := authority.substr(closing_bracket + 1)
		if not suffix.is_empty():
			if not suffix.begins_with(":") or not suffix.substr(1).is_valid_int():
				return ""
			port = int(suffix.substr(1))
			if port < 1 or port > 65535:
				return ""
	elif authority.count(":") == 1:
		var colon := authority.rfind(":")
		var port_text := authority.substr(colon + 1)
		if port_text.is_empty() or not port_text.is_valid_int():
			return ""
		host = authority.left(colon).to_lower()
		port = int(port_text)
		if port < 1 or port > 65535:
			return ""
	elif authority.count(":") > 1:
		return ""
	else:
		host = authority.to_lower()
	if host.is_empty():
		return ""
	if (scheme == "ws" and port == 80) or (scheme == "wss" and port == 443):
		port = -1
	while path.ends_with("/"):
		path = path.left(-1)
	var normalized_authority := host
	if port > 0:
		normalized_authority += ":%d" % port
	return "%s://%s%s" % [scheme, normalized_authority, path]


static func build_room_url(endpoint: String, room_id: int) -> String:
	var normalized := normalize_server_endpoint(endpoint)
	if normalized.is_empty():
		return ""
	return normalized + "/room?id=" + str(room_id)


func set_resume_state(token: String, attempt_sequence: int = 0) -> void:
	var normalized_token := token.to_lower()
	if not normalized_token.is_empty() and not _is_valid_resume_token(normalized_token):
		Log.warn("[EasyMultiplayer] discarded invalid persisted resume token")
		normalized_token = ""
	if attempt_sequence < 0 or attempt_sequence > MAX_ATTEMPT_SEQUENCE:
		Log.warn("[EasyMultiplayer] reset invalid persisted resume attempt sequence")
		attempt_sequence = 0
	_set_resume_state_internal(normalized_token, attempt_sequence, false)


func get_resume_state() -> Dictionary:
	return {
		"token": _resume_token,
		"attempt_sequence": _resume_attempt_sequence,
	}

func quit() -> void:
	Log.info("[EasyMultiplayer] quit")
	_invalidate_connection_attempt()
	_session_active = false
	_reconnecting = false
	if _engine and _engine.is_running():
		_engine.mp_set_session_active(false)
	if _conn:
		_conn.close()
		_socket_epoch = _conn.get_socket_epoch()
	_reset_socket_protocol_state()
	_set_connection_state(ConnectionState.DISCONNECTED)
	_initialize(true)

func set_enable_chat(on: bool) -> void:
	enable_chat = on
	_refresh_global_chat_server_ready()
	if not _session_connected:
		return
	_conn.send_packet("chaton", ["1" if enable_chat and not _privacy_blocks_public_data() else "0"])


func _on_chat_queue_discarded(channels: Array[String]) -> void:
	# Sent items have left EasyConnection's queue and keep awaiting their ACK.
	if channels.has("global"):
		_global_chat_pending = false
		_global_chat_ready_at_msec = 0
		_refresh_global_chat_server_ready()
		global_chat_rejected.emit(0.0)
	if channels.has("room"):
		_room_chat_pending = false
		_room_chat_ready_at_msec = 0
		_refresh_room_chat_server_ready()
		room_chat_rejected.emit(0.0)


func send_room_chat(text: String, mention_target_pid: int = 0, mentions: Array = []) -> bool:
	if (_current_map_id == 0 or not _session_connected or _switching_room
			or not enable_chat or _privacy_blocks_public_data()):
		return false
	if not is_room_chat_server_ready():
		return false
	var limited_text := ChatMentions.normalize_text(text)
	if limited_text.strip_edges().is_empty():
		return false
	if not ChatMentions.valid_spans(limited_text, mentions) or (not mentions.is_empty() and not supports_chat_mentions()):
		return false
	if not mentions.is_empty() and (text != limited_text or (ChatMentions.has_unnamed(limited_text, mentions) and not supports_unnamed_chat())):
		return false
	if supports_chat_mentions():
		_conn.send_packet("chatx", [limited_text] + ChatMentions.encode(mentions))
	elif _server_capabilities.has(CAPABILITY_CHAT_METADATA):
		_conn.send_packet("chatm", [limited_text, str(maxi(0, mention_target_pid))])
	else:
		_conn.send_packet("chat", [limited_text])
	if _server_capabilities.has(CAPABILITY_ROOM_CHAT_ACK):
		_room_chat_pending = true
		_refresh_room_chat_server_ready()
		room_chat_submission_pending.emit()
	else:
		# Without acknowledgements, use the client policy and immediate submission.
		_room_chat_ready_at_msec = Time.get_ticks_msec() + ROOM_CHAT_COOLDOWN_MSEC
		_room_chat_duration_msec = ROOM_CHAT_COOLDOWN_MSEC
		_refresh_room_chat_server_ready()
		room_chat_cooldown_started.emit(ROOM_CHAT_COOLDOWN_SECONDS)
	return true


func send_global_chat(text: String, mention_target_pid: int = 0, mentions: Array = []) -> bool:
	if (_current_map_id == 0 or not _session_connected or _switching_room
			or not enable_chat or _privacy_blocks_public_data()):
		return false
	if not is_global_chat_server_ready():
		return false
	var limited_text := ChatMentions.normalize_text(text)
	if limited_text.strip_edges().is_empty():
		return false
	if not ChatMentions.valid_spans(limited_text, mentions) or (not mentions.is_empty() and not supports_chat_mentions()):
		return false
	if not mentions.is_empty() and (text != limited_text or (ChatMentions.has_unnamed(limited_text, mentions) and not supports_unnamed_chat())):
		return false
	if supports_chat_mentions():
		_conn.send_packet("gchatx", [limited_text] + ChatMentions.encode(mentions))
	elif _server_capabilities.has(CAPABILITY_CHAT_METADATA):
		_conn.send_packet("gchatm", [limited_text, str(maxi(0, mention_target_pid))])
	else:
		_conn.send_packet("gchat", [limited_text])
	if _server_capabilities.has(CAPABILITY_GLOBAL_CHAT_ACK):
		_global_chat_pending = true
		_refresh_global_chat_server_ready()
		global_chat_submission_pending.emit()
	else:
		# Without acknowledgements, use the client policy and immediate submission.
		_global_chat_ready_at_msec = Time.get_ticks_msec() + GLOBAL_CHAT_COOLDOWN_MSEC
		_global_chat_duration_msec = GLOBAL_CHAT_COOLDOWN_MSEC
		_refresh_global_chat_server_ready()
		global_chat_cooldown_started.emit(GLOBAL_CHAT_COOLDOWN_SECONDS)
	return true


func get_my_pid() -> int:
	return _my_pid


func supports_chat_mentions() -> bool:
	return _session_connected and _server_capabilities.has(CAPABILITY_CHAT_MENTIONS) and ChatMentions.valid_id(_my_public_chat_id)


func supports_unnamed_chat() -> bool:
	return (_server_capabilities.has(CAPABILITY_UNNAMED_CHAT)
		and _server_capabilities.has(CAPABILITY_CHAT_SNAPSHOT)
		and _server_capabilities.has(CAPABILITY_CHAT_MENTIONS))


func _chat_sender_name_allowed(raw_name: String) -> bool:
	return supports_unnamed_chat() if raw_name.is_empty() else not InputLimits.sanitize_nickname(raw_name).is_empty()


func get_chat_mention_target(meta: Dictionary) -> Dictionary:
	if not supports_chat_mentions():
		return {}
	var public_id := str(meta.get("public_chat_id", ""))
	if public_id.is_empty():
		var pid := int(meta.get("sender_id", meta.get("pid", 0)))
		for profile in _chat_public_profiles.values():
			if int(profile.get("sender_id", 0)) == pid:
				public_id = str(profile.public_chat_id)
				break
	if not ChatMentions.valid_id(public_id):
		return {}
	var result: Dictionary = _chat_public_profiles.get(public_id, meta).duplicate(true)
	if str(result.get("display_name", "")).is_empty() and not supports_unnamed_chat():
		return {}
	result["public_chat_id"] = public_id
	return result


func _remember_chat_profile(public_id: String, pid: int, display_name: String, from_list: bool = false) -> void:
	if not ChatMentions.valid_id(public_id):
		return
	if not from_list:
		_touch_list_history("profile_pid:" + str(pid))
		_touch_list_history("profile:" + public_id)
	_chat_public_profiles.erase(public_id)
	_chat_public_profiles[public_id] = {"public_chat_id": public_id, "sender_id": pid, "display_name": display_name}
	while _chat_public_profiles.size() > MAX_PLAYER_SYSTEM_THEME_HISTORY:
		_chat_public_profiles.erase(_chat_public_profiles.keys()[0])


func supports_player_list() -> bool:
	return _server_capabilities.has(CAPABILITY_PLAYER_LIST)


func request_player_list() -> int:
	if (_conn == null or not _conn.is_connected_to_server() or not _session_connected
			or _privacy_blocks_public_data()
			or not _server_capabilities.has(CAPABILITY_PLAYER_LIST)):
		return 0
	var now := Time.get_ticks_msec()
	if _list_queries.has("plist"):
		ClientPerformance.count_event(&"identity.requests_coalesced")
		return _player_list_in_flight
	_player_list_pending.clear()
	_player_list_request_sequence = (_player_list_request_sequence % MAX_ATTEMPT_SEQUENCE) + 1
	var request_id := _player_list_request_sequence
	_player_list_in_flight = request_id
	_player_list_sent_msec = now
	_begin_list_query("plist", request_id)
	_conn.send_packet("plist", [str(request_id)])
	ClientPerformance.count_event(&"identity.requests")
	return request_id


func _begin_list_query(kind: String, request_id: int) -> void:
	var now := Time.get_ticks_msec()
	_list_queries[kind] = {"id": request_id, "started": now, "progress": now,
		"began": false, "refresh": false}


func _list_query_progress(kind: String, request_id: int, beginning: bool = false) -> bool:
	if not _list_queries.has(kind):
		return false
	var query: Dictionary = _list_queries[kind]
	if int(query.id) != request_id or (beginning and bool(query.began)):
		return false
	if not beginning and not bool(query.began):
		return false
	query.began = true
	query.progress = Time.get_ticks_msec()
	return true


func _finish_list_query(kind: String, success: bool = false) -> void:
	var refresh := success and bool(_list_queries.get(kind, {}).get("refresh", false))
	_list_queries.erase(kind)
	match kind:
		"plist":
			_player_list_pending.clear()
			_player_list_in_flight = 0
			_player_list_sent_msec = -1
			_plist_live_touches.clear()
			_plist_skip_history = false
		"roster": _admin_roster_pending.clear()
		"bans": _admin_bans_pending.clear()
	if refresh:
		_refresh_list_query.call_deferred(kind)


func _refresh_list_query(kind: String) -> void:
	match kind:
		"plist": request_player_list()
		"roster": request_admin_roster()
		"bans": request_admin_bans()


func _fail_list_query(kind: String, request_id: int, code: String) -> void:
	if int(_list_queries.get(kind, {}).get("id", 0)) != request_id or request_id <= 0:
		return
	_finish_list_query(kind)
	list_query_failed.emit(kind, request_id, code)


func _cancel_list_queries() -> void:
	for kind in ["plist", "roster", "bans"]:
		_finish_list_query(kind)
	_identity_snapshot_msec = -1
	_last_identity_request_msec = -IDENTITY_REFRESH_MSEC


func _check_list_query_deadlines(now: int) -> void:
	for kind in _list_queries.keys():
		var query: Dictionary = _list_queries[kind]
		if (now - int(query.progress) >= LIST_QUERY_IDLE_MSEC
				or now - int(query.started) >= LIST_QUERY_TOTAL_MSEC):
			_fail_list_query(kind, int(query.id), "timeout")


func _touch_list_history(key: String) -> void:
	if _player_list_pending.is_empty() or _plist_skip_history or _plist_live_touches.has(key):
		return
	if _plist_live_touches.size() >= MAX_PLAYER_SYSTEM_THEME_HISTORY:
		_plist_skip_history = true
		_plist_live_touches.clear()
		return
	_plist_live_touches[key] = true


func _plist_can_fill_history(keys: Array) -> bool:
	if _plist_skip_history:
		return false
	for key in keys:
		if _plist_live_touches.has(key):
			return false
	return true


func is_player_admin(pid: int) -> bool:
	return _known_admin_pids.has(pid)


func render_player_nickname(
		text: String, system_name: String, max_width: int = 512) -> Dictionary:
	return render_menu_text(text, system_name, 0, max_width)


func render_menu_text(
		text: String,
		system_name: String = "",
		color_index: int = 0,
		max_width: int = 512) -> Dictionary:
	if (_engine == null or not _engine.is_running()
			or not _engine.has_method("render_game_text_with_system")):
		return {}
	var resolved_system := system_name if not system_name.is_empty() else _local_system_name
	if resolved_system.is_empty() and color_index == 0 and _engine.has_method("render_current_game_text"):
		var current_rendered: Variant = _engine.call(
			"render_current_game_text", text, max_width)
		return current_rendered if current_rendered is Dictionary else {}
	var rendered: Variant = _engine.call(
		"render_game_text_with_system", text, resolved_system, max_width, color_index)
	return rendered if rendered is Dictionary else {}


func get_menu_system_texture(system_name: String = "") -> Texture2D:
	if (_engine == null or not _engine.is_running()
			or not _engine.has_method("get_system_texture")):
		return null
	return _engine.call("get_system_texture", system_name) as Texture2D


func render_menu_window(
		system_name: String, width: int, height: int, stretch_mode: int = -1) -> Texture2D:
	if (_engine == null or not _engine.is_running()
			or not _engine.has_method("render_game_window_with_system")):
		return null
	var resolved_stretch := _local_system_stretch if stretch_mode < 0 else clampi(stretch_mode, 0, 1)
	return _engine.call(
		"render_game_window_with_system", system_name, width, height, resolved_stretch) as Texture2D


func render_player_avatar(sprite_name: String, sprite_index: int, facing: int) -> Texture2D:
	if (_engine == null or not _engine.is_running()
			or not _engine.has_method("render_character_avatar")):
		return null
	return _engine.call(
		"render_character_avatar", sprite_name, sprite_index, facing) as Texture2D


func render_player_profile(sprite_name: String, sprite_index: int) -> Texture2D:
	if (_engine == null or not _engine.is_running()
			or not _engine.has_method("render_character_profile")
			or sprite_name.is_empty()):
		return null
	var game_path := str(_engine.call("get_game_path"))
	if game_path != _player_profile_cache_game_path:
		_player_profile_texture_cache.clear()
		_player_profile_cache_game_path = game_path
	var cache_key := "%s\u001f%d" % [sprite_name, sprite_index]
	if _player_profile_texture_cache.has(cache_key):
		return _player_profile_texture_cache[cache_key] as Texture2D
	var texture := _engine.call(
		"render_character_profile", sprite_name, sprite_index) as Texture2D
	if texture != null:
		_player_profile_texture_cache[cache_key] = texture
	return texture


func get_player_sprite_snapshot(pid: int) -> Dictionary:
	if pid == _my_pid:
		return {
			"sprite_name": _local_sprite_name,
			"sprite_index": _local_sprite_index,
		}
	if not _players.has(pid):
		return {}
	var player = _players[pid]
	return {
		"sprite_name": str(player.sprite_name),
		"sprite_index": int(player.sprite_index),
	}


func get_local_player_snapshot() -> Dictionary:
	return {
		"public_chat_id": _my_public_chat_id,
		"pid": _my_pid, "display_name": player_name, "room_id": _current_map_id,
		"sprite_name": _local_sprite_name, "sprite_index": _local_sprite_index,
		"facing": _local_facing, "system_name": _local_system_name,
		"system_stretch": _local_system_stretch,
	}


func get_player_system_stretch(pid: int, system_name: String) -> int:
	if pid == _my_pid:
		return _local_system_stretch if system_name == _local_system_name else 1
	if _player_system_themes.has(pid):
		var theme := _player_system_themes[pid] as Dictionary
		if str(theme.get("system_name", "")) == system_name:
			_player_system_themes.erase(pid)
			_player_system_themes[pid] = theme
			return clampi(int(theme.get("system_stretch", 1)), 0, 1)
	if _players.has(pid):
		var player := _players[pid] as OtherPlayer
		if player.system_name == system_name:
			return clampi(player.system_stretch, 0, 1)
	return 1


func get_menu_theme_colors(system_name: String) -> Dictionary:
	if system_name.is_empty():
		return get_current_menu_theme_colors()
	if (_engine == null or not _engine.is_running()
			or not _engine.has_method("get_system_texture")):
		return {}
	var raw_texture: Variant = _engine.call("get_system_texture", system_name)
	if not raw_texture is Texture2D:
		return {}
	var image := (raw_texture as Texture2D).get_image()
	if image == null or image.is_empty():
		return {}
	return SystemThemePaletteScript.colors_from_image(image)


func get_current_menu_theme_colors() -> Dictionary:
	if (_engine == null or not _engine.is_running()
			or not _engine.has_method("get_current_system_texture")):
		return {}
	var raw_texture: Variant = _engine.call("get_current_system_texture")
	if not raw_texture is Texture2D:
		return {}
	var image := (raw_texture as Texture2D).get_image()
	if image == null or image.is_empty():
		return {}
	return SystemThemePaletteScript.colors_from_image(image)


func _sample_system_menu_color(image: Image, color_index: int) -> Color:
	var position := _system_color_sample_position(color_index)
	var color := image.get_pixel(position.x, position.y)
	color.a = 1.0
	return color


func _system_color_sample_position(color_index: int) -> Vector2i:
	return Vector2i(
		(color_index % 10) * _SYSTEM_COLOR_CELL_SIZE + _SYSTEM_COLOR_SAMPLE_X,
		int(color_index / 10) * _SYSTEM_COLOR_CELL_SIZE
			+ _SYSTEM_COLOR_TABLE_Y + _SYSTEM_COLOR_SAMPLE_Y)


func chat_cooldown_snapshot(global_channel: bool) -> Array[int]:
	if global_channel:
		return [_global_chat_ready_at_msec, _global_chat_duration_msec]
	return [_room_chat_ready_at_msec, _room_chat_duration_msec]


func global_chat_cooldown_remaining() -> float:
	var remaining := _global_chat_ready_at_msec - Time.get_ticks_msec()
	return maxf(0.0, float(remaining) / 1000.0)


func room_chat_cooldown_remaining() -> float:
	var remaining := _room_chat_ready_at_msec - Time.get_ticks_msec()
	return maxf(0.0, float(remaining) / 1000.0)


func get_connection_state() -> ConnectionState:
	return _connection_state


func is_room_ready() -> bool:
	return _room_ready


func get_total_player_count() -> int:
	return _total_player_count


func get_room_player_count() -> int:
	return _room_player_count


func get_presence_room_id() -> int:
	return _presence_room_id


func is_moderation_muted() -> bool:
	return is_moderation_mute_permanent() or moderation_mute_remaining_seconds() > 0


func moderation_mute_remaining_seconds() -> int:
	if is_moderation_mute_permanent():
		return 0
	return maxi(0, _muted_until_unix - _estimated_server_unix())


func is_moderation_mute_permanent() -> bool:
	return _muted_duration_mode == "permanent"


func is_moderation_banned() -> bool:
	return is_moderation_ban_permanent() or moderation_ban_remaining_seconds() > 0


func moderation_ban_remaining_seconds() -> int:
	if is_moderation_ban_permanent():
		return 0
	return maxi(0, _banned_until_unix - _estimated_server_unix())


func is_moderation_ban_permanent() -> bool:
	return _banned_duration_mode == "permanent"


func get_estimated_server_unix_msec() -> int:
	if _moderation_server_unix <= 0:
		return roundi(Time.get_unix_time_from_system() * 1000.0)
	return (_moderation_server_unix * 1000) + maxi(
		0, Time.get_ticks_msec() - _moderation_synced_msec)


func _estimated_server_unix() -> int:
	return floori(float(get_estimated_server_unix_msec()) / 1000.0)


func set_privacy_enabled(enabled: bool) -> bool:
	if is_moderation_banned():
		return false
	if _privacy_desired == enabled:
		return false
	if (_server_hello_received and _session_connected
			and not _server_capabilities.has(CAPABILITY_PRIVACY)):
		if enabled:
			Log.warn("[EasyMultiplayer] privacy requested but the server lacks privacy1")
			return false
		# A persisted fail-closed preference must remain reversible on a legacy
		# server. Disabling it publishes one ordinary legacy-compatible room join;
		# privacy can never be enabled against that server.
		_privacy_desired = false
		_begin_privacy_transition_gate()
		_on_chat_queue_discarded(_conn.clear_queue())
		_refresh_local_player_snapshot_without_sending()
		_send_room_join_state()
		_conn.send_packet("chaton", ["1" if enable_chat else "0"])
		_emit_privacy_state_changed()
		return true
	_privacy_desired = enabled
	_begin_privacy_transition_gate()
	if enabled and _cu_player_count_seen:
		_apply_server_variables({1232: 1})
	_emit_privacy_state_changed()
	if (_session_connected and _server_capabilities.has(CAPABILITY_PRIVACY)
			and _conn != null and _conn.is_connected_to_server()):
		# Nothing queued before the privacy barrier may disclose the old public
		# state. New local state packets remain ordered after this request and are
		# cached, but not published, by a privacy-aware server.
		_on_chat_queue_discarded(_conn.clear_queue())
		_send_privacy_request()
	return true


func is_privacy_enabled() -> bool:
	return _privacy_desired


func is_privacy_active() -> bool:
	return _privacy_authoritative


func is_privacy_transition_pending() -> bool:
	return _privacy_transition_pending


func supports_privacy() -> bool:
	return _server_capabilities.has(CAPABILITY_PRIVACY)


func privacy_cooldown_remaining() -> float:
	var remaining := _privacy_ready_at_msec - Time.get_ticks_msec()
	return maxf(0.0, float(remaining) / 1000.0)


func is_privacy_server_ready() -> bool:
	return _compute_privacy_server_ready()


func is_global_chat_server_ready() -> bool:
	return _compute_global_chat_server_ready()


func is_room_chat_server_ready() -> bool:
	return _compute_room_chat_server_ready()


func uses_authoritative_global_chat() -> bool:
	return _server_capabilities.has(CAPABILITY_GLOBAL_CHAT_ACK)


func is_global_chat_submission_pending() -> bool:
	return _global_chat_pending


func uses_authoritative_room_chat() -> bool:
	return _server_capabilities.has(CAPABILITY_ROOM_CHAT_ACK)


func is_room_chat_submission_pending() -> bool:
	return _room_chat_pending


func get_current_map_id() -> int:
	return _current_map_id


func set_location_runtime(runtime: Node) -> void:
	# Deliberately duck-typed: a future user-supplied location catalog can be
	# injected without this networking layer depending on its concrete class.
	var context_callback := Callable(self, "_on_location_runtime_context_changed")
	if (is_instance_valid(_location_runtime)
			and _location_runtime.has_signal("context_changed")
			and _location_runtime.is_connected("context_changed", context_callback)):
		_location_runtime.disconnect("context_changed", context_callback)
	_location_runtime = runtime
	if (is_instance_valid(_location_runtime)
			and _location_runtime.has_signal("context_changed")
			and not _location_runtime.is_connected("context_changed", context_callback)):
		_location_runtime.connect("context_changed", context_callback)
	_sync_previous_location_if_ready()


func set_previous_map_id(map_id: int) -> void:
	if map_id < 0 or map_id > MAX_ROOM_ID:
		Log.warn("[EasyMultiplayer] ignored out-of-range previous map id: %d" % map_id)
		return
	_previous_map_id = map_id
	_sync_previous_location_if_ready()


func get_location_context() -> Dictionary:
	return {
		"map_id": _current_map_id,
		"prev_map_id": _resolve_previous_map_id(),
		"x": _local_x,
		"y": _local_y,
	}


func _resolve_previous_map_id() -> int:
	if is_instance_valid(_location_runtime):
		var candidate: Variant = null
		if _location_runtime.has_method("get_location_context"):
			var context: Variant = _location_runtime.call("get_location_context")
			if context is Dictionary:
				for key in ["prev_map_id", "previous_map_id", "prevMapId"]:
					if context.has(key):
						candidate = context[key]
						break
		elif _location_runtime.has_method("get_previous_map_id"):
			candidate = _location_runtime.call("get_previous_map_id")
		if typeof(candidate) == TYPE_INT:
			var runtime_prev_map_id := int(candidate)
			if runtime_prev_map_id >= 0 and runtime_prev_map_id <= MAX_ROOM_ID:
				return runtime_prev_map_id
	return _previous_map_id


func _on_location_runtime_context_changed(_context: Dictionary) -> void:
	_sync_previous_location_if_ready()


func _sync_previous_location_if_ready(force: bool = false) -> void:
	if (_conn == null or not _session_connected or _switching_room
			or _current_map_id == 0):
		return
	var previous_map_id := _resolve_previous_map_id()
	if not force and previous_map_id == _last_sent_previous_map_id:
		return
	_conn.send_packet("ploc", [str(previous_map_id)])
	_last_sent_previous_map_id = previous_map_id


func _refresh_current_map_id() -> void:
	if not is_instance_valid(_engine) or not _engine.has_method("get_current_map_id"):
		return
	var detected_map_id := maxi(0, int(_engine.get_current_map_id()))
	if detected_map_id != _current_map_id:
		connect_to_room(detected_map_id, true)


func _set_current_map_id(map_id: int) -> void:
	if _current_map_id == map_id:
		return
	_previous_map_id = _current_map_id if _current_map_id > 0 else 0
	_current_map_id = map_id
	_refresh_global_chat_server_ready()
	current_map_changed.emit(map_id)


func _suspend_for_map_zero() -> void:
	_connection_attempts = 0
	_connection_stopped = false
	_establishing_connection = false
	Log.info("[EasyMultiplayer] Map ID 0 — suspending client connection")
	_invalidate_connection_attempt()
	_session_active = false
	_reconnecting = false
	_set_session_connected(false)
	_switching_room = true
	_set_room_ready(false)
	_switched_room = false
	if _engine and _engine.is_running():
		# Keep the native room cache in sync so re-entering the same map later
		# still produces the correct transition and reconnect behavior.
		_engine.mp_set_room_id(0)
		_engine.mp_set_session_active(false)
	if _conn:
		_conn.close()
		_socket_epoch = _conn.get_socket_epoch()
	_reset_socket_protocol_state()
	_set_connection_state(ConnectionState.DISCONNECTED)
	_initialize(true)

func _wire_player_signals() -> void:
	_engine.player_moved.connect(_on_local_moved)
	_engine.player_facing_changed.connect(_on_local_facing)
	_engine.player_speed_changed.connect(_on_local_speed)
	_engine.player_sprite_changed.connect(_on_local_sprite)
	_engine.player_jumped.connect(_on_local_jumped)
	_engine.player_flashed.connect(_on_local_flashed)
	_engine.player_transparency_changed.connect(_on_local_transparency)
	_engine.player_hidden_changed.connect(_on_local_hidden)
	_engine.player_teleported.connect(_on_local_teleported)
	_engine.player_se_played.connect(_on_local_se)
	_engine.player_system_changed.connect(_on_local_system)
	_engine.map_changed.connect(_on_map_changed)
	_engine.switch_set.connect(_on_switch_set)
	_engine.variable_set.connect(_on_variable_set)
	_engine.event_triggered.connect(_on_event_triggered)

func _on_local_moved(x: int, y: int) -> void:
	_local_x = x
	_local_y = y
	if not _session_connected:
		return
	_conn.send_packet("m", [str(x), str(y)])

func _on_local_facing(dir: int) -> void:
	_local_facing = dir
	if not _session_connected:
		return
	_conn.send_packet("f", [str(dir)])

func _on_local_speed(spd: int) -> void:
	_local_speed = spd
	if not _session_connected:
		return
	_conn.send_packet("spd", [str(spd)])

func _on_local_sprite(spr_name: String, index: int) -> void:
	_local_sprite_name = spr_name
	_local_sprite_index = index
	player_profile_sprite_changed.emit(_my_pid, spr_name, index)
	if not _session_connected:
		return
	_conn.send_packet("spr", [_sanitize(spr_name), str(index)])

func _on_local_jumped(x: int, y: int) -> void:
	_local_x = x
	_local_y = y
	if not _session_connected:
		return
	_conn.send_packet("jmp", [str(x), str(y)])

func _on_local_flashed(r: int, g: int, b: int, power: int, frames: int) -> void:
	if not _session_connected:
		return
	if frames < 0 or frames > InputLimits.HARD_FLASH_FRAMES:
		_warn_packet("local_flash_frames_hard",
			"not sending flash with out-of-range duration %d" % frames)
		return
	if frames > InputLimits.NORMAL_FLASH_FRAMES:
		_warn_packet("local_flash_frames_soft",
			"sending extended flash duration %d" % frames)
	var flash := [r, g, b, power, frames]
	var is_continuation := (
		_last_flash_frame_index > -1
		and _frame_index - _last_flash_frame_index <= 1
		and (_last_frame_flash.is_empty() or _last_frame_flash == flash)
	)
	if is_continuation:
		if _last_frame_flash.is_empty():
			_last_frame_flash = flash
			_conn.send_packet("rfl", [str(r), str(g), str(b), str(power), str(frames)])
	else:
		_conn.send_packet("fl", [str(r), str(g), str(b), str(power), str(frames)])
		_last_frame_flash = []
	_last_flash_frame_index = _frame_index

func _on_local_transparency(t: int) -> void:
	_local_transparency = t
	if not _session_connected:
		return
	_conn.send_packet("tr", [str(t)])

func _on_local_hidden(hidden: bool) -> void:
	_local_hidden = hidden
	if not _session_connected:
		return
	_conn.send_packet("h", [str(1 if hidden else 0)])

func _on_local_teleported(map_id: int, x: int, y: int) -> void:
	_local_x = x
	_local_y = y
	if not _session_connected:
		return
	Log.debug("[EasyMultiplayer] local teleported map=%d (%d,%d)" % [map_id, x, y])
	_conn.send_packet("tp", [str(x), str(y)])

func _on_local_se(snd_name: String, volume: int, tempo: int, balance: int) -> void:
	if not _session_connected:
		return
	_conn.send_packet("se", [_sanitize(snd_name), str(volume), str(tempo), str(balance)])

func _on_local_system(sys_name: String) -> void:
	_local_system_name = sys_name
	if _engine != null and _engine.has_method("get_current_system_stretch"):
		_local_system_stretch = clampi(int(_engine.call("get_current_system_stretch")), 0, 1)
	local_menu_theme_changed.emit(get_current_menu_theme_colors())
	if not _session_connected:
		return
	_send_local_system_packet()


func _send_local_system_packet() -> void:
	if _server_capabilities.has(CAPABILITY_SYSTEM_THEME):
		_conn.send_packet("sys2", [_sanitize(_local_system_name), str(_local_system_stretch)])
	else:
		_conn.send_packet("sys", [_sanitize(_local_system_name)])

func _on_map_changed(map_id: int) -> void:
	if map_id != _current_map_id:
		connect_to_room(map_id, true)

func _on_switch_set(switch_id: int, value: int) -> void:
	if not _session_connected:
		return
	if switch_id in _sync_switches:
		_conn.send_packet("ss", [str(switch_id), str(value)])

func _on_variable_set(var_id: int, value: int) -> void:
	if not _session_connected:
		return
	# Variables owned by the server must never loop back through the generic sv path.
	if _server_global_vars_active and var_id >= 1231 and var_id <= 1237:
		return
	if var_id in _sync_vars:
		_conn.send_packet("sv", [str(var_id), str(value)])

func _on_event_triggered(event_id: int, action: bool) -> void:
	if not _session_connected:
		return
	if action:
		if event_id in _sync_action_events:
			_conn.send_packet("sev", [str(event_id), "1"])
	else:
		if event_id in _sync_events:
			_conn.send_packet("sev", [str(event_id), "0"])


func _start_physical_connection() -> void:
	if (_conn == null or not _session_active or _current_map_id == 0
			or _connection_stopped or _conn.is_connected_to_server()):
		return
	if not _identity_persistence_ready:
		Log.error("[EasyMultiplayer] connection blocked: local installation identity unavailable")
		_stop_disconnected_session()
		return
	var normalized_endpoint := normalize_server_endpoint(server_url)
	if normalized_endpoint.is_empty():
		Log.error("[EasyMultiplayer] connection blocked: invalid WebSocket server URL")
		_stop_disconnected_session()
		return
	server_url = normalized_endpoint
	_cancel_reconnect_wait()
	if _resume_attempt_sequence >= MAX_ATTEMPT_SEQUENCE:
		# A sequence cannot wrap while retaining a token whose server-side high-water
		# mark is already MAX_ATTEMPT_SEQUENCE. Start a fresh anonymous session.
		_set_resume_state_internal("", 0, true)
	_connection_attempts += 1
	_establishing_connection = true
	_clear_attempt_deadline()
	_connection_generation += 1
	_active_socket_generation = _connection_generation
	_resume_attempt_sequence += 1
	_active_attempt_sequence = _resume_attempt_sequence
	_accepted_attempt_sequence = 0
	_set_resume_state_internal(_resume_token, _resume_attempt_sequence, true)
	_switching_room = true
	_set_room_ready(false)
	_reset_socket_protocol_state()
	_set_connection_state(ConnectionState.CONNECTING)
	var url := _room_url(_room_id)
	_last_disconnect_reason = ""
	Log.info("[EasyMultiplayer] opening WebSocket attempt=%d generation=%d: %s" \
		% [_active_attempt_sequence, _active_socket_generation, url])
	_last_physical_open_msec = Time.get_ticks_msec()
	var open_error := _conn.open(url)
	_socket_epoch = _conn.get_socket_epoch()
	if open_error != OK:
		# A synchronous connect_to_url() failure produces no WebSocket close event,
		# so enter the same retry path as an asynchronous transport failure.
		_on_ws_disconnected(1006, _socket_epoch)
	else:
		_arm_attempt_deadline()


func _set_resume_state_internal(
	token: String,
	attempt_sequence: int,
	force_emit: bool
) -> void:
	var changed := (_resume_token != token or _resume_attempt_sequence != attempt_sequence)
	_resume_token = token
	_resume_attempt_sequence = attempt_sequence
	if changed or force_emit:
		resume_state_changed.emit(_resume_token, _resume_attempt_sequence)


func _is_valid_resume_token(token: String) -> bool:
	return _is_lower_hex_64(token)


static func _is_lower_hex_64(value: String) -> bool:
	if value.length() != 64 or value != value.to_lower():
		return false
	for index in range(value.length()):
		var code := value.unicode_at(index)
		if not ((code >= 48 and code <= 57) or (code >= 97 and code <= 102)):
			return false
	return true


func _cancel_reconnect_wait() -> void:
	_reconnect_wait_nonce += 1
	_reconnect_waiting = false


func _invalidate_connection_attempt() -> void:
	_clear_attempt_deadline()
	_connection_generation += 1
	_active_socket_generation = -1
	_active_attempt_sequence = 0
	_accepted_attempt_sequence = 0
	_cancel_reconnect_wait()


func _is_current_socket_event(event_epoch: int) -> bool:
	return (event_epoch == _socket_epoch
		and _active_socket_generation == _connection_generation)


func _on_ws_connected(event_epoch: int) -> void:
	if not _is_current_socket_event(event_epoch):
		return
	if _current_map_id == 0:
		_invalidate_connection_attempt()
		_conn.close()
		_socket_epoch = _conn.get_socket_epoch()
		return
	Log.info("[EasyMultiplayer] WebSocket connected")
	if _engine and _engine.is_running():
		_engine.mp_set_session_active(true)

func _on_transport_stalled(event_epoch: int) -> void:
	if not _is_current_socket_event(event_epoch) or not _session_active:
		return
	Log.warn("[EasyMultiplayer] outbound transport stalled — reconnecting with a full state sync")
	# Closing discards every queued non-idempotent packet. Chat text remains in
	# the overlay, but nothing is automatically replayed on the new socket.
	_conn.close()
	_socket_epoch = _conn.get_socket_epoch()
	_on_ws_disconnected(1006, _socket_epoch)


func _on_ws_disconnected_with_reason(code: int, _reason: String, event_epoch: int) -> void:
	_on_ws_disconnected(code, event_epoch)


func _on_ws_disconnected(code: int, event_epoch: int) -> void:
	if not _is_current_socket_event(event_epoch):
		return
	_clear_attempt_deadline()
	Log.info("[EasyMultiplayer] WebSocket disconnected code=%d" % code)
	_switching_room = true
	_initialize(true)
	_reset_socket_protocol_state()
	if code == SESSION_REPLACED_CLOSE_CODE:
		Log.warn("[EasyMultiplayer] session replaced (4001) — clearing resume token and stopping")
		_set_resume_state_internal("", _resume_attempt_sequence, true)
		_stop_disconnected_session()
	elif code == 1028:
		Log.warn("[EasyMultiplayer] server EXIT (1028) — stopping session")
		_stop_disconnected_session()
	elif code in [IDENTITY_REQUIRED_CLOSE_CODE, IDENTITY_INVALID_CLOSE_CODE]:
		Log.warn("[EasyMultiplayer] installation identity rejected — stopping session")
		_stop_disconnected_session()
	elif _session_active:
		_set_connection_state(ConnectionState.CONNECTING)
		_schedule_reconnect()
	else:
		_stop_disconnected_session()


func _schedule_reconnect() -> void:
	if _connection_attempts >= MAX_CONNECTION_ATTEMPTS:
		Log.warn("[EasyMultiplayer] connection attempts exhausted — waiting for manual reconnect")
		_stop_disconnected_session()
		return
	if _reconnect_waiting:
		Log.debug("[EasyMultiplayer] reconnect already pending — skipping duplicate")
		return
	_reconnecting = true
	_reconnect_waiting = true
	_reconnect_wait_nonce += 1
	var wait_nonce := _reconnect_wait_nonce
	var wait_generation := _connection_generation
	Log.info("[EasyMultiplayer] reconnecting to room %d in %.0fs…" \
		% [_room_id, RECONNECT_DELAY_SECONDS])
	await get_tree().create_timer(RECONNECT_DELAY_SECONDS).timeout
	if (wait_nonce != _reconnect_wait_nonce or wait_generation != _connection_generation
			or not _session_active or _current_map_id == 0):
		return
	_reconnect_waiting = false
	_start_physical_connection()


func _stop_disconnected_session() -> void:
	_connection_stopped = true
	_establishing_connection = false
	_invalidate_connection_attempt()
	_session_active = false
	_reconnecting = false
	if _engine and _engine.is_running():
		_engine.mp_set_session_active(false)
	_set_connection_state(ConnectionState.DISCONNECTED)


func _terminate_identity_handshake(message: String) -> void:
	Log.warn("[EasyMultiplayer] %s — stopping session" % message)
	if _conn != null:
		_conn.close()
		_socket_epoch = _conn.get_socket_epoch()
	_initialize(true)
	_reset_socket_protocol_state()
	_stop_disconnected_session()

func _on_packet(type: String, args: Array, packet_epoch: int) -> void:
	_check_attempt_deadline()
	if not _is_current_socket_event(packet_epoch) or _current_map_id == 0:
		return
	if _privacy_blocks_public_data() and _PRIVACY_BLOCKED_PACKETS.has(type):
		return
	# `ri` is the S2C room barrier. Packets queued for the previous room can
	# legitimately arrive before it on the reused socket and must not repopulate
	# the newly-cleared remote-player state.
	if (_switching_room and type not in ["s", "identity_chal", "identity_ok",
			"resume_ok", "privacy_status", "ri",
			"gchat2", "gchat3", "gchat4", "gchat5", "gchat6", "gchat", "gchat_status", "chat_status", "cut", "cuw", "ssv",
			"adm_ok", "adm_fail", "adm_result", "adm_roster_begin", "adm_roster_item", "adm_roster_item2",
			"adm_roster_end", "adm_bans_begin", "adm_bans_item", "adm_bans_item2", "adm_bans_item3", "adm_bans_end",
			"plist_begin", "plist_item", "plist_item2", "plist_end", "plist_fail",
			"server_notice", "mod_status"]):
		return
	if type == "identity_chal" and (
			args.size() != 1 or not _is_lower_hex_64(args[0] as String)):
		_terminate_identity_handshake("invalid installation identity challenge")
		return
	if type == "identity_ok" and not args.is_empty():
		_terminate_identity_handshake("invalid installation identity acknowledgement")
		return
	if not _packet_argument_count_is_valid(type, args.size()):
		_warn_packet("schema_" + type,
			"rejected packet '%s' with %d arguments" % [type, args.size()])
		return
	if not _packet_values_are_structurally_valid(type, args):
		_warn_packet("values_" + type, "rejected packet '%s' with invalid values" % type)
		return
	if type in ["fl", "rfl"] and int(args[5]) > InputLimits.NORMAL_FLASH_FRAMES:
		_warn_packet("flash_frames_soft",
			"accepted extended flash duration %s" % (args[5] as String))
	if _packet_targets_tombstoned_player(type, args):
		return
	match type:
		"s": _handle_sync_player_data(args)
		"identity_chal": _handle_identity_challenge(args)
		"identity_ok": _handle_identity_ok()
		"resume_ok": _handle_resume_ok(args)
		"privacy_status": _handle_privacy_status(args)
		"ri": _handle_room_info(args)
		"c": _handle_clear_player(args)
		"d": _handle_disconnect(args)
		"m": _handle_move(args)
		"jmp": _handle_jump(args)
		"f": _handle_facing(args)
		"spd": _handle_speed(args)
		"spr": _handle_sprite(args)
		"fl": _handle_flash(args)
		"rfl": _handle_repeating_flash(args)
		"rrfl": _handle_remove_repeating_flash(args)
		"tr": _handle_transparency(args)
		"h": _handle_hidden(args)
		"sys": _handle_system(args)
		"sys2": _handle_system_theme(args)
		"se": _handle_se(args)
		"ss": _handle_sync_switch(args)
		"sv": _handle_sync_variable(args)
		"sev": _handle_sync_event(args)
		"cut": _handle_cu_time(args)
		"cuw": _handle_cu_weather(args)
		"ssv": _handle_server_variable(args)
		"sp": _handle_sync_picture(args)
		"pns": _handle_name_list_sync(args)
		"bas": _handle_battle_anim_id_list(args)
		"name": _handle_name(args)
		"chat": _handle_chat(args)
		"chat2": _handle_chat_metadata(args)
		"chat3": _handle_chat_metadata_v2(args)
		"gchat2": _handle_global_chat_raw(args)
		"gchat3": _handle_global_chat_metadata(args)
		"gchat4": _handle_global_chat_metadata_v2(args)
		"gchat": _handle_global_chat_legacy(args)
		"presence": _handle_presence(args)
		"gchat_status": _handle_global_chat_status(args)
		"chat_status": _handle_room_chat_status(args)
		"adm_ok": _handle_admin_ok(args)
		"adm_fail": _handle_admin_fail(args)
		"adm_result": _handle_admin_result(args)
		"adm_roster_begin": _handle_admin_roster_begin(args)
		"adm_roster_item": _handle_admin_roster_item(args)
		"adm_roster_item2": _handle_admin_roster_item2(args)
		"adm_roster_end": _handle_admin_roster_end(args)
		"adm_bans_begin": _handle_admin_bans_begin(args)
		"adm_bans_item": _handle_admin_bans_item(args)
		"adm_bans_item2": _handle_admin_bans_item2(args)
		"adm_bans_item3": _handle_admin_bans_item3(args)
		"adm_bans_end": _handle_admin_bans_end(args)
		"plist_begin": _handle_player_list_begin(args)
		"plist_item": _handle_player_list_item(args)
		"plist_item2": _handle_player_list_item2(args)
		"chat4": _handle_chat_mentions_record(args, false)
		"gchat5": _handle_chat_mentions_record(args, true)
		"chat5": _handle_chat_mentions_record(args, false, true)
		"gchat6": _handle_chat_mentions_record(args, true, true)
		"plist_end": _handle_player_list_end(args)
		"plist_fail": _fail_list_query("plist", int(args[0]), str(args[1]))
		"server_notice": _handle_server_notice(args)
		"mod_status": _handle_moderation_status(args)
		_:
			_warn_packet("unknown", "unknown packet '%s'" % type)

func _handle_sync_player_data(_args: Array) -> void:
	if _server_hello_received:
		_warn_packet("duplicate_server_hello", "ignored duplicate server hello")
		return
	var own_pid: Variant = _bounded_packet_int(_args[1], 1, MAX_ROOM_ID)
	if own_pid == null:
		_warn_packet("session_pid", "rejected invalid own PID")
		return
	_my_pid = int(own_pid)
	_server_capabilities.clear()
	var negotiated_capabilities: Array[String] = []
	for index in range(2, _args.size()):
		var capability := _args[index] as String
		if capability in [CAPABILITY_PRESENCE, CAPABILITY_GLOBAL_CHAT_ACK, CAPABILITY_ROOM_CHAT_ACK,
				CAPABILITY_ROOM_BARRIER, CAPABILITY_SESSION_RESUME,
				CAPABILITY_INSTALL_IDENTITY, CAPABILITY_PRIVACY,
				CAPABILITY_ADMIN, CAPABILITY_CHAT_METADATA, CAPABILITY_MODERATION,
				CAPABILITY_PLAYER_LIST, CAPABILITY_LIST_QUERY, CAPABILITY_SYSTEM_THEME,
				CAPABILITY_SYSTEM_THEME_SYNC, CAPABILITY_CHAT_MENTIONS, CAPABILITY_CHAT_SNAPSHOT, CAPABILITY_UNNAMED_CHAT]:
			if not _server_capabilities.has(capability):
				_server_capabilities[capability] = true
				negotiated_capabilities.append(capability)
	if not negotiated_capabilities.is_empty():
		_conn.send_packet("cap", negotiated_capabilities)
	_server_hello_received = true
	_global_chat_pending = false
	_global_chat_ready_at_msec = 0
	_room_chat_pending = false
	_room_chat_ready_at_msec = 0
	# Legacy servers have no authoritative status packet, so transport/room/chat
	# state and the local cooldown are their readiness source of truth.
	_server_global_chat_raw_ready = not _server_capabilities.has(CAPABILITY_GLOBAL_CHAT_ACK)
	_server_room_chat_raw_ready = not _server_capabilities.has(CAPABILITY_ROOM_CHAT_ACK)
	_refresh_global_chat_server_ready()
	if not _server_capabilities.has(CAPABILITY_INSTALL_IDENTITY):
		_terminate_identity_handshake("server does not support install_identity1")
		return
	_identity_challenge_pending = true
	return


func _handle_identity_challenge(args: Array) -> void:
	if (not _server_hello_received
			or not _server_capabilities.has(CAPABILITY_INSTALL_IDENTITY)
			or not _identity_challenge_pending or _identity_response_pending
			or _identity_handshake_accepted):
		_terminate_identity_handshake("unexpected installation identity challenge")
		return
	if (not _identity_persistence_ready
			or _installation_secret.size() != ClientIdentityStoreScript.SECRET_BYTES):
		_terminate_identity_handshake("local installation identity unavailable")
		return
	var server_namespace := args[0] as String
	var installation_identity := ClientIdentityStoreScript.derive_installation_identity_from_secret(
		_installation_secret, server_namespace)
	if not _is_lower_hex_64(installation_identity):
		_terminate_identity_handshake("could not derive installation identity")
		return
	_identity_challenge_pending = false
	_identity_response_pending = true
	_conn.send_packet("install_identity", [installation_identity])


func _handle_identity_ok() -> void:
	if (not _server_capabilities.has(CAPABILITY_INSTALL_IDENTITY)
			or not _identity_response_pending or _identity_handshake_accepted):
		_terminate_identity_handshake("unexpected installation identity acknowledgement")
		return
	_identity_response_pending = false
	_identity_handshake_accepted = true
	_begin_resume_handshake()


func _begin_resume_handshake() -> void:
	if _server_capabilities.has(CAPABILITY_SESSION_RESUME):
		if _active_attempt_sequence < 1 or _active_attempt_sequence > MAX_ATTEMPT_SEQUENCE:
			_warn_packet("resume_attempt", "cannot resume without a current physical attempt")
			return
		_resume_handshake_pending = true
		Log.info("[EasyMultiplayer] negotiating anonymous session resume attempt=%d" \
			% _active_attempt_sequence)
		_conn.send_packet("resume", [_resume_token, str(_active_attempt_sequence)])
		return
	_complete_session_handshake()


func _handle_resume_ok(args: Array) -> void:
	if (not _server_capabilities.has(CAPABILITY_SESSION_RESUME)
			or not _resume_handshake_pending):
		_warn_packet("unexpected_resume_ok", "ignored unexpected resume_ok")
		return
	var token := (args[0] as String).to_lower()
	var attempt_sequence := int(args[1])
	if attempt_sequence != _active_attempt_sequence:
		_warn_packet("resume_attempt_mismatch",
			"ignored resume_ok for a non-current attempt sequence")
		return
	_resume_handshake_pending = false
	_accepted_attempt_sequence = attempt_sequence
	_my_public_chat_id = str(args[2]) if args.size() == 3 else ""
	_remember_chat_profile(_my_public_chat_id, _my_pid, player_name)
	# Always publish the accepted pair. This both persists a newly issued token
	# and confirms the exact high-water mark when the token was retained.
	_set_resume_state_internal(token, attempt_sequence, true)
	Log.info("[EasyMultiplayer] anonymous session resume accepted attempt=%d" \
		% attempt_sequence)
	_complete_session_handshake()


func _handle_privacy_status(args: Array) -> void:
	if not _server_capabilities.has(CAPABILITY_PRIVACY):
		_warn_packet("privacy_unnegotiated", "ignored unnegotiated privacy status")
		return
	var kind := args[0] as String
	var authoritative := (args[1] as String) == "1"
	var request_sequence := int(args[2])
	var remaining_msec := int(args[3])
	if request_sequence != _privacy_pending_sequence:
		# Status for a superseded last-write-wins target is valid server output,
		# but it cannot complete the client's newer transition.
		return
	_privacy_authoritative = authoritative
	_privacy_ready_at_msec = Time.get_ticks_msec() + remaining_msec
	if remaining_msec > 0:
		privacy_cooldown_started.emit(float(remaining_msec) / 1000.0)
	if kind == "pending":
		_privacy_request_in_flight = true
		_emit_privacy_state_changed()
		_refresh_privacy_server_ready()
		return

	# accepted means the reported state is already authoritative. The room join
	# is deliberately queued only now: private uses sr alone, public uses the
	# strict sr -> full basic snapshot (m last) path.
	_privacy_request_in_flight = false
	_emit_privacy_state_changed()
	_refresh_privacy_server_ready()
	if is_moderation_banned():
		_queue_room_join_after_privacy_accept(request_sequence)
		return
	if authoritative != _privacy_desired:
		_send_privacy_request()
		return
	_queue_room_join_after_privacy_accept(request_sequence)


func _complete_session_handshake() -> void:
	if not _identity_handshake_accepted:
		return
	if _server_capabilities.has(CAPABILITY_SESSION_RESUME):
		if _accepted_attempt_sequence != _active_attempt_sequence:
			return
	else:
		# Legacy servers have no resume acknowledgement. The current transport
		# attempt itself is the compatibility-mode acceptance boundary.
		_accepted_attempt_sequence = _active_attempt_sequence
	Log.info("[EasyMultiplayer] session ready")
	# Populate cached state first; callbacks update fields while transmission is
	# gated, and the negotiated join path then queues one coherent snapshot.
	if _engine and _engine.is_running():
		_engine.mp_sync_local_player()
	_set_session_connected(true)
	_set_connection_state(ConnectionState.CONNECTED)
	if not _admin_credential.is_empty() and _server_capabilities.has(CAPABILITY_ADMIN):
		authenticate_admin()
	if _server_capabilities.has(CAPABILITY_PRIVACY):
		_begin_privacy_transition_gate()
		_send_privacy_request()
	elif _privacy_desired:
		# Privacy must fail closed on a legacy server. Keep the transport/session
		# alive, but never publish a room snapshot the server cannot protect.
		_finish_connection_establishment()
		Log.warn("[EasyMultiplayer] privacy1 unavailable — staying outside public rooms")
		_conn.send_packet("chaton", ["0"])
		_emit_privacy_state_changed()
	else:
		_send_room_join_state()
		_conn.send_packet("chaton", ["1" if enable_chat else "0"])


func _handle_admin_ok(args: Array) -> void:
	if not _server_capabilities.has(CAPABILITY_ADMIN):
		return
	_set_admin_authentication(true, args[0] as String, "")
	admin_credential_accepted.emit()


func _handle_admin_fail(args: Array) -> void:
	var error := args[0] as String
	if error == "credential_revoked":
		_admin_credential = ""
	_set_admin_authentication(false, "", error)


func _set_admin_authentication(authenticated: bool, admin_id: String, error: String) -> void:
	var changed := (_admin_authenticated != authenticated or _admin_id != admin_id)
	if changed:
		_cancel_list_queries()
	_admin_authenticated = authenticated
	_admin_id = admin_id
	if not authenticated:
		_admin_punishments_snapshot.clear()
		_admin_roster_snapshot.clear()
		_admin_subject_by_pid_history.clear()
		_admin_current_pid_by_subject.clear()
	if changed or not error.is_empty():
		admin_authentication_changed.emit(authenticated, admin_id, error)


func _handle_admin_result(args: Array) -> void:
	var action := str(args[1])
	if action in ["roster", "bans"]:
		if str(args[2]) == "0":
			_fail_list_query(action, int(args[0]), str(args[3]))
		return
	if str(args[2]) == "1":
		for query in _list_queries.values():
			query.refresh = true
	admin_action_result.emit(
		int(args[0]), args[1] as String, (args[2] as String) == "1",
		args[3] as String, args[4] as String)


func _handle_admin_roster_begin(args: Array) -> void:
	if not _admin_authenticated or not _list_query_progress("roster", int(args[0]), true):
		return
	_admin_roster_pending[int(args[0])] = {
		"revision": int(args[1]),
		"items": [],
	}


func _handle_admin_roster_item(args: Array) -> void:
	var request_id := int(args[0])
	if (not _admin_authenticated or not _admin_roster_pending.has(request_id)
			or not _list_query_progress("roster", request_id)):
		return
	var pending := _admin_roster_pending[request_id] as Dictionary
	var items := pending["items"] as Array
	items.append({
		"pid": int(args[1]),
		"name": args[2] as String,
		"room": args[3] as String,
		"muted_until": int(args[4]),
		"banned_until": int(args[5]),
		"is_admin": (args[6] as String) == "1",
		"network_label": args[7] as String,
	})


func _handle_admin_roster_item2(args: Array) -> void:
	var request_id := int(args[0])
	if (not _admin_authenticated or not _admin_roster_pending.has(request_id)
			or not _list_query_progress("roster", request_id)):
		return
	var pending := _admin_roster_pending[request_id] as Dictionary
	var items := pending["items"] as Array
	var pid := int(args[1])
	for item_value in items:
		var item := item_value as Dictionary
		if int(item.get("pid", 0)) == pid:
			item["subject_group_id"] = args[2] as String
			return


func _handle_admin_roster_end(args: Array) -> void:
	var request_id := int(args[0])
	if (not _admin_authenticated or not _admin_roster_pending.has(request_id)
			or not _list_query_progress("roster", request_id)):
		return
	var pending := _admin_roster_pending[request_id] as Dictionary
	if int(pending.get("revision", -1)) != int(args[1]):
		_fail_list_query("roster", request_id, "invalid_data")
		return
	_finish_list_query("roster", true)
	var items := (pending.get("items", []) as Array).duplicate(true)
	_admin_roster_snapshot = items.duplicate(true)
	_admin_current_pid_by_subject.clear()
	for item_value in items:
		var item := item_value as Dictionary
		var pid := int(item.get("pid", 0))
		var group_id := str(item.get("subject_group_id", ""))
		if pid > 0 and not group_id.is_empty():
			_remember_admin_subject(pid, group_id)
			_admin_current_pid_by_subject[group_id] = pid
	admin_roster_received.emit(items)


func _handle_admin_bans_begin(args: Array) -> void:
	if not _admin_authenticated or not _list_query_progress("bans", int(args[0]), true):
		return
	_admin_bans_pending[int(args[0])] = {
		"revision": int(args[1]),
		"items": [],
	}


func _handle_admin_bans_item(args: Array) -> void:
	var request_id := int(args[0])
	if (not _admin_authenticated or not _admin_bans_pending.has(request_id)
			or not _list_query_progress("bans", request_id)):
		return
	var pending := _admin_bans_pending[request_id] as Dictionary
	var items := pending["items"] as Array
	items.append({
		"ban_id": args[1] as String,
		"kind": args[2] as String,
		"last_name": args[3] as String,
		"network_label": args[4] as String,
		"expires_at": int(args[5]),
		"actor": args[6] as String,
		"duration_mode": "finite",
		"scope": "installation",
	})


func _handle_admin_bans_item2(args: Array) -> void:
	var request_id := int(args[0])
	if (not _admin_authenticated or not _admin_bans_pending.has(request_id)
			or not _list_query_progress("bans", request_id)):
		return
	var pending := _admin_bans_pending[request_id] as Dictionary
	var items := pending["items"] as Array
	var punishment_id := args[1] as String
	var target: Dictionary = {}
	for item_value in items:
		var item := item_value as Dictionary
		if str(item.get("ban_id", "")) == punishment_id:
			target = item
			break
	if target.is_empty():
		target = {
			"ban_id": punishment_id, "kind": args[2] as String,
			"last_name": args[3] as String, "network_label": args[4] as String,
			"expires_at": int(args[5]), "actor": args[6] as String,
		}
		items.append(target)
	target.merge({
		"last_name": args[3] as String,
		"online_pid": int(args[7]), "room_id": int(args[8]),
		"previous_map_id": int(args[9]), "x": int(args[10]), "y": int(args[11]),
		"system_name": args[12] as String, "system_stretch": int(args[13]),
		"sprite_name": args[14] as String, "sprite_index": int(args[15]),
		"facing": int(args[16]), "is_admin": (args[17] as String) == "1",
	}, true)


func _handle_admin_bans_item3(args: Array) -> void:
	var request_id := int(args[0])
	if (not _admin_authenticated or not _admin_bans_pending.has(request_id)
			or not _list_query_progress("bans", request_id)):
		return
	var pending := _admin_bans_pending[request_id] as Dictionary
	var items := pending["items"] as Array
	var punishment_id := args[1] as String
	for item_value in items:
		var item := item_value as Dictionary
		if str(item.get("ban_id", "")) == punishment_id:
			item["subject_group_id"] = args[2] as String
			item["created_at"] = int(args[3])
			item["scope"] = args[4] as String
			item["duration_mode"] = args[5] as String
			item["can_add_network"] = (args[6] as String) == "1"
			return


func _handle_player_list_begin(args: Array) -> void:
	var request_id := int(args[0])
	if not _list_query_progress("plist", request_id, true):
		return
	_plist_live_touches.clear()
	_plist_skip_history = false
	_player_list_pending[request_id] = {
		"revision": int(args[1]), "server_unix": int(args[2]), "items": []}


func _handle_player_list_item(args: Array) -> void:
	var request_id := int(args[0])
	if not _player_list_pending.has(request_id) or not _list_query_progress("plist", request_id):
		return
	if _plist_can_fill_history(["theme:" + str(args[1])]):
		_remember_player_system_theme(int(args[1]), args[12] as String, int(args[13]), true)
	var pending := _player_list_pending[request_id] as Dictionary
	var items := pending["items"] as Array
	items.append({
		"pid": int(args[1]), "room_id": int(args[2]),
		"previous_map_id": int(args[3]), "x": int(args[4]), "y": int(args[5]),
		"display_name": InputLimits.sanitize_nickname(args[6] as String),
		"sprite_name": args[7] as String, "sprite_index": int(args[8]),
		"facing": int(args[9]), "hidden": (args[10] as String) == "1",
		"transparency": int(args[11]), "system_name": args[12] as String,
		"system_stretch": int(args[13]), "is_admin": (args[14] as String) == "1",
		"muted_until": int(args[15]), "muted_duration_mode": args[16] as String,
		"muted_network_scope": (args[17] as String) == "1",
		"server_unix": int(pending.get("server_unix", 0)),
	})


func _handle_player_list_end(args: Array) -> void:
	var request_id := int(args[0])
	if request_id != _player_list_in_flight or not _player_list_pending.has(request_id):
		return
	var pending := _player_list_pending[request_id] as Dictionary
	if int(pending.get("revision", -1)) != int(args[1]):
		_fail_list_query("plist", request_id, "invalid_data")
		return
	_finish_list_query("plist", true)
	var items := (pending.get("items", []) as Array).duplicate(true)
	var admins: Dictionary = {}
	_known_player_roles.clear()
	for item_value in items:
		var item := item_value as Dictionary
		var pid := int(item.get("pid", 0))
		_known_player_roles[pid] = bool(item.get("is_admin", false))
		if bool(item.get("is_admin", false)):
			admins[pid] = true
	_identity_snapshot_msec = Time.get_ticks_msec()
	_publish_player_roles(admins)
	player_list_received.emit(items)


func _publish_player_roles(admins: Dictionary) -> void:
	var changed: Array[int] = []
	for pid in _known_admin_pids:
		if not admins.has(pid):
			changed.append(int(pid))
	for pid in admins:
		if not _known_admin_pids.has(pid):
			changed.append(int(pid))
	_known_admin_pids = admins
	if not changed.is_empty():
		player_roles_changed.emit(changed)


func _invalidate_player_list_request() -> void:
	_finish_list_query("plist")
	_player_list_pending.clear()
	_player_list_in_flight = 0
	_player_list_sent_msec = -1
	_identity_snapshot_msec = -1
	_last_identity_request_msec = -IDENTITY_REFRESH_MSEC


func _handle_admin_bans_end(args: Array) -> void:
	var request_id := int(args[0])
	if (not _admin_authenticated or not _admin_bans_pending.has(request_id)
			or not _list_query_progress("bans", request_id)):
		return
	var pending := _admin_bans_pending[request_id] as Dictionary
	if int(pending.get("revision", -1)) != int(args[1]):
		_fail_list_query("bans", request_id, "invalid_data")
		return
	_finish_list_query("bans", true)
	_admin_punishments_snapshot = (pending.get("items", []) as Array).duplicate(true)
	admin_bans_received.emit(_admin_punishments_snapshot.duplicate(true))


func _handle_server_notice(args: Array) -> void:
	server_notice_received.emit(args[0] as String, args[1] as String)


func _handle_moderation_status(args: Array) -> void:
	var was_banned := is_moderation_banned()
	_moderation_server_unix = int(args[0])
	_moderation_synced_msec = Time.get_ticks_msec()
	_muted_duration_mode = args[1] as String
	_muted_until_unix = int(args[2])
	_banned_duration_mode = args[3] as String
	_banned_until_unix = int(args[4])
	var banned_now := is_moderation_banned()
	moderation_status_changed.emit(_muted_until_unix, _banned_until_unix)
	var authoritative_ban_expired := was_banned and not banned_now
	if was_banned != banned_now or authoritative_ban_expired:
		_begin_privacy_transition_gate()
		_emit_privacy_state_changed()
		if (_session_connected and _server_capabilities.has(CAPABILITY_PRIVACY)
				and _conn != null and _conn.is_connected_to_server()):
			_on_chat_queue_discarded(_conn.clear_queue())
			_send_privacy_request()
	else:
		_refresh_global_chat_server_ready()
		_refresh_privacy_server_ready()

func _handle_room_info(args: Array) -> void:
	if (not _session_connected
			or _accepted_attempt_sequence != _active_attempt_sequence):
		return
	var parsed_room_id: Variant = _bounded_packet_int(args[0], 0, MAX_ROOM_ID)
	if parsed_room_id == null:
		_warn_packet("room_info", "rejected invalid room-info id")
		return
	var room_id := int(parsed_room_id)
	if room_id != _room_id:
		Log.warn("[EasyMultiplayer] wrong room %d (expected %d) — reconnecting" % [room_id, _room_id])
		connect_to_room(_room_id)
		return
	if (_privacy_transition_pending
			and (_privacy_request_in_flight
				or _privacy_authoritative != _privacy_desired)):
		# `ri` has no request sequence. An acknowledgement already in flight for
		# an older privacy target must not release the newer transition gate.
		return
	_begin_room_epoch()
	_finish_connection_establishment()
	_switching_room = false
	_reconnecting = false
	if _privacy_transition_pending:
		_privacy_transition_pending = false
		_privacy_room_join_queued_sequence = 0
		_emit_privacy_state_changed()
	Log.info("[EasyMultiplayer] room %d confirmed" % room_id)
	_sync_previous_location_if_ready(true)
	if _engine and _engine.is_running():
		_engine.mp_notify_room_ready()
	_set_room_ready(true)


func _handle_presence(args: Array) -> void:
	if (not _server_capabilities.has(CAPABILITY_PRESENCE) or _switching_room
			or _privacy_blocks_public_data()):
		return
	var revision: Variant = _bounded_packet_int(args[0], 0, MAX_ROOM_ID)
	var total_count: Variant = _bounded_packet_int(args[1], 0, MAX_REMOTE_PLAYERS)
	var room_id: Variant = _bounded_packet_int(args[2], 0, MAX_ROOM_ID)
	var room_count: Variant = _bounded_packet_int(args[3], 0, MAX_REMOTE_PLAYERS)
	if (revision == null or total_count == null or room_id == null or room_count == null
			or int(room_count) > int(total_count) or int(room_id) != _room_id):
		_warn_packet("presence", "rejected invalid presence snapshot")
		return
	if int(revision) < _presence_revision:
		return
	var changed := (_total_player_count != int(total_count)
		or _room_player_count != int(room_count) or _presence_room_id != int(room_id))
	_presence_revision = int(revision)
	_total_player_count = int(total_count)
	_room_player_count = int(room_count)
	_presence_room_id = int(room_id)
	if changed:
		presence_changed.emit(_total_player_count, _room_player_count, _presence_room_id)


func _handle_global_chat_status(args: Array) -> void:
	if not _server_capabilities.has(CAPABILITY_GLOBAL_CHAT_ACK):
		return
	var status := args[0] as String
	var remaining: Variant = _bounded_packet_int(args[1], 0, 60000)
	if remaining == null or status not in ["accepted", "rejected", "ready"]:
		_warn_packet("gchat_status", "rejected invalid global-chat status")
		return
	var remaining_msec := int(remaining)
	match status:
		"accepted":
			_global_chat_pending = false
			_server_global_chat_raw_ready = false
			_global_chat_ready_at_msec = Time.get_ticks_msec() + remaining_msec
			_global_chat_duration_msec = maxi(GLOBAL_CHAT_COOLDOWN_MSEC, remaining_msec)
			_refresh_global_chat_server_ready()
			var duration := float(remaining_msec) / 1000.0
			global_chat_cooldown_started.emit(duration)
			global_chat_accepted.emit(duration)
		"rejected":
			_global_chat_pending = false
			_global_chat_ready_at_msec = Time.get_ticks_msec() + remaining_msec
			_global_chat_duration_msec = maxi(GLOBAL_CHAT_COOLDOWN_MSEC, remaining_msec)
			_server_global_chat_raw_ready = remaining_msec == 0
			_refresh_global_chat_server_ready()
			global_chat_rejected.emit(float(remaining_msec) / 1000.0)
		"ready":
			_global_chat_pending = false
			_global_chat_ready_at_msec = 0
			_server_global_chat_raw_ready = true
			_refresh_global_chat_server_ready()


func _handle_room_chat_status(args: Array) -> void:
	if not _server_capabilities.has(CAPABILITY_ROOM_CHAT_ACK):
		return
	var status := args[0] as String
	var remaining: Variant = _bounded_packet_int(args[1], 0, 60000)
	if remaining == null or status not in ["accepted", "rejected", "ready"]:
		_warn_packet("chat_status", "rejected invalid room-chat status")
		return
	var remaining_msec := int(remaining)
	match status:
		"accepted":
			_room_chat_pending = false
			_server_room_chat_raw_ready = false
			_room_chat_ready_at_msec = Time.get_ticks_msec() + remaining_msec
			_room_chat_duration_msec = maxi(ROOM_CHAT_COOLDOWN_MSEC, remaining_msec)
			_refresh_room_chat_server_ready()
			var duration := float(remaining_msec) / 1000.0
			room_chat_cooldown_started.emit(duration)
			room_chat_accepted.emit(duration)
		"rejected":
			_room_chat_pending = false
			_room_chat_ready_at_msec = Time.get_ticks_msec() + remaining_msec
			_room_chat_duration_msec = maxi(ROOM_CHAT_COOLDOWN_MSEC, remaining_msec)
			_server_room_chat_raw_ready = remaining_msec == 0
			_refresh_room_chat_server_ready()
			room_chat_rejected.emit(float(remaining_msec) / 1000.0)
		"ready":
			_room_chat_pending = false
			_room_chat_ready_at_msec = 0
			_server_room_chat_raw_ready = true
			_refresh_room_chat_server_ready()


func _handle_cu_time(args: Array) -> void:
	if args.size() != 2:
		Log.warn("[EasyMultiplayer] rejected cut packet with invalid argument count")
		return
	var raw_time: Variant = _bounded_packet_int(args[0], 0, 239)
	var new_randint: Variant = _bounded_packet_int(args[1], 0, 255)
	if raw_time == null or new_randint == null:
		Log.warn("[EasyMultiplayer] rejected cut packet with invalid values")
		return
	_apply_server_variables({
		1231: new_randint,
		1233: int(raw_time) % 20,
		1234: int(int(raw_time) / 20),
	})


func _handle_cu_weather(args: Array) -> void:
	if args.size() != 2:
		Log.warn("[EasyMultiplayer] rejected cuw packet with invalid argument count")
		return
	var new_temperature: Variant = _bounded_packet_int(args[0], -100, 100)
	var new_precipitation: Variant = _bounded_packet_int(args[1], 0, 100)
	if new_temperature == null or new_precipitation == null:
		Log.warn("[EasyMultiplayer] rejected cuw packet with invalid values")
		return
	_apply_server_variables({
		1235: new_temperature,
		1236: new_precipitation,
	})


func _handle_server_variable(args: Array) -> void:
	if args.size() != 2:
		Log.warn("[EasyMultiplayer] rejected ssv packet with invalid argument count")
		return
	var variable_id: Variant = _bounded_packet_int(args[0], 1232, 1237)
	if variable_id == null or (variable_id != 1232 and variable_id != 1237):
		Log.warn("[EasyMultiplayer] rejected ssv packet for unsupported variable")
		return
	# Player count 1232 belongs to the confirmed room. A stale value may arrive
	# before the `ri` barrier, while global state such as 1237 remains valid.
	if _switching_room and int(variable_id) == 1232:
		return
	var maximum := 2147483647 if variable_id == 1232 else 7
	var value: Variant = _bounded_packet_int(args[1], 0, maximum)
	if value == null:
		Log.warn("[EasyMultiplayer] rejected ssv packet with invalid value")
		return
	if int(variable_id) == 1232:
		_cu_player_count_seen = true
		if _privacy_desired or _privacy_authoritative:
			value = 1
	_apply_server_variables({int(variable_id): value})


func _apply_server_variables(values: Dictionary) -> bool:
	if _engine == null or not _engine.is_running():
		Log.warn("[EasyMultiplayer] dropped server variables while game is not running")
		return false
	if not _engine.mp_apply_server_variables(values):
		Log.warn("[EasyMultiplayer] GDExtension rejected server variable batch")
		return false
	_server_global_vars_active = true
	return true


func _clear_server_variables() -> void:
	_server_global_vars_active = false
	_cu_player_count_seen = false
	if _engine:
		_engine.mp_clear_server_variables()


func _set_connection_state(state: ConnectionState) -> void:
	if _connection_state == state:
		return
	_connection_state = state
	connection_state_changed.emit(state)
	_refresh_reconnect_ready()


func _set_session_connected(connected: bool) -> void:
	if _session_connected == connected:
		return
	_session_connected = connected
	_refresh_global_chat_server_ready()
	_refresh_privacy_server_ready()
	_refresh_reconnect_ready()


func _set_room_ready(ready: bool) -> void:
	if _room_ready == ready:
		return
	_room_ready = ready
	room_ready_changed.emit(ready)
	_refresh_global_chat_server_ready()


func _refresh_global_chat_server_ready() -> void:
	_refresh_room_chat_server_ready()
	var ready := _compute_global_chat_server_ready()
	if _global_chat_server_ready == ready:
		return
	_global_chat_server_ready = ready
	global_chat_server_ready_changed.emit(ready)


func _compute_global_chat_server_ready() -> bool:
	return (_server_global_chat_raw_ready and _session_connected and _room_ready
		and _current_map_id != 0 and enable_chat and not _global_chat_pending
		and not _privacy_blocks_public_data()
		and global_chat_cooldown_remaining() <= 0.0)


func _refresh_room_chat_server_ready() -> void:
	var ready := _compute_room_chat_server_ready()
	if _room_chat_server_ready == ready:
		return
	_room_chat_server_ready = ready
	room_chat_server_ready_changed.emit(ready)


func _compute_room_chat_server_ready() -> bool:
	return (_server_room_chat_raw_ready and _session_connected and _room_ready
		and _current_map_id != 0 and enable_chat and not _room_chat_pending
		and not _privacy_blocks_public_data()
		and room_chat_cooldown_remaining() <= 0.0)


func _privacy_blocks_public_data() -> bool:
	return (is_moderation_banned() or _privacy_desired or _privacy_authoritative
		or _privacy_transition_pending or _privacy_request_in_flight)


func _emit_privacy_state_changed() -> void:
	privacy_state_changed.emit(
		_privacy_desired,
		_privacy_authoritative,
		_privacy_transition_pending
	)
	_refresh_global_chat_server_ready()
	_refresh_privacy_server_ready()
	_refresh_reconnect_ready()


func _compute_privacy_server_ready() -> bool:
	return (not is_moderation_banned()
		and _server_capabilities.has(CAPABILITY_PRIVACY) and _session_connected
		and not _privacy_request_in_flight and not _privacy_transition_pending
		and privacy_cooldown_remaining() <= 0.0)


func _refresh_privacy_server_ready() -> void:
	var ready := _compute_privacy_server_ready()
	if _privacy_server_ready == ready:
		return
	_privacy_server_ready = ready
	privacy_server_ready_changed.emit(ready)


func _start_manual_reconnect_cooldown() -> void:
	_manual_reconnect_ready_at_msec = (
		Time.get_ticks_msec() + MANUAL_RECONNECT_COOLDOWN_MSEC)
	reconnect_cooldown_started.emit(MANUAL_RECONNECT_COOLDOWN_SECONDS)
	_refresh_reconnect_ready()


func _refresh_reconnect_ready() -> void:
	var ready := can_request_reconnect()
	if _manual_reconnect_ready == ready:
		return
	_manual_reconnect_ready = ready
	reconnect_ready_changed.emit(ready)


func _set_room_presence_unknown() -> void:
	if _room_player_count == UNKNOWN_PLAYER_COUNT and _presence_room_id == -1:
		return
	_room_player_count = UNKNOWN_PLAYER_COUNT
	_presence_room_id = -1
	presence_changed.emit(_total_player_count, _room_player_count, _presence_room_id)


func _reset_presence() -> void:
	var changed := (_total_player_count != UNKNOWN_PLAYER_COUNT
		or _room_player_count != UNKNOWN_PLAYER_COUNT or _presence_room_id != -1)
	_presence_revision = -1
	_total_player_count = UNKNOWN_PLAYER_COUNT
	_room_player_count = UNKNOWN_PLAYER_COUNT
	_presence_room_id = -1
	if changed:
		presence_changed.emit(_total_player_count, _room_player_count, _presence_room_id)


func _reset_socket_protocol_state() -> void:
	_cancel_list_queries()
	_my_pid = -1
	_my_public_chat_id = ""
	_chat_public_profiles.clear()
	_server_capabilities.clear()
	_server_hello_received = false
	_resume_handshake_pending = false
	_identity_challenge_pending = false
	_identity_response_pending = false
	_identity_handshake_accepted = false
	_accepted_attempt_sequence = 0
	_global_chat_pending = false
	_global_chat_ready_at_msec = 0
	_room_chat_pending = false
	_room_chat_ready_at_msec = 0
	_server_global_chat_raw_ready = false
	_server_room_chat_raw_ready = false
	_privacy_authoritative = false
	_privacy_transition_pending = _privacy_desired
	_privacy_request_in_flight = false
	_privacy_pending_sequence = 0
	_privacy_ready_at_msec = 0
	_privacy_room_join_queued_sequence = 0
	_player_system_themes.clear()
	_pre_spawn_identity.clear()
	_admin_roster_pending.clear()
	_admin_bans_pending.clear()
	_invalidate_player_list_request()
	_known_player_roles.clear()
	_publish_player_roles({})
	_clear_moderation_status()
	_set_admin_authentication(false, "", "")
	_refresh_global_chat_server_ready()
	_emit_privacy_state_changed()
	_reset_presence()


func _clear_moderation_status() -> void:
	var changed := (_muted_until_unix != 0 or _banned_until_unix != 0
		or _muted_duration_mode == "permanent"
		or _banned_duration_mode == "permanent")
	_moderation_server_unix = 0
	_moderation_synced_msec = 0
	_muted_until_unix = 0
	_banned_until_unix = 0
	_muted_duration_mode = "finite"
	_banned_duration_mode = "finite"
	if changed:
		moderation_status_changed.emit(0, 0)


func _packet_argument_count_is_valid(type: String, count: int) -> bool:
	match type:
		"plist_fail": return count == 2
		"s": return count >= 2 and count <= EasyConnection.MAX_ARGUMENTS
		"identity_ok": return count == 0
		"identity_chal": return count == 1
		"ri", "d", "c", "rrfl", "sp", "adm_ok", "adm_fail": return count == 1
		"m", "jmp", "spr": return count == 3
		"f", "spd", "tr", "h", "sys", "ss", "sv", "sev", "cut", "cuw", \
				"ssv", "name", "chat", "gchat_status", "chat_status": return count == 2
		"resume_ok": return count == (3 if _server_capabilities.has(CAPABILITY_CHAT_MENTIONS) else 2)
		"chat4": return count == 8
		"gchat5": return count == 12
		"chat5": return count == 10
		"gchat6": return count == 14
		"plist_item2": return count == 19
		"sys2": return count == 3
		"fl", "rfl", "gchat": return count == 6
		"se": return count == 5
		"chat2": return count == 5
		"chat3": return count == 6
		"gchat2": return count == 7
		"gchat3": return count == 9
		"gchat4": return count == 10
		"plist_begin": return count == 3
		"plist_item": return count == 18
		"plist_end": return count == 2
		"presence", "privacy_status": return count == 4
		"adm_result": return count == 5
		"adm_roster_begin", "adm_roster_end", "adm_bans_begin", "adm_bans_end", \
				"server_notice": return count == 2
		"adm_roster_item": return count == 8
		"adm_roster_item2": return count == 3
		"adm_bans_item": return count == 7
		"adm_bans_item2": return count == 18
		"adm_bans_item3": return count == 7
		"mod_status": return count == 5
		"pns", "bas": return count >= 1 and count <= EasyConnection.MAX_ARGUMENTS
		_: return true


func _packet_values_are_structurally_valid(type: String, args: Array) -> bool:
	match type:
		"plist_fail":
			return (_server_capabilities.has(CAPABILITY_LIST_QUERY)
				and _bounded_packet_int(args[0], 1, MAX_ATTEMPT_SEQUENCE) != null
				and str(args[1]) in ["busy", "too_large", "invalid_data", "unavailable", "timeout", "cancelled"])
		"s":
			return (_bounded_packet_int(args[0], 0, MAX_ROOM_ID) != null
				and _bounded_packet_int(args[1], 1, MAX_ROOM_ID) != null)
		"resume_ok":
			return (_is_valid_resume_token((args[0] as String).to_lower())
				and _bounded_packet_int(args[1], 1, MAX_ATTEMPT_SEQUENCE) != null
				and (args.size() == 2 or ChatMentions.valid_id(str(args[2]))))
		"plist_item2":
			return (_server_capabilities.has(CAPABILITY_CHAT_MENTIONS)
				and (str(args[18]).is_empty() or ChatMentions.valid_id(str(args[18])))
				and _packet_values_are_structurally_valid("plist_item", args.slice(0, 18)))
		"chat4", "gchat5":
			return _valid_chat_mentions_record(args, type == "gchat5")
		"chat5", "gchat6":
			var base_count := 12 if type == "gchat6" else 8
			return (_server_capabilities.has(CAPABILITY_CHAT_SNAPSHOT)
				and _valid_chat_mentions_record(args.slice(0, base_count), type == "gchat6")
				and _bounded_packet_int(args[base_count], 0, 1) != null
				and _bounded_packet_int(args[base_count + 1], 0, 1) != null)
		"identity_chal":
			return _is_lower_hex_64(args[0] as String)
		"adm_ok":
			return not (args[0] as String).is_empty() and (args[0] as String).length() <= 32
		"adm_fail":
			return not (args[0] as String).is_empty() and (args[0] as String).length() <= 64
		"adm_result":
			return (_bounded_packet_int(args[0], 1, MAX_ATTEMPT_SEQUENCE) != null
				and not (args[1] as String).is_empty()
				and _bounded_packet_int(args[2], 0, 1) != null
				and (args[3] as String).length() <= 64
				and (args[4] as String).length() <= 200)
		"adm_roster_begin", "adm_roster_end", "adm_bans_begin", "adm_bans_end":
			return (_bounded_packet_int(args[0], 1, MAX_ATTEMPT_SEQUENCE) != null
				and _bounded_packet_int(args[1], 0, MAX_ATTEMPT_SEQUENCE) != null)
		"adm_roster_item":
			return (_bounded_packet_int(args[0], 1, MAX_ATTEMPT_SEQUENCE) != null
				and _bounded_packet_int(args[1], 1, MAX_ROOM_ID) != null
				and (args[2] as String).length() <= 64
				and ((args[3] as String) in ["private", "banned"]
					or _bounded_packet_int(args[3], -1, MAX_ROOM_ID) != null)
				and _bounded_packet_int(args[4], 0, 2147483647) != null
				and _bounded_packet_int(args[5], 0, 2147483647) != null
				and _bounded_packet_int(args[6], 0, 1) != null
				and (args[7] as String).length() <= 16)
		"adm_roster_item2":
			return (_bounded_packet_int(args[0], 1, MAX_ATTEMPT_SEQUENCE) != null
				and _bounded_packet_int(args[1], 1, MAX_ROOM_ID) != null
				and _is_lower_hex_64(args[2] as String))
		"adm_bans_item":
			return (_bounded_packet_int(args[0], 1, MAX_ATTEMPT_SEQUENCE) != null
				and not (args[1] as String).is_empty() and (args[1] as String).length() <= 32
				and (args[2] as String) in ["mute", "ban"]
				and (args[3] as String).length() <= 64
				and (args[4] as String).length() <= 16
				and _bounded_packet_int(args[5], 0, 2147483647) != null
				and (args[6] as String).length() <= 32)
		"adm_bans_item3":
			return (_bounded_packet_int(args[0], 1, MAX_ATTEMPT_SEQUENCE) != null
				and not (args[1] as String).is_empty()
				and (args[1] as String).length() <= 32
				and ((args[2] as String).is_empty()
					or _is_lower_hex_64(args[2] as String))
				and _bounded_packet_int(args[3], 0, 2147483647) != null
				and (args[4] as String) in [
					"installation", "installation_network", "network"]
				and (args[5] as String) in ["finite", "permanent"]
				and _bounded_packet_int(args[6], 0, 1) != null)
		"server_notice":
			return (args[0] as String) in ["announcement", "restart", "shutdown"] \
				and (args[1] as String).length() <= 200
		"mod_status":
			return (_bounded_packet_int(args[0], 1, 2147483647) != null
				and (args[1] as String) in ["finite", "permanent"]
				and _bounded_packet_int(args[2], 0, 2147483647) != null
				and (args[3] as String) in ["finite", "permanent"]
				and _bounded_packet_int(args[4], 0, 2147483647) != null)
		"privacy_status":
			return ((args[0] as String) in ["accepted", "pending"]
				and _bounded_packet_int(args[1], 0, 1) != null
				and _bounded_packet_int(args[2], 1, MAX_ATTEMPT_SEQUENCE) != null
				and _bounded_packet_int(args[3], 0, 60000) != null)
		"ri":
			return _bounded_packet_int(args[0], 0, MAX_ROOM_ID) != null
		"d", "c", "rrfl":
			return _bounded_packet_int(args[0], 1, MAX_ROOM_ID) != null
		"m", "jmp":
			return (_bounded_packet_int(args[0], 1, MAX_ROOM_ID) != null
				and _bounded_packet_int(args[1], 0, MAX_COORDINATE) != null
				and _bounded_packet_int(args[2], 0, MAX_COORDINATE) != null)
		"f":
			return (_bounded_packet_int(args[0], 1, MAX_ROOM_ID) != null
				and _bounded_packet_int(args[1], 0, 3) != null)
		"spd":
			return (_bounded_packet_int(args[0], 1, MAX_ROOM_ID) != null
				and _bounded_packet_int(args[1], 0, 10) != null)
		"spr":
			return (_bounded_packet_int(args[0], 1, MAX_ROOM_ID) != null
				and ResourceNameRules.is_safe_flat_resource_name(args[1], true)
				and _bounded_packet_int(args[2], 0, 7) != null)
		"fl", "rfl":
			return (_bounded_packet_int(args[0], 1, MAX_ROOM_ID) != null
				and _bounded_packet_int(args[1], 0, 255) != null
				and _bounded_packet_int(args[2], 0, 255) != null
				and _bounded_packet_int(args[3], 0, 255) != null
				and _bounded_packet_int(args[4], 0, MAX_COORDINATE) != null
				and _bounded_packet_int(
					args[5], 0, InputLimits.HARD_FLASH_FRAMES) != null)
		"tr":
			return (_bounded_packet_int(args[0], 1, MAX_ROOM_ID) != null
				and _bounded_packet_int(args[1], 0, 7) != null)
		"h":
			return (_bounded_packet_int(args[0], 1, MAX_ROOM_ID) != null
				and _bounded_packet_int(args[1], 0, 1) != null)
		"sys":
			return (_bounded_packet_int(args[0], 1, MAX_ROOM_ID) != null
				and ResourceNameRules.is_safe_flat_resource_name(args[1], false))
		"sys2":
			return (_bounded_packet_int(args[0], 1, MAX_ROOM_ID) != null
				and ResourceNameRules.is_safe_flat_resource_name(args[1], false)
				and _bounded_packet_int(args[2], 0, 1) != null)
		"name", "chat":
			return _bounded_packet_int(args[0], 1, MAX_ROOM_ID) != null
		"chat2":
			return (_bounded_packet_int(args[0], 1, MAX_ROOM_ID) != null
				and (args[1] as String).length() <= 64
				and ((args[2] as String).is_empty()
					or ResourceNameRules.is_safe_flat_resource_name(args[2], false))
				and _bounded_packet_int(args[3], 0, MAX_ROOM_ID) != null)
		"chat3":
			return (_bounded_packet_int(args[0], 1, MAX_ROOM_ID) != null
				and (args[1] as String).length() <= 64
				and ((args[2] as String).is_empty()
					or ResourceNameRules.is_safe_flat_resource_name(args[2], false))
				and _bounded_packet_int(args[3], 0, 1) != null
				and _bounded_packet_int(args[4], 0, MAX_ROOM_ID) != null)
		"se":
			return (_bounded_packet_int(args[0], 1, MAX_ROOM_ID) != null
				and ResourceNameRules.is_safe_resource_path(args[1], false)
				and _bounded_packet_int(args[2], 0, 100) != null
				and _bounded_packet_int(args[3], 10, 400) != null
				and _bounded_packet_int(args[4], 0, 100) != null)
		"ss", "sv", "sev":
			return (_bounded_packet_int(args[0], 0, MAX_ROOM_ID) != null
				and _bounded_packet_int(args[1], 0, MAX_ROOM_ID) != null)
		"cut":
			return (_bounded_packet_int(args[0], 0, 239) != null
				and _bounded_packet_int(args[1], 0, 255) != null)
		"cuw":
			return (_bounded_packet_int(args[0], -100, 100) != null
				and _bounded_packet_int(args[1], 0, 100) != null)
		"ssv":
			var variable_id: Variant = _bounded_packet_int(args[0], 1232, 1237)
			if variable_id == null or (int(variable_id) != 1232 and int(variable_id) != 1237):
				return false
			var maximum := MAX_ROOM_ID if int(variable_id) == 1232 else 7
			return _bounded_packet_int(args[1], 0, maximum) != null
		"pns":
			return _bounded_packet_int(args[0], 0, 1) != null
		"bas":
			for value in args:
				if _bounded_packet_int(value, 0, MAX_ROOM_ID) == null:
					return false
			return true
		"gchat2":
			return (_bounded_packet_int(args[0], 1, MAX_ROOM_ID) != null
				and _bounded_packet_int(args[2], 0, MAX_ROOM_ID) != null
				and _bounded_packet_int(args[3], 0, MAX_ROOM_ID) != null
				and _bounded_packet_int(args[4], -1, MAX_COORDINATE) != null
				and _bounded_packet_int(args[5], -1, MAX_COORDINATE) != null)
		"gchat3":
			return (_bounded_packet_int(args[0], 1, MAX_ROOM_ID) != null
				and (args[1] as String).length() <= 64
				and ((args[2] as String).is_empty()
					or ResourceNameRules.is_safe_flat_resource_name(args[2], false))
				and _bounded_packet_int(args[3], 0, MAX_ROOM_ID) != null
				and _bounded_packet_int(args[4], 0, MAX_ROOM_ID) != null
				and _bounded_packet_int(args[5], -1, MAX_COORDINATE) != null
				and _bounded_packet_int(args[6], -1, MAX_COORDINATE) != null
				and _bounded_packet_int(args[7], 0, MAX_ROOM_ID) != null)
		"gchat4":
			return (_bounded_packet_int(args[0], 1, MAX_ROOM_ID) != null
				and (args[1] as String).length() <= 64
				and ((args[2] as String).is_empty()
					or ResourceNameRules.is_safe_flat_resource_name(args[2], false))
				and _bounded_packet_int(args[3], 0, 1) != null
				and _bounded_packet_int(args[4], 0, MAX_ROOM_ID) != null
				and _bounded_packet_int(args[5], 0, MAX_ROOM_ID) != null
				and _bounded_packet_int(args[6], -1, MAX_COORDINATE) != null
				and _bounded_packet_int(args[7], -1, MAX_COORDINATE) != null
				and _bounded_packet_int(args[8], 0, MAX_ROOM_ID) != null)
		"gchat":
			return (_bounded_packet_int(args[0], 1, MAX_ROOM_ID) != null
				and _bounded_packet_int(args[2], 0, MAX_ROOM_ID) != null)
		_:
			return true


func _packet_targets_tombstoned_player(type: String, args: Array) -> bool:
	match type:
		"m", "jmp", "f", "spd", "spr", "fl", "rfl", "rrfl", "tr", "h", \
				"sys", "sys2", "se", "name", "chat":
			return _is_player_tombstoned(int(args[0]))
		_:
			return false


func _warn_packet(category: String, message: String) -> void:
	var now := Time.get_ticks_msec()
	var previous := int(_protocol_warning_times.get(category, -PROTOCOL_WARNING_INTERVAL_MSEC))
	if now - previous < PROTOCOL_WARNING_INTERVAL_MSEC:
		_protocol_warning_suppressed[category] = int(
			_protocol_warning_suppressed.get(category, 0)) + 1
		return
	var suppressed := int(_protocol_warning_suppressed.get(category, 0))
	_protocol_warning_times[category] = now
	_protocol_warning_suppressed[category] = 0
	if suppressed > 0:
		Log.warn("[EasyMultiplayer] %s (%d similar warnings suppressed)" % [message, suppressed])
	else:
		Log.warn("[EasyMultiplayer] %s" % message)


func _bounded_packet_int(value: Variant, minimum: int, maximum: int) -> Variant:
	if typeof(value) != TYPE_STRING:
		return null
	var text := value as String
	if text.length() > 32 or not text.is_valid_int():
		return null
	var parsed := int(text)
	if parsed < minimum or parsed > maximum:
		return null
	return parsed

func _handle_disconnect(args: Array) -> void:
	var id := int(args[0])
	Log.info("[EasyMultiplayer] player DISCONNECT id=%d" % id)
	_mark_player_tombstoned(id)
	_pre_spawn_identity.erase(id)
	_pending_spawn.erase(id)
	_repeating_flashes.erase(id)
	if not _players.has(id):
		return
	_players.erase(id)
	if _engine:
		_engine.mp_remove_player(id)


func _handle_clear_player(args: Array) -> void:
	var id := int(args[0])
	if id == _my_pid:
		return
	# `c` is server-owned replacement authority. It may clear only the current
	# socket/room epoch's departure tombstone; a following `m` then performs one
	# ordinary pending spawn with the canonical identity/resource record.
	if _is_player_tombstoned(id):
		_disconnected_player_tombstones.erase(id)
	_pre_spawn_identity.erase(id)
	_pending_spawn.erase(id)
	_repeating_flashes.erase(id)
	if _players.has(id):
		_players.erase(id)
		if _engine:
			_engine.mp_remove_player(id)


func _handle_move(args: Array) -> void:
	var id := int(args[0])
	if id == _my_pid:
		return
	var x := int(args[1])
	var y := int(args[2])
	if not _players.has(id):
		Log.debug("[EasyMultiplayer] late spawn for id=%d on first move" % id)
		_spawn_player(id)
		if not _players.has(id):
			return
	_players[id].x = x
	_players[id].y = y
	if _is_pending(id):
		return
	if _engine and _engine.is_running():
		_engine.mp_move_player(id, x, y)

func _handle_jump(args: Array) -> void:
	var id := int(args[0])
	if not _players.has(id):
		return
	var x := int(args[1])
	var y := int(args[2])
	_players[id].x = x
	_players[id].y = y
	if _is_pending(id):
		return
	if _engine and _engine.is_running():
		_engine.mp_jump_player(id, x, y)

func _handle_facing(args: Array) -> void:
	var id := int(args[0])
	var facing := clampi(int(args[1]), 0, 3)
	if not _players.has(id):
		return
	_players[id].facing = facing
	if _is_pending(id):
		return
	if _engine:
		_engine.mp_set_player_facing(id, facing)

func _handle_speed(args: Array) -> void:
	var id := int(args[0])
	var speed := clampi(int(args[1]), 1, 6)
	if not _players.has(id):
		return
	_players[id].speed = speed
	if _is_pending(id):
		return
	if _engine:
		_engine.mp_set_player_speed(id, speed)

func _handle_sprite(args: Array) -> void:
	var id := int(args[0])
	var spr_name := args[1] as String
	var index := clampi(int(args[2]), 0, 7)
	if not _players.has(id):
		return
	_players[id].sprite_name = spr_name
	_players[id].sprite_index = index
	player_profile_sprite_changed.emit(id, spr_name, index)
	if _is_pending(id):
		return
	if _engine:
		_engine.mp_set_player_sprite(id, spr_name, index)

func _handle_flash(args: Array) -> void:
	var id := int(args[0])
	if not _players.has(id) or _is_pending(id):
		return
	if _engine:
		_engine.mp_flash_player(id,
			int(args[1]), int(args[2]), int(args[3]), int(args[4]), int(args[5]))

func _handle_repeating_flash(args: Array) -> void:
	var id := int(args[0])
	var flash := [int(args[1]), int(args[2]), int(args[3]), int(args[4]), int(args[5])]
	if not _players.has(id):
		return
	_repeating_flashes[id] = flash
	if _is_pending(id):
		return
	if _engine:
		_engine.mp_flash_player(id, flash[0], flash[1], flash[2], flash[3], flash[4])

func _handle_remove_repeating_flash(args: Array) -> void:
	_repeating_flashes.erase(int(args[0]))

func _handle_transparency(args: Array) -> void:
	var id := int(args[0])
	var t := clampi(int(args[1]), 0, 7)
	if not _players.has(id):
		return
	_players[id].transparency = t
	if _is_pending(id):
		return
	if _engine:
		_engine.mp_set_player_transparency(id, t)

func _handle_hidden(args: Array) -> void:
	var id := int(args[0])
	var hidden := int(args[1]) == 1
	if not _players.has(id):
		return
	_players[id].hidden = hidden
	if _is_pending(id):
		return
	if _engine:
		_engine.mp_set_player_hidden(id, hidden)

func _handle_system(args: Array) -> void:
	var id := int(args[0])
	var sys_name := args[1] as String
	if id == _my_pid:
		return
	_remember_player_system_theme(id, sys_name, 1)
	if not _players.has(id):
		_cache_pre_spawn_identity(id, "system", sys_name)
		return
	var p: OtherPlayer = _players[id]
	if p.system_name == sys_name:
		return
	p.system_name = sys_name
	if _is_pending(id):
		return
	if _engine and _engine.is_running() and _engine.is_map_ready():
		_engine.mp_set_player_system_graphic(id, sys_name)

func _handle_system_theme(args: Array) -> void:
	var id := int(args[0])
	var sys_name := args[1] as String
	var stretch_mode := clampi(int(args[2]), 0, 1)
	if id == _my_pid:
		return
	_remember_player_system_theme(id, sys_name, stretch_mode)
	if not _players.has(id):
		_cache_pre_spawn_system(id, sys_name, stretch_mode)
		return
	var player := _players[id] as OtherPlayer
	var system_changed := player.system_name != sys_name
	player.system_name = sys_name
	player.system_stretch = stretch_mode
	if (system_changed and not _is_pending(id) and _engine
			and _engine.is_running() and _engine.is_map_ready()):
		_engine.mp_set_player_system_graphic(id, sys_name)

func _handle_se(args: Array) -> void:
	if not enable_sounds or mute_audio:
		return
	if _engine == null or not _engine.is_running():
		return
	
	var id := int(args[0])
	var snd_name := args[1] as String
	var snd_volume := int(args[2])
	var snd_tempo := int(args[3])
	var snd_balance := int(args[4])
	
	if not _players.has(id):
		return
	var p: OtherPlayer = _players[id]
	
	var px := _local_x
	var py := _local_y
	var ox := p.x
	var oy := p.y
	var rx := px - ox
	var ry := py - oy
	var dist := sqrt(float(rx * rx + ry * ry))
	if _INST_SET.has(snd_name):
		dist = maxf(0.0, dist - 7.0)
	
	var dist_volume := 75.0 - dist * 10.0
	var real_volume := maxi(int(dist_volume * float(snd_volume) / 100.0), 0)
	if real_volume <= 0:
		return
	
	_engine.mp_play_se(snd_name, real_volume, snd_tempo, snd_balance)

func _handle_sync_switch(args: Array) -> void:
	var sw_id := int(args[0])
	var sync_type := int(args[1])
	if sync_type >= 1 and sw_id not in _sync_switches:
		_sync_switches.append(sw_id)

func _handle_sync_variable(args: Array) -> void:
	var var_id := int(args[0])
	var sync_type := int(args[1])
	if sync_type >= 1 and var_id not in _sync_vars:
		_sync_vars.append(var_id)

func _handle_sync_event(args: Array) -> void:
	var ev_id := int(args[0])
	var trig_type := int(args[1])
	if trig_type != 1 and ev_id not in _sync_events:
		_sync_events.append(ev_id)
	if trig_type >= 1 and ev_id not in _sync_action_events:
		_sync_action_events.append(ev_id)

func _handle_sync_picture(args: Array) -> void:
	var pic_name := args[0] as String
	if pic_name not in _sync_picture_names:
		_sync_picture_names.append(pic_name)

func _handle_name_list_sync(args: Array) -> void:
	match int(args[0]):
		0: _global_sync_pic_names = args.slice(1)
		1: _global_sync_pic_pfx = args.slice(1)

func _handle_battle_anim_id_list(args: Array) -> void:
	_sync_battle_anim_ids = args.map(func(s): return int(s))

func _handle_name(args: Array) -> void:
	var id := int(args[0])
	var n := InputLimits.sanitize_nickname(args[1] as String)
	if id == _my_pid:
		return
	_touch_list_history("profile_pid:" + str(id))
	for profile in _chat_public_profiles.values():
		if int(profile.get("sender_id", 0)) == id:
			_touch_list_history("profile:" + str(profile.get("public_chat_id", "")))
			profile["display_name"] = n
	if not _players.has(id):
		_cache_pre_spawn_identity(id, "name", n)
		return
	var p: OtherPlayer = _players[id]
	if p.display_name == n:
		return
	p.display_name = n
	Log.debug("[EasyMultiplayer] player %d name='%s'" % [id, n])
	if _is_pending(id):
		return
	if _engine and _engine.is_running() and _engine.is_map_ready():
		_engine.mp_set_player_name(id, n)
		# Native ChatName recreation resets its theme. Reapply only after a real
		# nickname change; identical name packets remain fully idempotent.
		if p.system_name != "":
			_engine.mp_set_player_system_graphic(id, p.system_name)

func _handle_chat(args: Array) -> void:
	var id := int(args[0])
	var msg := args[1] as String
	if msg.length() > InputLimits.CHAT_MESSAGE_MAX_CHARACTERS:
		_warn_packet("chat_length", "Chat message exceeds %d characters from PID %d" \
				% [InputLimits.CHAT_MESSAGE_MAX_CHARACTERS, id])
		return
	var display_name := player_name
	if not _players.has(id):
		if id != _my_pid:
			_warn_packet("chat_pid", "got chat message from unknown PID: %d" % id)
			return
	else:
		display_name = _players[id].display_name
	MpEvents.on_chat_message.emit(display_name, msg)


func _handle_player_list_item2(args: Array) -> void:
	_handle_player_list_item(args)
	var request_id := int(args[0])
	if not _player_list_pending.has(request_id):
		return
	var items: Array = _player_list_pending[request_id]["items"]
	if not items.is_empty():
		items.back()["public_chat_id"] = str(args[18])
	if _plist_can_fill_history(["profile_pid:" + str(args[1]), "profile:" + str(args[18])]):
		_remember_chat_profile(str(args[18]), int(args[1]), InputLimits.sanitize_nickname(str(args[6])), true)


func _valid_chat_mentions_record(args: Array, global: bool) -> bool:
	if not _server_capabilities.has(CAPABILITY_CHAT_MENTIONS):
		return false
	var id_index := 8 if global else 4
	var text_index := id_index + 1
	if (not ChatMentions.valid_id(str(args[id_index]))
			or not _chat_sender_name_allowed(str(args[1]))
			or InputLimits.sanitize_nickname(str(args[1])) != str(args[1])):
		return false
	var legacy: Array = args.slice(0, id_index)
	legacy.append("0")
	legacy.append(args[text_index])
	if not _packet_values_are_structurally_valid("gchat4" if global else "chat3", legacy):
		return false
	var decoded: Variant = ChatMentions.decode(str(args[text_index]), str(args[text_index + 1]), str(args[text_index + 2]))
	return decoded != null and (supports_unnamed_chat() or not ChatMentions.has_unnamed(str(args[text_index]), decoded))


func _handle_chat_mentions_record(args: Array, global: bool, snapshot: bool = false) -> void:
	var id_index := 8 if global else 4
	var body := str(args[id_index + 1])
	var decoded: Variant = ChatMentions.decode(body, str(args[id_index + 2]), str(args[id_index + 3]))
	if decoded == null or body.strip_edges().is_empty():
		return
	var record := {"kind": "global" if global else "room", "sender_id": int(args[0]),
		"display_name": str(args[1]), "system_name": str(args[2]), "system_stretch": int(args[3]),
		"public_chat_id": str(args[id_index]), "text": body, "mentions": decoded,
		"mentioned_local": ChatMentions.contains_target(decoded, _my_public_chat_id)}
	if snapshot:
		record["sender_is_admin"] = str(args[id_index + 4]) == "1"
		record["mentioned_local"] = str(args[id_index + 5]) == "1"
	if global:
		record.merge({"map_id": int(args[4]), "previous_map_id": int(args[5]), "x": int(args[6]), "y": int(args[7])})
	_remember_player_system_theme(int(args[0]), str(args[2]), int(args[3]))
	_remember_chat_profile(str(args[id_index]), int(args[0]), str(args[1]))
	MpEvents.on_chat_record.emit(record)
	_request_identity_refresh(int(args[0]))


func _handle_chat_metadata(args: Array) -> void:
	var sender_id := int(args[0])
	var display_name := InputLimits.sanitize_nickname(args[1] as String)
	var system_name := args[2] as String
	var mention_target_pid := int(args[3])
	var msg := args[4] as String
	if (not _chat_sender_name_allowed(str(args[1])) or msg.strip_edges().is_empty()
			or msg.length() > InputLimits.CHAT_MESSAGE_MAX_CHARACTERS):
		return
	MpEvents.on_chat_message_metadata.emit(
		sender_id, display_name, system_name, mention_target_pid, msg)
	_request_identity_refresh(sender_id)


func _handle_chat_metadata_v2(args: Array) -> void:
	var sender_id := int(args[0])
	var system_name := args[2] as String
	_remember_player_system_theme(sender_id, system_name, int(args[3]))
	_handle_chat_metadata([
		args[0], args[1], system_name, args[4], args[5],
	])


func _handle_global_chat_raw(args: Array) -> void:
	if args.size() != 7:
		Log.warn("[EasyMultiplayer] rejected malformed raw global-chat packet")
		return
	var sender_id: Variant = _bounded_packet_int(args[0], 1, MAX_ROOM_ID)
	var map_id: Variant = _bounded_packet_int(args[2], 0, MAX_ROOM_ID)
	var prev_map_id: Variant = _bounded_packet_int(args[3], 0, MAX_ROOM_ID)
	var x: Variant = _bounded_packet_int(args[4], -1, MAX_COORDINATE)
	var y: Variant = _bounded_packet_int(args[5], -1, MAX_COORDINATE)
	if sender_id == null or map_id == null or prev_map_id == null or x == null or y == null:
		Log.warn("[EasyMultiplayer] rejected invalid raw global-chat location context")
		return
	var display_name := InputLimits.sanitize_nickname(args[1] as String)
	var msg := args[6] as String
	if not _chat_sender_name_allowed(str(args[1])):
		return
	if msg.strip_edges().is_empty() or msg.length() > InputLimits.CHAT_MESSAGE_MAX_CHARACTERS:
		return
	MpEvents.on_global_chat_message_raw.emit(
		int(sender_id),
		display_name,
		int(map_id),
		int(prev_map_id),
		int(x),
		int(y),
		msg
	)


func _handle_global_chat_metadata(args: Array) -> void:
	var sender_id := int(args[0])
	var display_name := InputLimits.sanitize_nickname(args[1] as String)
	var system_name := args[2] as String
	var map_id := int(args[3])
	var prev_map_id := int(args[4])
	var x := int(args[5])
	var y := int(args[6])
	var mention_target_pid := int(args[7])
	var msg := args[8] as String
	if (not _chat_sender_name_allowed(str(args[1])) or msg.strip_edges().is_empty()
			or msg.length() > InputLimits.CHAT_MESSAGE_MAX_CHARACTERS):
		return
	MpEvents.on_global_chat_message_metadata.emit(
		sender_id, display_name, system_name, map_id, prev_map_id, x, y,
		mention_target_pid, msg)
	_request_identity_refresh(sender_id)


func _handle_global_chat_metadata_v2(args: Array) -> void:
	var sender_id := int(args[0])
	var system_name := args[2] as String
	_remember_player_system_theme(sender_id, system_name, int(args[3]))
	_handle_global_chat_metadata([
		args[0], args[1], system_name, args[4], args[5], args[6], args[7], args[8], args[9],
	])


func _request_identity_refresh(sender_id: int) -> void:
	var now := Time.get_ticks_msec()
	if (_known_player_roles.has(sender_id) and _identity_snapshot_msec >= 0
			and now - _identity_snapshot_msec < IDENTITY_REFRESH_MSEC):
		return
	if now - _last_identity_request_msec < IDENTITY_REFRESH_MSEC:
		return
	if request_player_list() > 0:
		_last_identity_request_msec = now


func _handle_global_chat_legacy(args: Array) -> void:
	# Old servers provided localized labels instead of raw context. Preserve the
	# legacy signal and also normalize what can be recovered into the raw signal.
	if args.size() != 6:
		Log.warn("[EasyMultiplayer] rejected malformed legacy global-chat packet")
		return
	var sender_id: Variant = _bounded_packet_int(args[0], 1, MAX_ROOM_ID)
	var map_id: Variant = _bounded_packet_int(args[2], 0, MAX_ROOM_ID)
	if sender_id == null or map_id == null:
		return
	var display_name := InputLimits.sanitize_nickname(args[1] as String)
	var room_japanese := args[3] as String
	var room_english := args[4] as String
	var msg := args[5] as String
	if not _chat_sender_name_allowed(str(args[1])):
		return
	if msg.strip_edges().is_empty() or msg.length() > InputLimits.CHAT_MESSAGE_MAX_CHARACTERS:
		return
	MpEvents.on_global_chat_message.emit(
		int(sender_id),
		display_name,
		int(map_id),
		room_japanese,
		room_english,
		msg
	)
	MpEvents.on_global_chat_message_raw.emit(
		int(sender_id),
		display_name,
		int(map_id),
		0,
		-1,
		-1,
		msg
	)

func _send_room_join_state() -> void:
	_arm_attempt_deadline()
	var strict_room_barrier := _server_capabilities.has(CAPABILITY_ROOM_BARRIER)
	if strict_room_barrier:
		_conn.send_packet("sr", [str(_room_id)])
	_send_basic_data(strict_room_barrier)
	if not strict_room_barrier:
		# Preserve the original client order for servers that do not explicitly
		# negotiate the strict room barrier.
		_conn.send_packet("sr", [str(_room_id)])


func _send_private_room_join_state() -> void:
	_arm_attempt_deadline()
	# A privacy-aware server treats sr as a private CU subscription and replies
	# with ri without waiting for the public spawn credential (`m`).
	_conn.send_packet("sr", [str(_room_id)])


func _send_privacy_request() -> void:
	if (not _session_connected or _conn == null
			or not _conn.is_connected_to_server()
			or not _server_capabilities.has(CAPABILITY_PRIVACY)):
		return
	if _privacy_sequence >= MAX_ATTEMPT_SEQUENCE:
		_privacy_sequence = 0
	_privacy_sequence += 1
	_privacy_pending_sequence = _privacy_sequence
	_privacy_request_in_flight = true
	_privacy_transition_pending = true
	_privacy_room_join_queued_sequence = 0
	_set_room_ready(false)
	_switching_room = true
	_arm_attempt_deadline()
	_conn.send_packet("privacy", [
		"1" if _privacy_desired else "0",
		str(_privacy_pending_sequence),
	])
	# Privacy never participates in either room or global chat. Public chat is
	# restored only after the matching public ri barrier.
	_conn.send_packet("chaton", ["0"])
	_emit_privacy_state_changed()


func _queue_room_join_after_privacy_accept(request_sequence: int) -> void:
	if (_privacy_room_join_queued_sequence == request_sequence
			or request_sequence != _privacy_pending_sequence):
		return
	_privacy_room_join_queued_sequence = request_sequence
	_switching_room = true
	_set_room_ready(false)
	# Refresh the complete public snapshot without transmitting callbacks ahead
	# of its privacy/sr barriers.
	_refresh_local_player_snapshot_without_sending()
	if _privacy_authoritative:
		_send_private_room_join_state()
		_conn.send_packet("chaton", ["0"])
	else:
		_send_room_join_state()
		_conn.send_packet("chaton", ["1" if enable_chat else "0"])


func _refresh_local_player_snapshot_without_sending() -> void:
	if _engine == null or not _engine.is_running():
		return
	var was_connected := _session_connected
	_session_connected = false
	_engine.mp_sync_local_player()
	_session_connected = was_connected


func _arm_attempt_deadline() -> void:
	# Physical WebSocket setup is deliberately included: EasyConnection does not
	# report open until poll(), so requiring an already-open socket here would
	# leave a black-holed CONNECTING attempt without any deadline.
	if _conn == null or not _session_active or _current_map_id == 0:
		return
	if _establishing_connection and _attempt_deadline_msec > 0:
		return
	var timeout := CONNECTION_ATTEMPT_TIMEOUT_MSEC if _establishing_connection else ROOM_OPERATION_TIMEOUT_MSEC
	_attempt_deadline_msec = Time.get_ticks_msec() + timeout
	_attempt_deadline_generation = _connection_generation
	_attempt_deadline_socket_epoch = _socket_epoch


func _finish_connection_establishment() -> void:
	_clear_attempt_deadline()
	_establishing_connection = false
	_connection_attempts = 0
	_reconnecting = false


func is_legacy_privacy_hold() -> bool:
	return _session_connected and _privacy_desired and not supports_privacy()


func _clear_attempt_deadline() -> void:
	_attempt_deadline_msec = 0
	_attempt_deadline_generation = -1
	_attempt_deadline_socket_epoch = -1


func _check_attempt_deadline() -> void:
	if _attempt_deadline_msec <= 0:
		return
	if (_attempt_deadline_generation != _connection_generation
			or _attempt_deadline_socket_epoch != _socket_epoch):
		_clear_attempt_deadline()
		return
	if Time.get_ticks_msec() < _attempt_deadline_msec:
		return
	_clear_attempt_deadline()
	Log.warn("[EasyMultiplayer] connection/room handshake timed out — reconnecting")
	# Reuse the ordinary transport-failure path so backoff, generation and epoch
	# handling remain single-sourced.
	_conn.close()
	_socket_epoch = _conn.get_socket_epoch()
	_on_ws_disconnected(1006, _socket_epoch)


func _begin_privacy_transition_gate() -> void:
	_cancel_list_queries()
	_privacy_transition_pending = true
	_privacy_request_in_flight = false
	_privacy_room_join_queued_sequence = 0
	_switching_room = true
	_set_room_ready(false)
	_set_room_presence_unknown()
	_begin_privacy_room_epoch()


func _begin_privacy_room_epoch() -> void:
	_begin_room_epoch()
	if _engine:
		if _engine.has_method("mp_clear_remote_player_objects_immediate"):
			_engine.call("mp_clear_remote_player_objects_immediate")
		else:
			_engine.mp_clear_remote_players_immediate()
	_players.clear()
	_pending_spawn.clear()
	_pre_spawn_identity.clear()
	_repeating_flashes.clear()


func _send_basic_data(position_last: bool) -> void:
	if not _session_connected:
		return
	Log.debug("[EasyMultiplayer] sending basic data pos=(%d,%d) spr='%s'[%d]" \
		% [_local_x, _local_y, _local_sprite_name, _local_sprite_index])
	if not position_last:
		_conn.send_packet("m", [str(_local_x), str(_local_y)])
	_conn.send_packet("spr", [_sanitize(_local_sprite_name), str(_local_sprite_index)])
	_conn.send_packet("f", [str(_local_facing)])
	_conn.send_packet("spd", [str(_local_speed)])
	_conn.send_packet("h", [str(1 if _local_hidden else 0)])
	_conn.send_packet("tr", [str(_local_transparency)])
	var safe_player_name := InputLimits.sanitize_nickname(player_name)
	if safe_player_name != "":
		_conn.send_packet("name", [_sanitize(safe_player_name)])
	if _local_system_name != "":
		_send_local_system_packet()
	if position_last:
		_conn.send_packet("m", [str(_local_x), str(_local_y)])

func _update_frame() -> void:
	if (_last_flash_frame_index > -1
			and not _last_frame_flash.is_empty()
			and _frame_index > _last_flash_frame_index):
		_conn.send_packet("rrfl", [])
		_last_flash_frame_index = -1
		_last_frame_flash = []
	
	_frame_index += 1
	
	for id in _repeating_flashes:
		if _players.has(id) and _engine:
			var f: Array = _repeating_flashes[id]
			_engine.mp_flash_player(id, f[0], f[1], f[2], f[3], f[4])
	
	if not _switching_room and not _switched_room:
		_switched_room = true

func _is_pending(id: int) -> bool:
	return id in _pending_spawn

func _room_url(room_id: int) -> String:
	return build_room_url(server_url, room_id)


func _begin_room_epoch() -> void:
	_room_epoch += 1
	_disconnected_player_tombstones.clear()
	_tombstone_resync_pending = false


func _mark_player_tombstoned(id: int) -> void:
	_disconnected_player_tombstones[id] = {
		"socket_epoch": _socket_epoch,
		"room_epoch": _room_epoch,
	}
	_request_same_room_tombstone_resync()


func _request_same_room_tombstone_resync() -> void:
	if (_tombstone_resync_pending
			or _disconnected_player_tombstones.size() < PLAYER_TOMBSTONE_RESYNC_THRESHOLD):
		return
	if (_conn == null or not _conn.is_connected_to_server()
			or not _session_active or not _session_connected or not _room_ready
			or _switching_room or _room_id < 0 or _current_map_id == 0
			or _room_id != _current_map_id or _privacy_blocks_public_data()):
		return
	_tombstone_resync_pending = true
	_conn.send_packet("sr", [str(_room_id)])
	_arm_attempt_deadline()


func _is_player_tombstoned(id: int) -> bool:
	if not _disconnected_player_tombstones.has(id):
		return false
	var tombstone: Dictionary = _disconnected_player_tombstones[id]
	return (int(tombstone.get("socket_epoch", -1)) == _socket_epoch
		and int(tombstone.get("room_epoch", -1)) == _room_epoch)


func _initialize(clear_all_outbound: bool = false) -> void:
	_set_session_connected(false)
	_set_room_ready(false)
	_begin_room_epoch()
	_last_sent_previous_map_id = -1
	_clear_server_variables()
	if _conn:
		if clear_all_outbound:
			_cancel_list_queries()
			_on_chat_queue_discarded(_conn.clear_queue())
		else:
			_on_chat_queue_discarded(_conn.clear_room_queue())
	if _engine:
		_engine.mp_clear_remote_players_immediate()
	_players.clear()
	_pending_spawn.clear()
	_pre_spawn_identity.clear()
	_sync_switches.clear()
	_sync_vars.clear()
	_sync_events.clear()
	_sync_action_events.clear()
	_sync_picture_names.clear()
	_sync_picture_cache.clear()
	_repeating_flashes.clear()
	_frame_index = 0
	_last_flash_frame_index = -1
	_last_frame_flash = []


func _remember_player_system_theme(id: int, system_name: String, stretch_mode: int, from_list: bool = false) -> void:
	if id <= 0:
		return
	if not from_list:
		_touch_list_history("theme:" + str(id))
	_player_system_themes.erase(id)
	_player_system_themes[id] = {
		"system_name": system_name,
		"system_stretch": clampi(stretch_mode, 0, 1),
	}
	while _player_system_themes.size() > MAX_PLAYER_SYSTEM_THEME_HISTORY:
		_player_system_themes.erase(_player_system_themes.keys()[0])


func _remember_admin_subject(pid: int, group_id: String) -> void:
	if pid <= 0 or group_id.is_empty():
		return
	_admin_subject_by_pid_history.erase(pid)
	_admin_subject_by_pid_history[pid] = group_id
	while _admin_subject_by_pid_history.size() > MAX_ADMIN_PID_HISTORY:
		_admin_subject_by_pid_history.erase(_admin_subject_by_pid_history.keys()[0])


func _cache_pre_spawn_system(id: int, system_name: String, stretch_mode: int) -> void:
	_cache_pre_spawn_identity(id, "system", system_name)
	if not _pre_spawn_identity.has(id):
		return
	var identity := _pre_spawn_identity[id] as Dictionary
	identity["system_stretch"] = clampi(stretch_mode, 0, 1)
	_pre_spawn_identity[id] = identity


func _cache_pre_spawn_identity(id: int, field: String, value: String) -> void:
	if id == _my_pid or _is_player_tombstoned(id):
		return
	if (not _pre_spawn_identity.has(id)
			and _players.size() + _pre_spawn_identity.size() >= MAX_REMOTE_PLAYERS):
		_warn_packet("pre_spawn_identity_limit",
			"ignored pre-spawn identity beyond the %d-player client limit" % MAX_REMOTE_PLAYERS)
		return
	var identity: Dictionary = _pre_spawn_identity.get(id, {
		"name_seen": false,
		"display_name": "",
		"system_seen": false,
		"system_name": "",
		"system_stretch": 1,
	})
	if field == "name":
		identity.name_seen = true
		identity.display_name = value
	else:
		identity.system_seen = true
		identity.system_name = value
	_pre_spawn_identity[id] = identity


func _spawn_player(id: int) -> void:
	if id == _my_pid or _players.has(id) or _is_player_tombstoned(id):
		return
	if _players.size() >= MAX_REMOTE_PLAYERS:
		_warn_packet("remote_player_limit",
			"ignored remote player beyond the %d-player client limit" % MAX_REMOTE_PLAYERS)
		return
	Log.debug("[EasyMultiplayer] queuing spawn for id=%d" % id)
	var p := OtherPlayer.new()
	p.id = id
	if _pre_spawn_identity.has(id):
		var identity: Dictionary = _pre_spawn_identity[id]
		if bool(identity.get("name_seen", false)):
			p.display_name = identity.get("display_name", "") as String
		if bool(identity.get("system_seen", false)):
			p.system_name = identity.get("system_name", "") as String
			p.system_stretch = clampi(int(identity.get("system_stretch", 1)), 0, 1)
		_pre_spawn_identity.erase(id)
	_players[id] = p
	if id not in _pending_spawn:
		_pending_spawn.append(id)

func _do_mp_add_player(id: int) -> bool:
	if not _players.has(id):
		return true
	if _engine == null or not _engine.is_running():
		return false
	if not _engine.is_map_ready():
		return false
	var p: OtherPlayer = _players[id]
	Log.info("[EasyMultiplayer] spawning id=%d pos=(%d,%d) spr='%s'[%d]" \
		% [id, p.x, p.y, p.sprite_name, p.sprite_index])
	_engine.mp_add_player(id, p.x, p.y, p.sprite_name, p.sprite_index, p.facing, p.speed)
	if p.transparency > 0:
		_engine.mp_set_player_transparency(id, p.transparency)
	if p.hidden:
		_engine.mp_set_player_hidden(id, true)
	if p.display_name != "":
		_engine.mp_set_player_name(id, p.display_name)
	if p.system_name != "":
		_engine.mp_set_player_system_graphic(id, p.system_name)
	return true

func _retry_pending_spawns() -> void:
	if _pending_spawn.is_empty() or _engine == null or not _engine.is_running():
		return
	var ids := _pending_spawn.duplicate()
	_pending_spawn.clear()
	for id in ids:
		if _players.has(id):
			if not _do_mp_add_player(id):
				if id not in _pending_spawn:
					_pending_spawn.append(id)

func _sanitize(s: String) -> String:
	return s.replace(EasyConnection.PARAM_DELIM, "").replace(EasyConnection.MSG_DELIM, "")
