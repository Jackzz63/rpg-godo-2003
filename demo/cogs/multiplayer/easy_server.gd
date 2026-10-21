class_name EasyServer
extends Node

const InputLimits := preload("res://cogs/input_limits.gd")
const ResourceNameRules := preload("res://cogs/multiplayer/resource_name_rules.gd")
const AdminStoreScript := preload("res://cogs/multiplayer/admin_store.gd")
const PunishmentStoreScript := preload("res://cogs/multiplayer/punishment_store.gd")
const ServerBadSounds := preload("res://cogs/multiplayer/server_bad_sounds.gd")
const StatusProtocol := preload("res://cogs/multiplayer/server_status_protocol.gd")
const StatusServiceScript := preload("res://cogs/multiplayer/server_status_service.gd")

@export var port: int = 42424
@export var bind_address: String = "*"
@export var auto_start: bool = false
@export var global_vars_mode: String = ""
@export var bad_sounds_profile: String = ""
@export var admins_file: String = ""
@export var punishments_file: String = ""
@export var audit_file: String = ""
@export var punishment_address_source: String = "direct"

const PARAM_DELIM := "\uFFFF" # separates fields within one message
const MSG_DELIM := "\uFFFE" # separates multiple messages in one ws frame
const MAX_FRAME_BYTES := 65536
const MAX_STRICT_MESSAGES_PER_FRAME := 128
const MAX_LEGACY_MESSAGES_PER_FRAME := 1024
const MAX_OUTBOUND_MESSAGES_PER_FRAME := 128
const MAX_MESSAGE_CHARS := 4096
const MAX_PACKET_ARGS := 32
const MAX_ARG_CHARS := 1024
const MAX_PACKET_TYPE_CHARS := 16
const MAX_PROTOCOL_COUNTER := 2147483647
const MAX_ROOM_ID := MAX_PROTOCOL_COUNTER
const MAX_COORDINATE := 2147483647
const MIN_SIGNED_INT := -2147483648

# Deliberately generous operational ceilings. Short, legitimate bursts are
# processed fairly across later ticks; only sustained traffic above the token
# buckets is discarded, never punished with a disconnect.
const MAX_CONNECTIONS := 2048
const DEFAULT_MAX_PENDING_ADMISSIONS := 512
const MAX_ACCEPTS_PER_TICK := 64
const HANDSHAKE_TIMEOUT_MSEC := 60000
const HEARTBEAT_INTERVAL_SECONDS := 30.0
const MAX_FRAMES_PER_PEER_PER_TICK := 4
const MAX_FRAMES_PER_TICK := 4096
const MAX_MESSAGES_PER_TICK := 8192
const MAX_BYTES_PER_TICK := 8 * 1024 * 1024
const FRAME_TOKEN_RATE := 240.0
const FRAME_TOKEN_BURST := 960.0
const MESSAGE_TOKEN_RATE := 4096.0
const MESSAGE_TOKEN_BURST := 8192.0
const BYTE_TOKEN_RATE := 4.0 * 1024.0 * 1024.0
const BYTE_TOKEN_BURST := 8.0 * 1024.0 * 1024.0
const WARNING_INTERVAL_MSEC := 5000
const GLOBAL_CHAT_COOLDOWN_MSEC := 2000
const ROOM_CHAT_COOLDOWN_MSEC := 2000
const MAX_PENDING_GCHAT_STATUS_PACKETS := 8
const PRIVACY_COOLDOWN_MSEC := 1000
const SAME_ROOM_RESYNC_INTERVAL_MSEC := 1000
const IDENTITY_RECOVERY_RETRY_MSEC := 250
const PRESENCE_REFRESH_MSEC := 5000
const MAX_OUTBOUND_BATCH_BYTES := 4088
const MAX_TRANSIENT_BATCHES := 256
const MAX_LIST_SNAPSHOT_BYTES := 32 * 1024 * 1024
const MAX_LIST_SNAPSHOTS_BYTES := 64 * 1024 * 1024
const MAX_OUTBOUND_FRAME_BYTES := 65535
const LIST_QUERY_IDLE_MSEC := 10000
const LIST_QUERY_TOTAL_MSEC := 60000
const MAX_OUTBOUND_BATCHES_PER_PEER_PER_TICK := 64
const RESUME_SESSION_GRACE_MSEC := 120000
const SESSION_REPLACED_CLOSE_CODE := 4001
const CLIENT_UPDATE_REQUIRED_CLOSE_CODE := 4003
const INVALID_INSTALL_IDENTITY_CLOSE_CODE := 4004
const RESTART_EXIT_CODE := 75
const MAX_MODERATION_DURATION_SECONDS := 30 * 24 * 60 * 60
const MAX_MUTE_DURATION_SECONDS := 7 * 24 * 60 * 60
const MODERATION_STATUS_SYNC_INTERVAL_MSEC := 10000
const MODERATION_EXPIRY_CHECK_INTERVAL_MSEC := 1000
const PUNISHMENT_STORE_MAINTENANCE_INTERVAL_MSEC := 5000
const AUTH_FAILURE_LIMIT := 5
const AUTH_FAILURE_WINDOW_MSEC := 10 * 60 * 1000
const AUTH_BLOCK_MSEC := 10 * 60 * 1000
const AUTH_FAILURE_CLEANUP_INTERVAL_MSEC := 60 * 1000
const MAX_AUTH_FAILURE_SUBJECTS := 8192
const AUTH_RATE_LIMIT_REPLY_INTERVAL_MSEC := 1000
const PUNISHMENT_ADDRESS_DISABLED := "disabled"
const PUNISHMENT_ADDRESS_DIRECT := "direct"
const PUNISHMENT_ADDRESS_NGINX_URI_V1 := "nginx_uri_v1"
const PUNISHMENT_ADDRESS_DIRECT_OR_NGINX_URI_V1 := "direct_or_nginx_uri_v1"
const VALID_PUNISHMENT_ADDRESS_SOURCES := [
	PUNISHMENT_ADDRESS_DISABLED,
	PUNISHMENT_ADDRESS_DIRECT,
	PUNISHMENT_ADDRESS_NGINX_URI_V1,
	PUNISHMENT_ADDRESS_DIRECT_OR_NGINX_URI_V1,
]
const NGINX_URI_V1_LOOPBACK := "127.0.0.1"
const NGINX_URI_V1_HOST := "rpg-proxy.internal"
const NGINX_URI_V1_PATH := "/__rpg_proxy_v1"
const SERVER_CAPABILITIES := [
	"presence1", "gchat_ack1", "chat_ack1", "room_barrier1", "session_resume1", "privacy1", "admin3",
	"chat_meta1", "moderation3", "player_list1", "list_query1", "system_theme1", "system_theme2",
	"install_identity1", "chat_mentions1", "chat_snapshot1", "unnamed_chat1"]
const ChatMentions := preload("res://cogs/chat_mentions.gd")

@export var max_connections: int = MAX_CONNECTIONS
@export var max_pending_admissions: int = DEFAULT_MAX_PENDING_ADMISSIONS
var exit_process_on_protocol_limit: bool = false

enum ProtocolMode {
	UNKNOWN,
	STRICT,
	LEGACY,
}

enum OrderedOutputKind {
	NONE,
	ROOM_BARRIER,
	GLOBAL_BATCH,
	ROOM_STATE,
	PRESENCE,
	ROOM_BATCH,
	LIST_FRAME,
}

enum SnapshotQueueResult {
	EMPTY,
	QUEUED,
	DEFERRED,
}

var _list_snapshot_bytes := 0
var _list_peer_cursor := 0
var _tcp: TCPServer = null
var _running: bool = false
var _bad_sound_names: Dictionary = {}
var _next_id: int = 1
var _peers: Dictionary = {}
var _pending_transports: Array[PendingTransport] = []
var _status_service := StatusServiceScript.new()
var _greeted: Dictionary = {}
var _room_members: Dictionary = {}
var _joined_player_count: int = 0
var _fair_peer_cursor: int = 0
var _presence_revision: int = 0
var _presence_global_dirty: bool = false
var _presence_dirty_rooms: Dictionary = {}
var _next_presence_refresh_msec: int = 0
var _gchat_ready_heap: Array = []
var _pending_privacy_updates: Dictionary = {}
var _pending_same_room_resyncs: Dictionary = {}
var _pending_identity_recoveries: Dictionary = {}
var _resume_sessions: Dictionary = {}
var _public_chat_sessions: Dictionary = {}
var _global_variables: GlobalVariableService = null
var _admin_store: AdminStore = null
var _punishment_store: PunishmentStore = null
var _auth_failures_by_subject: Dictionary = {}
var _next_auth_failure_cleanup_msec: int = 0
var _auth_failure_capacity_rejects: int = 0
var _auth_rate_limit_replies_suppressed: int = 0
var _server_namespace: String = ""
var _moderation_revision: int = 0
var _next_moderation_sync_msec: int = 0
var _next_moderation_expiry_check_msec: int = 0
var _next_punishment_maintenance_msec: int = 0
var _shutdown_deadline_msec: int = 0
var _shutdown_restart: bool = false
var _shutdown_message: String = ""
var _next_shutdown_notice_second: int = -1
var _shutdown_origin: String = ""
var _protocol_limit_reached: bool = false
var _protocol_limit_reason: String = ""
var _protocol_limit_shutdown_scheduled: bool = false

class ResumeSession:
	var token: String = ""
	var public_chat_id: String = ""
	var installation_identity: String = ""
	var current_pid: int = -1
	var highest_attempt: int = 0
	var expires_msec: int = 0
	var gchat_ready_msec: int = 0
	var chat_ready_msec: int = 0
	var privacy_mode: int = 0
	var privacy_requested: int = 0
	var privacy_request_seq: int = 0
	var privacy_revision: int = 0
	var privacy_cooldown_until_msec: int = 0
	var privacy_pending: bool = false

class PendingTransport:
	var ws: WebSocketPeer = null
	var transport_address: String = ""
	var accepted_msec: int = 0


class PeerEntry:
	var id: int = 0
	var ws: WebSocketPeer = null
	var room_id: int = -1
	var announced_room: int = -1
	var room_epoch: int = 0
	var committed_room_epoch: int = -1
	var protocol_mode: int = ProtocolMode.UNKNOWN
	var capabilities_received: bool = false
	var room_barrier_capable: bool = false
	var resume_capable: bool = false
	var resume_complete: bool = true
	var resume_token: String = ""
	var resume_attempt: int = 0
	var superseded: bool = false
	var detaching: bool = false
	var resume_deadline_msec: int = 0
	var prev_map_id: int = 0
	var x: int = -1
	var y: int = -1
	var position_seen: bool = false
	var facing: int = 2
	var speed: int = 4
	var sprite_name: String = ""
	var sprite_idx: int = 0
	var hidden: bool = false
	var transparency: int = 0
	var sys_name: String = ""
	var system_stretch: int = 1
	var display_name: String = ""
	var chat_enabled: bool = false # p4o-a7o: off by default
	var accepted_msec: int = 0
	var ingress_last_msec: int = 0
	var frame_tokens: float = 0.0
	var message_tokens: float = 0.0
	var byte_tokens: float = 0.0
	var warning_times: Dictionary = {}
	var presence_capable: bool = false
	var gchat_ack_capable: bool = false
	var chat_ack_capable: bool = false
	var gchat_ready_msec: int = 0
	var chat_ready_msec: int = 0
	var privacy_capable: bool = false
	var admin_capable: bool = false
	var chat_metadata_capable: bool = false
	var chat_mentions_capable: bool = false
	var chat_snapshot_capable: bool = false
	var unnamed_chat_capable: bool = false
	var moderation_capable: bool = false
	var player_list_capable: bool = false
	var system_theme_capable: bool = false
	var system_theme_sync_capable: bool = false
	var install_identity_capable: bool = false
	var install_identity_complete: bool = false
	var installation_identity: String = ""
	var admin_id: String = ""
	var admin_auth_connection_failure: Dictionary = {}
	var next_admin_auth_rate_limit_reply_msec: int = 0
	var transport_address: String = ""
	var punishment_address: String = ""
	var punishment_address_source: String = ""
	var muted_until_unix: int = 0
	var banned_until_unix: int = 0
	var muted_permanent: bool = false
	var banned_permanent: bool = false
	var muted_network_scope: bool = false
	var banned_network_scope: bool = false
	var privacy_pre_ban_mode: int = -1
	var privacy_mode: int = 0
	var privacy_requested: int = 0
	var privacy_request_seq: int = 0
	var privacy_revision: int = 0
	var privacy_cooldown_until_msec: int = 0
	var privacy_pending: bool = false
	var private_room_id: int = -1
	var needs_revive: bool = false
	var same_room_resync_room_id: int = -1
	var last_same_room_resync_msec: int = 0
	var same_room_resync_due_msec: int = 0
	var same_room_snapshot_in_flight: bool = false
	# Per-recipient, room-epoch-scoped recovery for canonical player identity.
	# Each dirty value is [latest_state_revision, latest_required_clear_revision].
	var identity_recovery_dirty: Dictionary = {}
	var identity_recovery_revision: int = 0
	var identity_recovery_due_msec: int = 0
	var identity_recovery_in_flight: bool = false
	var identity_recovery_fence_batch_id: int = 0
	var identity_recovery_fence_state_revisions: Dictionary = {}
	var identity_recovery_fence_clear_revisions: Dictionary = {}
	var pending_control: Dictionary = {}
	var pending_gchat_status: Array = []
	var pending_chat_status: Array = []
	var pending_privacy_status: Array = []
	var pending_room_barrier: String = ""
	var pending_room_barrier_epoch: int = -1
	var pending_room_barrier_sequence: int = 0
	var pending_room_state: Dictionary = {}
	var pending_presence: String = ""
	var pending_presence_epoch: int = -1
	var pending_presence_sequence: int = 0
	var global_batches: Array = []
	var global_batch: String = ""
	var global_batch_messages: int = 0
	var global_batch_sequence: int = 0
	var room_batches: Array = []
	var room_batch: String = ""
	var room_batch_messages: int = 0
	var room_batch_sequence: int = 0
	var next_room_batch_id: int = 1
	var snapshot_fence_batch_id: int = 0
	var list_query_capable := false
	var list_waiting: Dictionary = {}
	var list_snapshot: Dictionary = {}
	var list_frame := PackedByteArray()
	var list_frame_sequence := 0
	var list_frame_end := 0
	var room_sync: Dictionary = {}
	var room_sync_last_kind := ""
	var room_sync_produced := 0
	var next_output_sequence: int = 1

func _ready() -> void:
	if auto_start:
		start()

func _exit_tree() -> void:
	stop()

func _process(_delta: float) -> void:
	if not _running:
		return
	_process_scheduled_shutdown()
	if not _running:
		return
	if _global_variables:
		_global_variables.poll()
	var accepted_this_tick := 0
	while (not _protocol_limit_reached
			and accepted_this_tick < MAX_ACCEPTS_PER_TICK
			and _tcp.is_connection_available()):
		_accept_connection(_tcp.take_connection())
		accepted_this_tick += 1
	
	var to_remove: Array = []
	var open_pids: Array = []
	var now_msec := Time.get_ticks_msec()
	_process_auth_failure_cleanup(now_msec)
	_status_service.poll(now_msec, _joined_player_count)
	_poll_pending_transports(now_msec)
	for pid in _peers.keys():
		var entry: PeerEntry = _peers[pid]
		entry.ws.poll()
		match entry.ws.get_ready_state():
			WebSocketPeer.STATE_OPEN:
				if not _greeted.get(pid, false):
					_greeted[pid] = true
					_on_peer_open(pid, entry)
				if not _peers.has(pid):
					continue
				if (not _peer_has_public_admission_capabilities(entry)
						and now_msec - entry.accepted_msec >= HANDSHAKE_TIMEOUT_MSEC):
					_warn_peer(pid, "identity_timeout",
						"[EasyServer] peer %d admission identity timed out" % pid,
						now_msec)
					entry.ws.close(
						CLIENT_UPDATE_REQUIRED_CLOSE_CODE, "identity required")
					to_remove.append(pid)
					continue
				if (entry.resume_capable
						and not entry.resume_complete
						and now_msec >= entry.resume_deadline_msec):
					_warn_peer(pid, "resume_timeout",
						"[EasyServer] peer %d resume handshake timed out" % pid,
						now_msec)
					entry.ws.close(1008, "resume handshake timeout")
					to_remove.append(pid)
					continue
				_process_room_chat_ready(entry, now_msec)
				open_pids.append(pid)
			WebSocketPeer.STATE_CLOSED:
				to_remove.append(pid)
			_:
				if now_msec - entry.accepted_msec >= HANDSHAKE_TIMEOUT_MSEC:
					_warn_peer(pid, "handshake_timeout",
						"[EasyServer] peer %d handshake timed out" % pid, now_msec)
					entry.ws.close(1008, "handshake timeout")
					to_remove.append(pid)

	_expire_resume_sessions(now_msec)
	_process_open_peer_frames(open_pids, now_msec)
	
	for pid in to_remove:
		_on_peer_closed(pid)

	_process_due_global_chat_ready(now_msec)
	_process_due_privacy_updates(now_msec)
	_process_moderation_status(now_msec)
	_process_due_same_room_resyncs(now_msec)
	_process_due_identity_recoveries(now_msec)
	_flush_presence_updates(now_msec)
	_schedule_protocol_limit_shutdown()
	_flush_pending_outputs()

func prepare_local_host_admin() -> Dictionary:
	if not _running or _admin_store == null:
		return {"ok": false, "error": "本地主机管理员存储尚未就绪。"}
	return _admin_store.get_or_create_local_host()


func start() -> bool:
	if _running:
		return true
	if max_connections < 1 or max_connections > MAX_CONNECTIONS:
		Log.server_error("[EasyServer] FATAL invalid max_connections=%d allowed=1..%d" \
			% [max_connections, MAX_CONNECTIONS])
		return false
	if max_pending_admissions < 1 or max_pending_admissions > max_connections:
		Log.server_error(("[EasyServer] FATAL invalid max_pending_admissions=%d "
			+ "allowed=1..%d") % [max_pending_admissions, max_connections])
		return false
	punishment_address_source = punishment_address_source.strip_edges().to_lower()
	if punishment_address_source not in VALID_PUNISHMENT_ADDRESS_SOURCES:
		Log.server_error("[EasyServer] FATAL invalid punishment_address_source=%s" \
			% punishment_address_source)
		return false
	# Validate read-only resources before creating management data or listening.
	# Keep the result local so a failed start never commits an active filter.
	var sound_profile := ServerBadSounds.load_profile(bad_sounds_profile)
	if not bool(sound_profile["ok"]):
		Log.server_error("[EasyServer] FATAL bad_sounds profile=%s error=%s" \
			% [bad_sounds_profile, str(sound_profile["error"])])
		return false
	if not admins_file.is_empty():
		_admin_store = AdminStoreScript.new()
		if not _admin_store.load_or_create(admins_file):
			Log.server_error("[EasyServer] FATAL admins_file error=%s" % _admin_store.last_error)
			_admin_store = null
			return false
	if not punishments_file.is_empty():
		_punishment_store = PunishmentStoreScript.new()
		if not _punishment_store.load_or_create(punishments_file):
			Log.server_error("[EasyServer] FATAL punishments_file error=%s" % _punishment_store.last_error)
			_punishment_store = null
			_admin_store = null
			return false
		_server_namespace = _punishment_store.get_server_namespace()
	else:
		# Identity negotiation remains a mandatory admission boundary even when a
		# development server has disabled persistent moderation storage.
		_server_namespace = Crypto.new().generate_random_bytes(32).hex_encode()
	_tcp = TCPServer.new()
	var err := _tcp.listen(port, bind_address)
	if err != OK:
		Log.server_error("[EasyServer] FATAL listen_failed bind=%s port=%d error=%s" \
			% [bind_address, port, error_string(err)])
		_tcp = null
		_admin_store = null
		_punishment_store = null
		return false
	_bad_sound_names = sound_profile["names"]
	_running = true
	_status_service.configure(_verify_status_auth)
	if not bad_sounds_profile.is_empty():
		Log.server_info("[EasyServer] bad_sounds profile=%s names=%d" \
			% [bad_sounds_profile, _bad_sound_names.size()])
	var local_port := _tcp.get_local_port()
	var started_msec := Time.get_ticks_msec()
	_next_presence_refresh_msec = started_msec + PRESENCE_REFRESH_MSEC
	_next_auth_failure_cleanup_msec = started_msec + AUTH_FAILURE_CLEANUP_INTERVAL_MSEC
	_auth_failure_capacity_rejects = 0
	_auth_rate_limit_replies_suppressed = 0
	_next_moderation_sync_msec = started_msec + MODERATION_STATUS_SYNC_INTERVAL_MSEC
	_next_moderation_expiry_check_msec = (
		started_msec + MODERATION_EXPIRY_CHECK_INTERVAL_MSEC)
	_next_punishment_maintenance_msec = (
		started_msec + PUNISHMENT_STORE_MAINTENANCE_INTERVAL_MSEC)
	if global_vars_mode == "unconscious":
		_global_variables = GlobalVariableService.new()
		_global_variables.minute_tick.connect(_on_cu_minute_tick)
		_global_variables.weather_tick.connect(_on_cu_weather_tick)
		_global_variables.holiday_changed.connect(_on_cu_holiday_changed)
		_global_variables.start()
		Log.server_info("[EasyServer] unconscious global variables enabled")
	Log.server_info("[EasyServer] READY transport=ws bind=%s port=%d" \
		% [bind_address, local_port])
	return true

func stop() -> void:
	if not _running:
		return
	_running = false
	_bad_sound_names.clear()
	for transport in _pending_transports:
		transport.ws.close(-1)
	_pending_transports.clear()
	_status_service.reset()
	for pid in _peers.keys():
		(_peers[pid] as PeerEntry).ws.close()
	_peers.clear()
	_list_snapshot_bytes = 0
	_list_peer_cursor = 0
	_greeted.clear()
	_next_id = 1
	_room_members.clear()
	_joined_player_count = 0
	_fair_peer_cursor = 0
	_presence_revision = 0
	_moderation_revision = 0
	_presence_global_dirty = false
	_presence_dirty_rooms.clear()
	_next_presence_refresh_msec = 0
	_next_moderation_sync_msec = 0
	_next_moderation_expiry_check_msec = 0
	_next_punishment_maintenance_msec = 0
	_gchat_ready_heap.clear()
	_pending_privacy_updates.clear()
	_pending_same_room_resyncs.clear()
	_pending_identity_recoveries.clear()
	_resume_sessions.clear()
	_public_chat_sessions.clear()
	_global_variables = null
	_admin_store = null
	_punishment_store = null
	_auth_failures_by_subject.clear()
	_next_auth_failure_cleanup_msec = 0
	_auth_failure_capacity_rejects = 0
	_auth_rate_limit_replies_suppressed = 0
	_server_namespace = ""
	_shutdown_deadline_msec = 0
	_shutdown_restart = false
	_shutdown_message = ""
	_next_shutdown_notice_second = -1
	_shutdown_origin = ""
	_protocol_limit_reached = false
	_protocol_limit_reason = ""
	_protocol_limit_shutdown_scheduled = false
	if _tcp:
		_tcp.stop()
		_tcp = null
	Log.server_info("[EasyServer] stopped")

func is_running() -> bool:
	return _running

func _accept_connection(stream: StreamPeerTCP) -> void:
	if stream == null:
		return
	if not _can_accept_connection():
		stream.disconnect_from_host()
		return
	var ws := WebSocketPeer.new()
	var transport_address := stream.get_connected_host()
	ws.supported_protocols = PackedStringArray(["binary", StatusProtocol.SUBPROTOCOL])
	ws.heartbeat_interval = HEARTBEAT_INTERVAL_SECONDS
	if ws.accept_stream(stream) != OK:
		stream.disconnect_from_host()
		return
	var transport := PendingTransport.new()
	transport.ws = ws
	transport.transport_address = PunishmentStoreScript.normalize_address(transport_address)
	transport.accepted_msec = Time.get_ticks_msec()
	_pending_transports.append(transport)


func _poll_pending_transports(now_msec: int) -> void:
	for transport in _pending_transports.duplicate():
		if now_msec - transport.accepted_msec >= HANDSHAKE_TIMEOUT_MSEC:
			transport.ws.close(-1)
			_pending_transports.erase(transport)
			continue
		transport.ws.poll()
		var state: int = transport.ws.get_ready_state()
		if state == WebSocketPeer.STATE_CLOSED:
			_pending_transports.erase(transport)
			continue
		if state != WebSocketPeer.STATE_OPEN:
			continue
		# Transfer the already-counted transport; neither branch accepts another
		# connection or allocates an additional admission slot.
		_pending_transports.erase(transport)
		if transport.ws.get_selected_protocol() == StatusProtocol.SUBPROTOCOL:
			var resolved := _resolve_punishment_address_value(
				punishment_address_source, transport.transport_address,
				transport.ws.get_requested_url())
			if (not bool(resolved.get("ok", false))
					or not _status_service.accept_query(transport.ws,
						str(resolved.get("address", "")), transport.accepted_msec, now_msec)):
				transport.ws.close(-1)
			continue
		if transport.ws.get_selected_protocol() != "binary":
			transport.ws.close(-1)
			continue
		_promote_game_transport(transport)


func _promote_game_transport(transport: PendingTransport) -> void:
	var pid := _take_next_peer_id()
	if pid < 0:
		transport.ws.close(-1)
		return
	var entry := PeerEntry.new()
	entry.id = pid
	entry.ws = transport.ws
	entry.transport_address = transport.transport_address
	entry.accepted_msec = transport.accepted_msec
	entry.ingress_last_msec = entry.accepted_msec
	entry.frame_tokens = FRAME_TOKEN_BURST
	entry.message_tokens = MESSAGE_TOKEN_BURST
	entry.byte_tokens = BYTE_TOKEN_BURST
	_peers[pid] = entry
	Log.server_info("[EasyServer] new peer created %d" % pid)


func _pending_admission_count() -> int:
	var pending := _pending_transports.size() + _status_service.connection_count()
	for entry_value in _peers.values():
		if not _peer_is_fully_admitted(entry_value as PeerEntry):
			pending += 1
	return pending


func _connection_count() -> int:
	return _peers.size() + _pending_transports.size() + _status_service.connection_count()


func _can_accept_connection() -> bool:
	if _protocol_limit_reached:
		return false
	if _next_id >= MAX_PROTOCOL_COUNTER:
		_request_protocol_limit_shutdown("peer_id")
		return false
	return (_connection_count() < max_connections
		and _pending_admission_count() < max_pending_admissions)


func _take_next_peer_id() -> int:
	if _next_id >= MAX_PROTOCOL_COUNTER:
		_next_id = MAX_PROTOCOL_COUNTER
		_request_protocol_limit_shutdown("peer_id")
		return -1
	var pid := _next_id
	_next_id += 1
	if _next_id >= MAX_PROTOCOL_COUNTER:
		_request_protocol_limit_shutdown("peer_id")
	return pid


func _advance_presence_revision() -> int:
	if _presence_revision >= MAX_PROTOCOL_COUNTER:
		_presence_revision = MAX_PROTOCOL_COUNTER
		_request_protocol_limit_shutdown("presence_revision")
		return _presence_revision
	_presence_revision += 1
	if _presence_revision >= MAX_PROTOCOL_COUNTER:
		_request_protocol_limit_shutdown("presence_revision")
	return _presence_revision


func _advance_moderation_revision() -> int:
	if _moderation_revision >= MAX_PROTOCOL_COUNTER:
		_moderation_revision = MAX_PROTOCOL_COUNTER
		_request_protocol_limit_shutdown("moderation_revision")
		return _moderation_revision
	_moderation_revision += 1
	if _moderation_revision >= MAX_PROTOCOL_COUNTER:
		_request_protocol_limit_shutdown("moderation_revision")
	return _moderation_revision


func _request_protocol_limit_shutdown(reason: String) -> void:
	if _protocol_limit_reached:
		return
	_protocol_limit_reached = true
	_protocol_limit_reason = reason
	Log.server_error("[EasyServer] protocol counter capacity reached counter=%s" % reason)

func _on_peer_open(pid: int, entry: PeerEntry) -> void:
	if not _resolve_punishment_address(entry):
		Log.server_warn("[EasyServer] rejected peer %d: invalid trusted address metadata" % pid)
		_close_and_detach_peer(pid, 1008, "invalid proxy metadata")
		return
	Log.server_debug("[EasyServer] peer %d open, sending s" % pid)
	# p4o-a7o: added PID to message for identifying self in chat messages
	_send_control(pid, "s", _build("s", ["0", str(pid)] + SERVER_CAPABILITIES))


func _resolve_punishment_address(entry: PeerEntry) -> bool:
	var resolved := _resolve_punishment_address_value(
		punishment_address_source, entry.transport_address, entry.ws.get_requested_url())
	if not bool(resolved.get("ok", false)):
		return false
	entry.punishment_address = str(resolved.get("address", ""))
	entry.punishment_address_source = str(resolved.get(
		"source", PUNISHMENT_ADDRESS_DISABLED))
	return true


func _resolve_punishment_address_value(
		source: String, transport_address: String, requested_url: String) -> Dictionary:
	var normalized_transport := PunishmentStoreScript.normalize_address(transport_address)
	match source:
		PUNISHMENT_ADDRESS_DISABLED:
			return {
				"ok": true, "address": "", "source": PUNISHMENT_ADDRESS_DISABLED}
		PUNISHMENT_ADDRESS_DIRECT:
			return {
				"ok": true,
				"address": normalized_transport,
				"source": PUNISHMENT_ADDRESS_DIRECT,
			}
		PUNISHMENT_ADDRESS_NGINX_URI_V1:
			if normalized_transport != NGINX_URI_V1_LOOPBACK:
				return {"ok": false}
		PUNISHMENT_ADDRESS_DIRECT_OR_NGINX_URI_V1:
			if normalized_transport != NGINX_URI_V1_LOOPBACK:
				return {
					"ok": true,
					"address": normalized_transport,
					"source": PUNISHMENT_ADDRESS_DIRECT,
				}
		_:
			return {"ok": false}

	var forwarded_address := _parse_nginx_uri_v1(requested_url)
	if forwarded_address.is_empty():
		return {"ok": false}
	return {
		"ok": true,
		"address": forwarded_address,
		"source": PUNISHMENT_ADDRESS_NGINX_URI_V1,
	}


func _parse_nginx_uri_v1(requested_url: String) -> String:
	# Nginx overwrites both Host and upstream URI. Do not accept client-supplied
	# forwarding headers, additional query fields, ports, fragments, or fallback
	# values from the loopback transport.
	if requested_url.length() > 2048 or not requested_url.begins_with("ws://"):
		return ""
	var remainder := requested_url.substr(5)
	var path_start := remainder.find("/")
	if path_start <= 0 or remainder.substr(0, path_start) != NGINX_URI_V1_HOST:
		return ""
	var resource := remainder.substr(path_start)
	if resource.contains("#"):
		return ""
	var query_start := resource.find("?")
	if query_start < 0 or resource.substr(0, query_start) != NGINX_URI_V1_PATH:
		return ""
	var query := resource.substr(query_start + 1)
	if not query.begins_with("ip=") or query.count("&") != 0 or query.count("=") != 1:
		return ""
	var normalized := PunishmentStoreScript.normalize_address(query.substr(3))
	return normalized if PunishmentStoreScript.address_is_usable(normalized) else ""

func _on_peer_closed(pid: int) -> void:
	if not _peers.has(pid):
		return
	var entry: PeerEntry = _peers[pid]
	_detach_peer(pid, entry, Time.get_ticks_msec())


func _detach_peer(pid: int, entry: PeerEntry, now_msec: int) -> void:
	if entry.detaching:
		return
	entry.detaching = true
	_cancel_server_list_queries(entry)
	_persist_peer_punishment_profile(entry)
	Log.server_info("[EasyServer] peer %d closed (room %d)" % [pid, entry.room_id])
	var old_room := entry.room_id
	if old_room >= 0:
		_broadcast_departure(old_room, entry.id, pid)
		_set_peer_room(entry, -1)
	_pending_privacy_updates.erase(pid)
	_pending_same_room_resyncs.erase(pid)
	_pending_identity_recoveries.erase(pid)
	_peers.erase(pid)
	_greeted.erase(pid)
	_deactivate_resume_session_if_owner(entry, now_msec)
	if old_room >= 0:
		_broadcast_cu_player_count(old_room)


func _close_and_detach_peer(pid: int, code: int, reason: String) -> void:
	if not _peers.has(pid):
		return
	var entry := _peers[pid] as PeerEntry
	_detach_peer(pid, entry, Time.get_ticks_msec())
	entry.ws.close(code, reason)


func _deactivate_resume_session_if_owner(entry: PeerEntry, now_msec: int) -> void:
	if entry.resume_token.is_empty() or not _resume_sessions.has(entry.resume_token):
		return
	_sync_privacy_to_resume_session(entry)
	_sync_global_chat_to_resume_session(entry)
	var session := _resume_sessions[entry.resume_token] as ResumeSession
	# Compare-delete semantics: a late close from a superseded socket must never
	# clear the owner installed by the newer resume attempt.
	if session.current_pid != entry.id:
		return
	session.current_pid = -1
	session.expires_msec = now_msec + RESUME_SESSION_GRACE_MSEC


func _sync_privacy_to_resume_session(entry: PeerEntry) -> void:
	if entry.resume_token.is_empty() or not _resume_sessions.has(entry.resume_token):
		return
	var session := _resume_sessions[entry.resume_token] as ResumeSession
	if session.current_pid != entry.id:
		return
	session.privacy_mode = (
		entry.privacy_pre_ban_mode
		if entry.privacy_pre_ban_mode >= 0 else entry.privacy_mode)
	session.privacy_requested = entry.privacy_requested
	session.privacy_request_seq = entry.privacy_request_seq
	session.privacy_revision = entry.privacy_revision
	session.privacy_cooldown_until_msec = entry.privacy_cooldown_until_msec
	session.privacy_pending = entry.privacy_pending


func _restore_privacy_from_resume_session(
		entry: PeerEntry, session: ResumeSession) -> void:
	entry.privacy_mode = session.privacy_mode
	entry.privacy_requested = session.privacy_requested
	entry.privacy_request_seq = session.privacy_request_seq
	entry.privacy_revision = session.privacy_revision
	entry.privacy_cooldown_until_msec = session.privacy_cooldown_until_msec
	entry.privacy_pending = session.privacy_pending


func _sync_global_chat_to_resume_session(entry: PeerEntry) -> void:
	if entry.resume_token.is_empty() or not _resume_sessions.has(entry.resume_token):
		return
	var session := _resume_sessions[entry.resume_token] as ResumeSession
	if session.current_pid != entry.id:
		return
	session.gchat_ready_msec = entry.gchat_ready_msec
	session.chat_ready_msec = entry.chat_ready_msec


func _restore_global_chat_from_resume_session(
		entry: PeerEntry, session: ResumeSession, now_msec: int) -> void:
	# Preserve the original deadline, not a fresh cooldown after every reconnect.
	# Old heap entries belong to the retired PID and are skipped when they expire.
	var remaining := maxi(0, session.gchat_ready_msec - now_msec)
	entry.gchat_ready_msec = session.gchat_ready_msec if remaining > 0 else 0
	session.gchat_ready_msec = entry.gchat_ready_msec
	if remaining > 0:
		_schedule_global_chat_ready(entry.id, entry.gchat_ready_msec)
	if entry.gchat_ack_capable:
		_queue_global_chat_status(
			entry.id, "rejected" if remaining > 0 else "ready", remaining)

	var room_remaining := maxi(0, session.chat_ready_msec - now_msec)
	entry.chat_ready_msec = session.chat_ready_msec if room_remaining > 0 else 0
	session.chat_ready_msec = entry.chat_ready_msec
	if entry.chat_ack_capable:
		_queue_room_chat_status(
			entry.id, "rejected" if room_remaining > 0 else "ready", room_remaining)


func _expire_resume_sessions(now_msec: int) -> void:
	for token_value in _resume_sessions.keys():
		var token := token_value as String
		var session := _resume_sessions[token] as ResumeSession
		if (session.current_pid < 0
				and session.expires_msec > 0
				and now_msec >= session.expires_msec):
			_erase_resume_session(token)


func _erase_resume_session(token: String) -> void:
	var session: ResumeSession = _resume_sessions.get(token)
	if session != null:
		_public_chat_sessions.erase(session.public_chat_id)
	_resume_sessions.erase(token)


func _public_chat_id(entry: PeerEntry) -> String:
	var session: ResumeSession = _resume_sessions.get(entry.resume_token)
	return session.public_chat_id if session != null and session.current_pid == entry.id else ""


func _generate_resume_token() -> String:
	var crypto := Crypto.new()
	var token := crypto.generate_random_bytes(32).hex_encode()
	while token.length() != 64 or _resume_sessions.has(token):
		token = crypto.generate_random_bytes(32).hex_encode()
	return token

func _process_open_peer_frames(open_pids: Array, now_msec: int) -> void:
	if open_pids.is_empty():
		_fair_peer_cursor = 0
		return
	var peer_count := open_pids.size()
	var start_index := _fair_peer_cursor % peer_count
	var last_index := start_index
	var frames_processed := 0
	var messages_processed := 0
	var bytes_processed := 0
	var exhausted := false
	for _round in range(MAX_FRAMES_PER_PEER_PER_TICK):
		for offset in range(peer_count):
			if (frames_processed >= MAX_FRAMES_PER_TICK
					or messages_processed >= MAX_MESSAGES_PER_TICK
					or bytes_processed >= MAX_BYTES_PER_TICK):
				exhausted = true
				break
			var index := (start_index + offset) % peer_count
			last_index = index
			var pid := int(open_pids[index])
			if not _peers.has(pid):
				continue
			var entry := _peers[pid] as PeerEntry
			if entry.ws.get_available_packet_count() <= 0:
				continue
			var raw := entry.ws.get_packet()
			frames_processed += 1
			bytes_processed += raw.size()
			messages_processed += _dispatch_frame(pid, entry, raw, now_msec)
		if exhausted:
			break
	_fair_peer_cursor = (last_index + 1) % peer_count


func _dispatch_frame(pid: int, entry: PeerEntry, raw: PackedByteArray, now_msec: int) -> int:
	if raw.size() <= 0 or raw.size() > MAX_FRAME_BYTES:
		_warn_peer(pid, "frame_size",
			"[EasyServer] rejected frame from peer %d: invalid size %d" % [pid, raw.size()],
			now_msec)
		return 1
	# Limit splitting itself: a delimiter flood cannot allocate an unbounded
	# number of message strings before the structural limit is checked.
	# Reject NUL before decoding so Godot cannot replace it or log per byte.
	# Keep the existing whole-frame rejection and ingress accounting below.
	var has_nul: bool = raw.has(0)
	var frame_text := "" if has_nul else raw.get_string_from_utf8()
	if has_nul or frame_text.to_utf8_buffer() != raw:
		# Godot substitutes malformed UTF-8 while decoding. Reject any frame
		# whose bytes cannot round-trip exactly so substituted protocol fields
		# can never reach semantic handlers.
		_consume_ingress_tokens(entry, raw.size(), 1, now_msec)
		_warn_peer(pid, "frame_utf8",
			"[EasyServer] rejected invalid UTF-8 frame from peer %d" % pid,
			now_msec)
		return 1
	var messages := frame_text.split(
		MSG_DELIM, false, MAX_LEGACY_MESSAGES_PER_FRAME)
	# Count malformed delimiter floods against the same generous ingress budget
	# as valid traffic; otherwise a peer could bypass the bucket by staying just
	# outside the structural limit.
	if not _consume_ingress_tokens(entry, raw.size(), messages.size(), now_msec):
		_warn_peer(pid, "rate_limit",
			"[EasyServer] dropped sustained excess traffic from peer %d" % pid,
			now_msec)
		return messages.size()
	var protocol_preflight := _preflight_frame_protocol(entry, messages)
	var strict_frame := bool(protocol_preflight[0])
	var strict_exclusive_request := bool(protocol_preflight[1])
	var message_limit := (MAX_STRICT_MESSAGES_PER_FRAME
		if strict_frame else MAX_LEGACY_MESSAGES_PER_FRAME)
	if messages.size() > message_limit:
		_warn_peer(pid, "frame_messages",
			"[EasyServer] rejected frame from peer %d: too many messages for protocol mode" % pid,
			now_msec)
		return messages.size()
	if messages.size() != 1 and strict_exclusive_request:
		_warn_peer(pid, "room_barrier",
			"[EasyServer] rejected non-exclusive barrier request from peer %d" % pid,
			now_msec)
		return messages.size()
	for msg in messages:
		_dispatch_message(pid, entry, msg)
		if not _peers.has(pid) or entry.superseded:
			break
	return messages.size()


func _preflight_frame_protocol(
		entry: PeerEntry, messages: PackedStringArray) -> Array:
	# Simulate only capability negotiation and the first room request. No peer
	# state is mutated, so a rejected frame cannot partially negotiate STRICT.
	var mode := entry.protocol_mode
	var barrier_capable := entry.room_barrier_capable
	var capabilities_received := entry.capabilities_received
	var strict_frame := _peer_uses_strict_room_barrier(entry)
	var strict_exclusive_request := false
	for msg_value in messages:
		var msg := msg_value as String
		if mode == ProtocolMode.UNKNOWN and not capabilities_received:
			var preflight_capabilities: Variant = _preflight_capability_message(msg)
			if typeof(preflight_capabilities) == TYPE_DICTIONARY:
				capabilities_received = true
				barrier_capable = barrier_capable or (
					preflight_capabilities as Dictionary).has("room_barrier1")
				strict_frame = strict_frame or barrier_capable
		if msg == "sr" or msg.begins_with("sr" + PARAM_DELIM):
			if mode == ProtocolMode.UNKNOWN:
				mode = ProtocolMode.STRICT if barrier_capable else ProtocolMode.LEGACY
			strict_exclusive_request = mode == ProtocolMode.STRICT
			break
		if (strict_frame
				and (msg == "privacy" or msg.begins_with("privacy" + PARAM_DELIM))):
			strict_exclusive_request = true
			break
	return [strict_frame, strict_exclusive_request]


func _preflight_capability_message(msg: String) -> Variant:
	if msg.is_empty() or msg.length() > MAX_MESSAGE_CHARS:
		return null
	var p := msg.find(PARAM_DELIM)
	if p < 0 or msg.substr(0, p) != "cap":
		return null
	var args := Array(msg.substr(p + PARAM_DELIM.length()).split(PARAM_DELIM, true))
	if args.size() > MAX_PACKET_ARGS:
		return null
	for arg in args:
		if typeof(arg) != TYPE_STRING or (arg as String).length() > MAX_ARG_CHARS:
			return null
	return _validated_capability_set(args)


func _consume_ingress_tokens(
		entry: PeerEntry, frame_bytes: int, message_count: int, now_msec: int) -> bool:
	var elapsed_seconds := maxf(
		0.0, float(now_msec - entry.ingress_last_msec) / 1000.0)
	entry.ingress_last_msec = now_msec
	entry.frame_tokens = minf(
		FRAME_TOKEN_BURST, entry.frame_tokens + elapsed_seconds * FRAME_TOKEN_RATE)
	entry.message_tokens = minf(
		MESSAGE_TOKEN_BURST, entry.message_tokens + elapsed_seconds * MESSAGE_TOKEN_RATE)
	entry.byte_tokens = minf(
		BYTE_TOKEN_BURST, entry.byte_tokens + elapsed_seconds * BYTE_TOKEN_RATE)
	if (entry.frame_tokens < 1.0
			or entry.message_tokens < float(message_count)
			or entry.byte_tokens < float(frame_bytes)):
		return false
	entry.frame_tokens -= 1.0
	entry.message_tokens -= float(message_count)
	entry.byte_tokens -= float(frame_bytes)
	return true

func _dispatch_message(pid: int, entry: PeerEntry, msg: String) -> void:
	if msg.is_empty() or msg.length() > MAX_MESSAGE_CHARS:
		_warn_peer(pid, "message_length",
			"[EasyServer] rejected invalid message length from peer %d" % pid)
		return
	var p := msg.find(PARAM_DELIM)
	var type: String
	var args: Array
	if p == -1:
		type = msg
		args = []
	else:
		type = msg.substr(0, p)
		# Empty resource names are meaningful (for example clearing a sprite).
		# Preserve their argument position and let each packet schema decide.
		args = Array(msg.substr(p + PARAM_DELIM.length()).split(PARAM_DELIM, true))
	if type.is_empty() or type.length() > MAX_PACKET_TYPE_CHARS or args.size() > MAX_PACKET_ARGS:
		_warn_peer(pid, "packet_shape",
			"[EasyServer] rejected malformed packet from peer %d" % pid)
		return
	for arg in args:
		if typeof(arg) != TYPE_STRING or (arg as String).length() > MAX_ARG_CHARS:
			_warn_peer(pid, "argument_size",
				"[EasyServer] rejected oversized packet argument from peer %d" % pid)
			return
	if OS.is_debug_build():
		if type in ["chat", "gchat", "chatm", "gchatm", "chatx", "gchatx"]:
			var contents_length := (args[0] as String).length() if not args.is_empty() else 0
			Log.server_debug("[EasyServer] RX peer=%d '%s' chars=%d" \
					% [pid, type, contents_length])
		elif type in ["resume", "adm_auth", "install_identity"]:
			# Resume tokens and administrator credentials are bearer credentials. Never put them in logs,
			# including malformed-packet diagnostics.
			Log.server_debug("[EasyServer] RX peer=%d '%s' args=%d credential=<redacted>" \
					% [pid, type, args.size()])
		else:
			Log.server_debug("[EasyServer] RX peer=%d '%s' args=%s" % [pid, type, str(args)])
	var admission_capable := _peer_has_public_admission_capabilities(entry)
	if (admission_capable
			and not entry.resume_complete
			and type != "cap"
			and type != "install_identity"
			and type != "resume"):
		_warn_peer(pid, "resume_required",
			"[EasyServer] rejected packet '%s' before resume from peer %d" % [type, pid])
		return
	if type not in ["cap", "install_identity", "resume"] and not admission_capable:
		_warn_peer(pid, "client_update_required",
			"[EasyServer] rejected packet '%s' without current admission capabilities from peer %d"
				% [type, pid])
		if type == "sr":
			# Keep polling this transport through the close handshake so clients see
			# the application close code instead of an abnormal disconnect.
			entry.ws.close(CLIENT_UPDATE_REQUIRED_CLOSE_CODE, "client update required")
		return
	
	match type:
		"cap": _handle_capabilities(pid, entry, args)
		"install_identity": _handle_install_identity(pid, entry, args)
		"resume": _handle_resume(pid, entry, args)
		"adm_auth": _handle_admin_auth(pid, entry, args)
		"adm_logout": _handle_admin_logout(pid, entry, args)
		"adm_roster": _handle_admin_roster(pid, entry, args)
		"adm_bans": _handle_admin_bans(pid, entry, args)
		"plist": _handle_player_list(pid, entry, args)
		"adm_act": _handle_admin_action(pid, entry, args)
		"privacy": _handle_privacy(pid, entry, args)
		"sr": _handle_sr(pid, entry, args)
		"ploc": _handle_previous_location(pid, entry, args)
		"m", "tp": _handle_move(pid, entry, type, args)
		"jmp": _handle_jump(pid, entry, args)
		"f": _handle_facing(pid, entry, args)
		"spd": _handle_speed(pid, entry, args)
		"spr": _handle_sprite(pid, entry, args)
		"tr": _handle_transparency(pid, entry, args)
		"h": _handle_hidden(pid, entry, args)
		"sys": _handle_sys(pid, entry, args)
		"sys2": _handle_sys2(pid, entry, args)
		"name": _handle_name_pkt(pid, entry, args)
		"chat": _handle_chat(pid, entry, args)
		"chatm": _handle_chat_metadata(pid, entry, args)
		"chatx": _handle_chat_mentions(pid, entry, args, false)
		"gchat": _handle_global_chat(pid, entry, args)
		"gchatm": _handle_global_chat_metadata(pid, entry, args)
		"gchatx": _handle_chat_mentions(pid, entry, args, true)
		"chaton": _handle_chaton(pid, entry, args)
		"s", "identity_chal", "identity_ok", "resume_ok", "ri", "d", "c", "chat2", "chat3", "gchat2", "gchat3", "gchat4", "gchat_status", "chat_status", "privacy_status", "presence", "cut", "cuw", "ssv", \
				"adm_ok", "adm_fail", "adm_result", "adm_roster_begin", "adm_roster_item", "adm_roster_item2", "adm_roster_end", \
				"adm_bans_begin", "adm_bans_item", "adm_bans_item2", "adm_bans_item3", "adm_bans_end", "server_notice", "mod_status", \
				"plist_begin", "plist_item", "plist_item2", "plist_end", "chat4", "gchat5", "chat5", "gchat6":
			_warn_peer(pid, "server_owned",
				"[EasyServer] rejected server-owned packet '%s' from peer %d" % [type, pid])
		"fl","rfl","rrfl","se","ba","ap","mp","rp","ss","sv","sev":
			_handle_relay(pid, entry, type, args)
		_:
			_warn_peer(pid, "unknown_packet",
				"[EasyServer] unknown packet '%s' from peer %d" % [type, pid])


func _peer_has_public_admission_capabilities(entry: PeerEntry) -> bool:
	return (entry.capabilities_received
		and entry.room_barrier_capable
		and entry.resume_capable
		and entry.install_identity_capable
		and entry.install_identity_complete)


func _peer_is_fully_admitted(entry: PeerEntry) -> bool:
	return (entry != null
		and not entry.detaching
		and not entry.superseded
		and _peer_has_public_admission_capabilities(entry)
		and entry.resume_complete)


func _handle_sys2(pid: int, entry: PeerEntry, args: Array) -> void:
	if (not entry.system_theme_capable or args.size() != 2 or typeof(args[0]) != TYPE_STRING
			or not ResourceNameRules.is_safe_flat_resource_name(args[0], false)
			or not _is_bounded_int(args[1], 0, 1)):
		_warn_peer(pid, "system_theme", "[EasyServer] rejected malformed sys2 packet")
		return
	var system_name := args[0] as String
	var stretch_mode := int(args[1])
	if entry.sys_name == system_name and entry.system_stretch == stretch_mode:
		return
	entry.sys_name = system_name
	entry.system_stretch = stretch_mode
	if entry.room_id < 0:
		return
	_broadcast_system_theme(entry.room_id, entry, pid)


func _handle_player_list(pid: int, entry: PeerEntry, args: Array) -> void:
	if (not entry.player_list_capable or args.size() != 1
			or not _is_bounded_int(args[0], 1, MAX_ROOM_ID)
			or entry.room_id < 0 or entry.privacy_mode != 0):
		return
	_queue_list_query(entry, "plist", str(args[0]))


func _build_plist_snapshot(entry: PeerEntry, args: Array) -> Dictionary:
	var request_id := args[0] as String
	var revision := maxi(_presence_revision, _moderation_revision)
	var now_unix := int(Time.get_unix_time_from_system())
	var packets: Array = [_build("plist_begin", [
		request_id, str(revision), str(now_unix)])]
	for value in _peers.values():
		var target := value as PeerEntry
		if (target == null or target.room_id < 0 or target.privacy_mode != 0
				or _peer_is_banned(target, now_unix)):
			continue
		var item_args: Array = [
			request_id, str(target.id), str(target.room_id), str(target.prev_map_id),
			str(target.x), str(target.y), target.display_name, target.sprite_name,
			str(target.sprite_idx), str(target.facing), "1" if target.hidden else "0",
			str(target.transparency), target.sys_name, str(target.system_stretch),
			"1" if not target.admin_id.is_empty() else "0",
			str(target.muted_until_unix if not entry.admin_id.is_empty() else 0),
			"permanent" if not entry.admin_id.is_empty() and target.muted_permanent else "finite",
			"1" if not entry.admin_id.is_empty() and target.muted_network_scope else "0",
		]
		if entry.chat_mentions_capable:
			item_args.append(_public_chat_id(target))
		packets.append(_build("plist_item2" if entry.chat_mentions_capable else "plist_item", item_args))
	packets.append(_build("plist_end", [request_id, str(revision)]))
	return _freeze_list_packets(packets)


func _peer_profile(entry: PeerEntry) -> Dictionary:
	return {
		"display_name": entry.display_name,
		"system_name": entry.sys_name,
		"system_stretch": entry.system_stretch,
		"sprite_name": entry.sprite_name,
		"sprite_index": entry.sprite_idx,
		"facing": entry.facing,
	}


func _persist_peer_punishment_profile(entry: PeerEntry) -> void:
	if (_punishment_store == null or entry.installation_identity.is_empty()
			or not entry.position_seen):
		return
	_punishment_store.update_active_profile_for_subjects(
		entry.punishment_address, entry.installation_identity, _peer_profile(entry))


func _find_online_peer_for_punishment(record: Dictionary) -> PeerEntry:
	if _punishment_store == null:
		return null
	var best_match: PeerEntry = null
	var best_strength := 0
	for value in _peers.values():
		var candidate := value as PeerEntry
		if (not _peer_is_fully_admitted(candidate)
				or not candidate.position_seen):
			continue
		var strength := _punishment_store.record_profile_match_strength(
			record, candidate.punishment_address, candidate.installation_identity)
		if strength > best_strength:
			best_strength = strength
			best_match = candidate
	return best_match


func _build_punishment_profile_packet(request_id: String, record: Dictionary) -> String:
	var online := _find_online_peer_for_punishment(record)
	var profile := _peer_profile(online) if online != null else {
		"display_name": str(record.get("last_name", "")),
		"system_name": str(record.get("last_system_name", "")),
		"system_stretch": int(record.get("last_system_stretch", 1)),
		"sprite_name": str(record.get("last_sprite_name", "")),
		"sprite_index": int(record.get("last_sprite_index", 0)),
		"facing": int(record.get("last_facing", 2)),
	}
	return _build("adm_bans_item2", [
		request_id, str(record.get("id", "")),
		str(record.get("kind", PunishmentStoreScript.KIND_BAN)),
		str(profile.get("display_name", record.get("last_name", ""))),
		str(record.get("network_label", "")), str(record.get("expires_at", 0)),
		str(record.get("actor", "")),
		str(online.id if online != null else 0), str(online.room_id if online != null else -1),
		str(online.prev_map_id if online != null else 0), str(online.x if online != null else -1),
		str(online.y if online != null else -1), str(profile.get("system_name", "")),
		str(profile.get("system_stretch", 1)), str(profile.get("sprite_name", "")),
		str(profile.get("sprite_index", 0)), str(profile.get("facing", 2)),
		"1" if online != null and not online.admin_id.is_empty() else "0",
	])


func _build_punishment_identity_packet(request_id: String, record: Dictionary) -> String:
	var online := _find_online_peer_for_punishment(record)
	return _build("adm_bans_item3", [
		request_id,
		str(record.get("id", "")),
		_punishment_store.subject_group_id_for_record(record),
		str(record.get("created_at", 0)),
		str(record.get("scope", PunishmentStoreScript.SCOPE_INSTALLATION)),
		str(record.get("duration_mode", PunishmentStoreScript.DURATION_FINITE)),
		"1" if online != null and PunishmentStoreScript.address_is_usable(
			online.punishment_address) else "0",
	])


func _execute_remote_update_punishment(
		pid: int, actor: PeerEntry, request_id: String, punishment_id: String,
		duration: int, duration_mode: String, include_network: bool) -> void:
	if _punishment_store == null:
		_send_admin_result(pid, request_id, "punishment_update", false,
			"punishment_store_unavailable", "")
		return
	var existing := _punishment_store.get_active(punishment_id)
	if existing.is_empty():
		_send_admin_result(pid, request_id, "punishment_update", false,
			"already_expired", "")
		return
	var maximum := (
		MAX_MUTE_DURATION_SECONDS
		if str(existing.get("kind", "ban")) == PunishmentStoreScript.KIND_MUTE
		else MAX_MODERATION_DURATION_SECONDS)
	if not (duration_mode == PunishmentStoreScript.DURATION_PERMANENT and duration == 0
			or duration_mode == PunishmentStoreScript.DURATION_FINITE
				and duration > 0 and duration <= maximum):
		_send_admin_result(pid, request_id, "punishment_update", false,
			"invalid_duration", "")
		return
	var online := _find_online_peer_for_punishment(existing)
	if _network_change_includes_admin(existing, include_network, duration, duration_mode,
			online.punishment_address if online != null else ""):
		_send_admin_result(pid, request_id, "punishment_update", false,
			"network_identity_includes_admin", "该IP下有在线管理员，不能新增或延长IP处罚")
		return
	var result := _punishment_store.update_punishment(
		punishment_id, duration, duration_mode, include_network,
		online.punishment_address if online != null else "",
		online.installation_identity if online != null else "")
	if not bool(result.get("ok", false)):
		_send_admin_result(pid, request_id, "punishment_update", false,
			"change_failed", str(result.get("error", "")))
		return
	_advance_moderation_revision()
	_refresh_all_peer_punishments()
	_append_audit("remote", actor.admin_id, "punishment_update", 0,
		punishment_id, duration, "", "ok")
	_send_admin_result(pid, request_id, "punishment_update", true, "ok", punishment_id)


func _handle_capabilities(pid: int, entry: PeerEntry, args: Array) -> void:
	if entry.capabilities_received:
		_warn_peer(pid, "capabilities",
			"[EasyServer] ignored repeated capability response from peer %d" % pid)
		return
	var validated: Variant = _validated_capability_set(args)
	if typeof(validated) != TYPE_DICTIONARY:
		_warn_peer(pid, "capabilities",
			"[EasyServer] rejected malformed capability response from peer %d" % pid)
		return
	var seen := validated as Dictionary
	if not seen.has("install_identity1"):
		_warn_peer(pid, "identity_required",
			"[EasyServer] peer %d lacks mandatory install identity capability" % pid)
		_close_and_detach_peer(
			pid, CLIENT_UPDATE_REQUIRED_CLOSE_CODE, "identity required")
		return
	entry.capabilities_received = true
	entry.install_identity_capable = true
	entry.presence_capable = entry.presence_capable or seen.has("presence1")
	entry.gchat_ack_capable = entry.gchat_ack_capable or seen.has("gchat_ack1")
	entry.chat_ack_capable = entry.chat_ack_capable or seen.has("chat_ack1")
	entry.admin_capable = entry.admin_capable or seen.has("admin3")
	entry.chat_metadata_capable = (
		entry.chat_metadata_capable or seen.has("chat_meta1"))
	entry.chat_mentions_capable = (seen.has("chat_mentions1")
		and seen.has("session_resume1") and entry.chat_metadata_capable)
	entry.chat_snapshot_capable = entry.chat_mentions_capable and seen.has("chat_snapshot1")
	entry.unnamed_chat_capable = entry.chat_snapshot_capable and seen.has("unnamed_chat1")
	entry.moderation_capable = entry.moderation_capable or seen.has("moderation3")
	entry.player_list_capable = entry.player_list_capable or seen.has("player_list1")
	entry.list_query_capable = entry.list_query_capable or seen.has("list_query1")
	entry.system_theme_capable = entry.system_theme_capable or seen.has("system_theme1")
	entry.system_theme_sync_capable = (
		entry.system_theme_capable
		and (entry.system_theme_sync_capable or seen.has("system_theme2")))
	if entry.protocol_mode == ProtocolMode.UNKNOWN:
		entry.room_barrier_capable = (
			entry.room_barrier_capable or seen.has("room_barrier1"))
	entry.privacy_capable = (entry.privacy_capable
		or (seen.has("privacy1")
			and entry.room_barrier_capable
			and entry.protocol_mode != ProtocolMode.LEGACY))
	if seen.has("privacy1") and not entry.privacy_capable:
		_warn_peer(pid, "privacy_capability",
			"[EasyServer] ignored privacy capability without strict room barrier for peer %d" % pid)
	if seen.has("session_resume1"):
		# Resume negotiation is a connection handshake and cannot be retrofitted
		# after this transport has already become an online room participant.
		if entry.room_id >= 0 or entry.announced_room >= 0:
			_warn_peer(pid, "resume_order",
				"[EasyServer] peer %d negotiated resume after requesting a room" % pid)
			_close_and_detach_peer(pid, 1008, "resume negotiated after room join")
			return
		entry.resume_capable = true
		entry.resume_complete = false
		entry.resume_deadline_msec = Time.get_ticks_msec() + HANDSHAKE_TIMEOUT_MSEC
	if entry.room_id >= 0 and entry.presence_capable:
		_queue_presence(pid)
	if entry.gchat_ack_capable:
		var remaining := maxi(0, entry.gchat_ready_msec - Time.get_ticks_msec())
		if remaining == 0:
			_queue_global_chat_status(pid, "ready", 0)
		else:
			_queue_global_chat_status(pid, "rejected", remaining)
	_send_control(pid, "identity_chal", _build("identity_chal", [_server_namespace]))


func _handle_install_identity(pid: int, entry: PeerEntry, args: Array) -> void:
	if (not entry.capabilities_received or not entry.install_identity_capable
			or entry.install_identity_complete or not entry.installation_identity.is_empty()
			or args.size() != 1 or typeof(args[0]) != TYPE_STRING):
		_warn_peer(pid, "install_identity",
			"[EasyServer] rejected invalid install identity handshake from peer %d" % pid)
		_close_and_detach_peer(
			pid, INVALID_INSTALL_IDENTITY_CLOSE_CODE, "identity invalid")
		return
	var identity := args[0] as String
	if (identity != identity.to_lower()
			or not PunishmentStoreScript.installation_identity_is_usable(identity)):
		_warn_peer(pid, "install_identity",
			"[EasyServer] rejected malformed install identity from peer %d" % pid)
		_close_and_detach_peer(
			pid, INVALID_INSTALL_IDENTITY_CLOSE_CODE, "identity invalid")
		return
	entry.installation_identity = identity
	entry.install_identity_complete = true
	_refresh_peer_punishments(
		pid, entry, int(Time.get_unix_time_from_system()), false)
	_send_control(pid, "identity_ok", _build("identity_ok"))


func _validated_capability_set(args: Array) -> Variant:
	if args.is_empty() or args.size() > SERVER_CAPABILITIES.size():
		return null
	var seen: Dictionary = {}
	for capability in args:
		if typeof(capability) != TYPE_STRING:
			return null
		var value := capability as String
		if seen.has(value) or value not in SERVER_CAPABILITIES:
			return null
		seen[value] = true
	return seen


func _handle_admin_auth(pid: int, entry: PeerEntry, args: Array) -> void:
	if not entry.admin_capable or _admin_store == null:
		_send_admin_packet(pid, _build("adm_fail", ["unavailable_or_invalid_request"]))
		return
	var now_msec := Time.get_ticks_msec()
	var auth_subjects := _admin_auth_subjects(entry)
	if _admin_auth_is_blocked(entry, auth_subjects, now_msec):
		_send_admin_rate_limited(pid, entry, now_msec)
		return
	var credential_digest := ""
	if args.size() == 1 and typeof(args[0]) == TYPE_STRING:
		credential_digest = _decode_admin_credential(args[0] as String)
	if credential_digest.is_empty() or credential_digest.length() > 160:
		var malformed_recorded := _record_admin_auth_failure_attempt(
			entry, auth_subjects, now_msec)
		if malformed_recorded:
			_send_admin_packet(pid, _build("adm_fail", ["unavailable_or_invalid_request"]))
		else:
			_send_admin_rate_limited(pid, entry, now_msec)
		return
	var admin_id := _admin_store.verify(credential_digest)
	if admin_id.is_empty():
		var failure_recorded := _record_admin_auth_failure_attempt(
			entry, auth_subjects, now_msec)
		if failure_recorded:
			_send_admin_packet(pid, _build("adm_fail", ["invalid_credential"]))
			_append_audit(
				"remote", "", "admin_auth", pid, entry.display_name, 0, "", "denied")
		else:
			_send_admin_rate_limited(pid, entry, now_msec)
		return
	for auth_subject in auth_subjects:
		_auth_failures_by_subject.erase(auth_subject)
	entry.admin_auth_connection_failure.clear()
	entry.next_admin_auth_rate_limit_reply_msec = 0
	_cancel_server_list_queries(entry)
	entry.admin_id = admin_id
	_send_admin_packet(pid, _build("adm_ok", [admin_id]))
	_append_audit("remote", admin_id, "admin_auth", pid, entry.display_name, 0, "", "ok")


func _decode_admin_credential(encoded: String) -> String:
	if encoded.is_empty() or encoded.length() > EasyConnection.MAX_ARGUMENT_CHARACTERS:
		return ""
	var base64 := encoded.replace("-", "+").replace("_", "/")
	var remainder := base64.length() % 4
	if remainder == 1:
		return ""
	if remainder > 0:
		base64 += "=".repeat(4 - remainder)
	var decoded_bytes := Marshalls.base64_to_raw(base64)
	if decoded_bytes.is_empty() or decoded_bytes.has(0):
		return ""
	var decoded := decoded_bytes.get_string_from_utf8()
	if decoded.to_utf8_buffer() != decoded_bytes:
		return ""
	return decoded


func _admin_auth_subjects(entry: PeerEntry) -> Array[String]:
	var result: Array[String] = []
	if PunishmentStoreScript.installation_identity_is_usable(entry.installation_identity):
		result.append("installation:" + entry.installation_identity)
	if PunishmentStoreScript.address_is_usable(entry.punishment_address):
		result.append("network:" + entry.punishment_address)
	if not result.is_empty():
		return result
	# This branch is unreachable after mandatory identity admission, but it keeps
	# a disabled-address development server from collapsing every failure into a
	# single empty bucket if authentication is called during malformed traffic.
	result.append("connection:" + str(entry.id))
	return result


func _verify_status_auth(
		address: String, request_id: String, nonce: String, proof: String, now_msec: int) -> bool:
	if _admin_store == null:
		return false
	var subject := ""
	if PunishmentStoreScript.address_is_usable(address):
		subject = "network:" + PunishmentStoreScript.normalize_address(address)
		if _auth_failures_by_subject.has(subject):
			var record := _auth_failures_by_subject[subject] as Dictionary
			if _auth_failure_record_is_expired(record, now_msec):
				_auth_failures_by_subject.erase(subject)
			elif _auth_failure_record_is_blocked(record, now_msec):
				return false
		if (not _auth_failures_by_subject.has(subject)
				and _auth_failures_by_subject.size() >= MAX_AUTH_FAILURE_SUBJECTS):
			# Queries cannot fall back to a connection-local failure counter:
			# reconnecting must never buy another unaccounted credential attempt.
			_auth_failure_capacity_rejects += 1
			return false
	var verified := _admin_store.verify_status_proof(request_id, nonce, proof)
	if not verified and not subject.is_empty():
		_auth_failures_by_subject[subject] = _advance_auth_failure_record(
			_auth_failures_by_subject.get(subject, {}) as Dictionary, now_msec)
	# Successful previews confer no role and do not clear failures belonging to
	# formal sessions. Unknown proxy sources use the service's bounded work
	# budget, not a shared ten-minute lockout of every client behind the proxy.
	return verified


func _auth_failure_record_is_expired(record: Dictionary, now_msec: int) -> bool:
	if record.is_empty() or not record.has("window_started"):
		return true
	var window_expires := int(record.get("window_started", now_msec)) \
		+ AUTH_FAILURE_WINDOW_MSEC
	var expires_msec := maxi(window_expires, int(record.get("blocked_until", 0)))
	return now_msec >= expires_msec


func _auth_failure_record_is_blocked(record: Dictionary, now_msec: int) -> bool:
	return (not _auth_failure_record_is_expired(record, now_msec)
		and now_msec < int(record.get("blocked_until", 0)))


func _advance_auth_failure_record(record: Dictionary, now_msec: int) -> Dictionary:
	var window_started := now_msec
	var count := 0
	if not _auth_failure_record_is_expired(record, now_msec):
		window_started = int(record.get("window_started", now_msec))
		count = int(record.get("count", 0))
	count += 1
	var next_record := {
		"window_started": window_started,
		"count": count,
		"blocked_until": 0,
	}
	if count >= AUTH_FAILURE_LIMIT:
		next_record["blocked_until"] = now_msec + AUTH_BLOCK_MSEC
	return next_record


func _admin_auth_is_blocked(
		entry: PeerEntry, auth_subjects: Array[String], now_msec: int) -> bool:
	if _auth_failure_record_is_expired(entry.admin_auth_connection_failure, now_msec):
		entry.admin_auth_connection_failure.clear()
	elif _auth_failure_record_is_blocked(entry.admin_auth_connection_failure, now_msec):
		return true
	for auth_subject in auth_subjects:
		if not _auth_failures_by_subject.has(auth_subject):
			continue
		var record := _auth_failures_by_subject[auth_subject] as Dictionary
		if _auth_failure_record_is_expired(record, now_msec):
			_auth_failures_by_subject.erase(auth_subject)
			continue
		if _auth_failure_record_is_blocked(record, now_msec):
			return true
	return false


func _record_admin_auth_failure_attempt(
		entry: PeerEntry, auth_subjects: Array[String], now_msec: int) -> bool:
	entry.admin_auth_connection_failure = _advance_auth_failure_record(
		entry.admin_auth_connection_failure, now_msec)
	var missing_subjects := 0
	for auth_subject in auth_subjects:
		if not _auth_failures_by_subject.has(auth_subject):
			missing_subjects += 1
	var fully_recorded := (
		_auth_failures_by_subject.size() + missing_subjects <= MAX_AUTH_FAILURE_SUBJECTS)
	for auth_subject in auth_subjects:
		if fully_recorded or _auth_failures_by_subject.has(auth_subject):
			var record := _auth_failures_by_subject.get(auth_subject, {}) as Dictionary
			_auth_failures_by_subject[auth_subject] = _advance_auth_failure_record(
				record, now_msec)
	if not fully_recorded:
		_auth_failure_capacity_rejects += 1
	return fully_recorded


func _send_admin_rate_limited(pid: int, entry: PeerEntry, now_msec: int) -> void:
	if now_msec < entry.next_admin_auth_rate_limit_reply_msec:
		_auth_rate_limit_replies_suppressed += 1
		return
	entry.next_admin_auth_rate_limit_reply_msec = (
		now_msec + AUTH_RATE_LIMIT_REPLY_INTERVAL_MSEC)
	_send_admin_packet(pid, _build("adm_fail", ["rate_limited"]))


func _process_auth_failure_cleanup(now_msec: int) -> void:
	if now_msec < _next_auth_failure_cleanup_msec:
		return
	_next_auth_failure_cleanup_msec = now_msec + AUTH_FAILURE_CLEANUP_INTERVAL_MSEC
	for auth_subject_value in _auth_failures_by_subject.keys():
		var auth_subject := auth_subject_value as String
		var record := _auth_failures_by_subject[auth_subject] as Dictionary
		if _auth_failure_record_is_expired(record, now_msec):
			_auth_failures_by_subject.erase(auth_subject)


func _handle_admin_logout(pid: int, entry: PeerEntry, args: Array) -> void:
	if not args.is_empty():
		return
	var previous_id := entry.admin_id
	_cancel_server_list_queries(entry)
	entry.admin_id = ""
	_send_admin_packet(pid, _build("adm_fail", ["logged_out"]))
	if not previous_id.is_empty():
		_append_audit("remote", previous_id, "admin_logout", pid, entry.display_name, 0, "", "ok")


func _handle_admin_roster(pid: int, entry: PeerEntry, args: Array) -> void:
	if not _admin_request_is_valid(entry, args):
		_send_admin_failure_for_request(pid, args, "roster", "not_authorized_or_invalid")
		return
	_queue_list_query(entry, "roster", str(args[0]))


func _build_roster_snapshot(entry: PeerEntry, args: Array) -> Dictionary:
	var request_id := args[0] as String
	var packets: Array = [_build("adm_roster_begin", [request_id, str(_moderation_revision)])]
	var peer_ids := _peers.keys()
	peer_ids.sort()
	var now := int(Time.get_unix_time_from_system())
	for peer_id_value in peer_ids:
		var online := _peers[peer_id_value] as PeerEntry
		if not _peer_is_fully_admitted(online):
			continue
		var room_label := (
			"banned" if _peer_is_banned(online)
			else ("private" if online.privacy_mode == 1 else str(online.room_id)))
		packets.append(_build("adm_roster_item", [
			request_id,
			str(online.id),
			online.display_name,
			room_label,
			str(online.muted_until_unix if online.muted_permanent or online.muted_until_unix > now else 0),
			str(online.banned_until_unix if online.banned_permanent or online.banned_until_unix > now else 0),
			"1" if not online.admin_id.is_empty() else "0",
			_network_label_for_entry(online),
		]))
		if entry.player_list_capable and _punishment_store != null:
			packets.append(_build("adm_roster_item2", [
				request_id,
				str(online.id),
				_punishment_store.subject_group_id_for_installation(
					online.installation_identity),
			]))
	packets.append(_build("adm_roster_end", [request_id, str(_moderation_revision)]))
	return _freeze_list_packets(packets)


func _handle_admin_bans(pid: int, entry: PeerEntry, args: Array) -> void:
	if not _admin_request_is_valid(entry, args):
		_send_admin_failure_for_request(pid, args, "bans", "not_authorized_or_invalid")
		return
	_queue_list_query(entry, "bans", str(args[0]))


func _admin_request_is_valid(entry: PeerEntry, args: Array) -> bool:
	return (not entry.admin_id.is_empty()
		and _admin_store != null and _admin_store.has_enabled(entry.admin_id)
		and args.size() == 1 and _is_bounded_int(args[0], 1, MAX_ROOM_ID))


func _send_admin_failure_for_request(
		pid: int, args: Array, action: String, code: String) -> void:
	var request_id := str(args[0]) if not args.is_empty() else "0"
	if action in ["roster", "bans"] and _peers.has(pid):
		_list_query_failure(_peers[pid] as PeerEntry, action, request_id, code)
	else:
		_send_admin_result(pid, request_id, action, false, code, "")


func _handle_admin_action(pid: int, entry: PeerEntry, args: Array) -> void:
	if (entry.admin_id.is_empty() or _admin_store == null
			or not _admin_store.has_enabled(entry.admin_id)):
		_send_admin_failure_for_request(pid, args, "unknown", "not_authorized")
		return
	if (args.size() != 6 or not _is_bounded_int(args[0], 1, MAX_ROOM_ID)
			or typeof(args[1]) != TYPE_STRING or typeof(args[2]) != TYPE_STRING
			or (args[2] as String).length() > 100
			or not _is_bounded_int(args[3], 0, MAX_MODERATION_DURATION_SECONDS)
			or (args[4] as String) not in [
				PunishmentStoreScript.DURATION_FINITE,
				PunishmentStoreScript.DURATION_PERMANENT]
			or not _is_bounded_int(args[5], 0, 1)):
		_send_admin_failure_for_request(pid, args, "unknown", "invalid_request")
		return
	var request_id := args[0] as String
	var action := (args[1] as String).to_lower()
	var subject := args[2] as String
	var duration := int(args[3])
	var duration_mode := args[4] as String
	var include_network := (args[5] as String) == "1"
	match action:
		"announce":
			var message := subject.strip_edges()
			if (message.is_empty() or duration != 0
					or duration_mode != PunishmentStoreScript.DURATION_FINITE
					or include_network):
				_send_admin_result(pid, request_id, action, false, "invalid_announcement", "")
				return
			_broadcast_global_event(_build("server_notice", ["announcement", message]))
			_append_audit("remote", entry.admin_id, action, 0, "", 0, message, "ok")
			_send_admin_result(pid, request_id, action, true, "ok", "announcement sent")
		"unban":
			_execute_remote_unban(pid, entry, request_id, subject)
		"punishment_update":
			_execute_remote_update_punishment(
				pid, entry, request_id, subject, duration, duration_mode, include_network)
		"mute", "unmute", "ban", "set_mute", "set_ban", "revoke_mute", "revoke_ban":
			_execute_remote_player_action(
				pid, entry, request_id, action, subject, duration,
				duration_mode, include_network)
		_:
			_send_admin_result(pid, request_id, action, false, "unsupported_action", "")


func _execute_remote_player_action(
		actor_pid: int, actor: PeerEntry, request_id: String, action: String,
		target_text: String, duration: int, duration_mode: String,
		include_network: bool) -> void:
	if not _is_bounded_int(target_text, 1, MAX_ROOM_ID):
		_send_admin_result(actor_pid, request_id, action, false, "invalid_target", "")
		return
	var target_pid := int(target_text)
	if not _peers.has(target_pid):
		_send_admin_result(actor_pid, request_id, action, false, "target_offline", "")
		return
	var target := _peers[target_pid] as PeerEntry
	if not _peer_is_fully_admitted(target):
		_send_admin_result(actor_pid, request_id, action, false, "target_offline", "")
		return
	if not target.admin_id.is_empty():
		_send_admin_result(actor_pid, request_id, action, false, "target_is_admin", "")
		return
	if action in ["set_mute", "set_ban"]:
		_execute_remote_set_player_punishment(
			actor_pid, actor, request_id, action, target_pid, target, duration,
			duration_mode, include_network)
		return
	if action in ["revoke_mute", "revoke_ban"]:
		_execute_remote_revoke_player_punishment(
			actor_pid, actor, request_id, action, target_pid, target)
		return
	if (action in ["mute", "ban"] and _punishment_store != null
			and _network_change_includes_admin({}, include_network
				or not PunishmentStoreScript.installation_identity_is_usable(target.installation_identity),
				duration, duration_mode, target.punishment_address)):
		_send_admin_result(actor_pid, request_id, action, false,
			"network_identity_includes_admin", "该IP下有在线管理员，不能新增或延长IP处罚")
		return
	match action:
		"mute":
			if not _moderation_duration_is_valid(
					duration, duration_mode, MAX_MUTE_DURATION_SECONDS):
				_send_admin_result(actor_pid, request_id, action, false, "invalid_duration", "")
				return
			if _punishment_store == null:
				_send_admin_result(actor_pid, request_id, action, false, "punishment_store_unavailable", "")
				return
			var mute_result := _punishment_store.add_subject_mute(
				target.punishment_address, target.installation_identity,
				target.display_name, duration, actor.admin_id,
				include_network, duration_mode)
			if not bool(mute_result.get("ok", false)):
				_send_admin_result(actor_pid, request_id, action, false, "mute_failed",
					str(mute_result.get("error", "")))
				return
			_refresh_all_peer_punishments()
		"unmute":
			if _punishment_store == null:
				_send_admin_result(actor_pid, request_id, action, false, "punishment_store_unavailable", "")
				return
			var unmute_result := _punishment_store.revoke_active_for_subjects(
				target.punishment_address, target.installation_identity,
				PunishmentStoreScript.KIND_MUTE, actor.admin_id)
			if not bool(unmute_result.get("ok", false)):
				_send_admin_result(actor_pid, request_id, action, false, "unmute_failed",
					str(unmute_result.get("error", "")))
				return
			_refresh_all_peer_punishments()
		"ban":
			if not _moderation_duration_is_valid(
					duration, duration_mode, MAX_MODERATION_DURATION_SECONDS):
				_send_admin_result(actor_pid, request_id, action, false, "invalid_duration", "")
				return
			if _punishment_store == null:
				_send_admin_result(actor_pid, request_id, action, false, "ban_store_unavailable", "")
				return
			var result := _punishment_store.add_subject_ban(
				target.punishment_address, target.installation_identity,
				target.display_name, duration, actor.admin_id,
				include_network, duration_mode)
			if not bool(result.get("ok", false)):
				_send_admin_result(actor_pid, request_id, action, false, "ban_failed",
					str(result.get("error", "")))
				return
			var ban := result.get("ban", {}) as Dictionary
			_append_audit("remote", actor.admin_id, action, target_pid,
				target.display_name, duration, "", "ok")
			_send_admin_result(actor_pid, request_id, action, true, "ok", str(ban.get("id", "")))
			_refresh_all_peer_punishments()
			_advance_moderation_revision()
			return
	_append_audit("remote", actor.admin_id, action, target_pid,
		target.display_name, duration, "", "ok")
	_advance_moderation_revision()
	_send_admin_result(actor_pid, request_id, action, true, "ok",
		"#%d %s" % [target_pid, target.display_name])


func _execute_remote_set_player_punishment(
		actor_pid: int, actor: PeerEntry, request_id: String, action: String,
		target_pid: int, target: PeerEntry, duration: int,
		duration_mode: String, include_network: bool) -> void:
	if _punishment_store == null:
		_send_admin_result(actor_pid, request_id, action, false,
			"punishment_store_unavailable", "")
		return
	var kind := (
		PunishmentStoreScript.KIND_MUTE
		if action == "set_mute"
		else PunishmentStoreScript.KIND_BAN)
	var maximum := (
		MAX_MUTE_DURATION_SECONDS
		if kind == PunishmentStoreScript.KIND_MUTE
		else MAX_MODERATION_DURATION_SECONDS)
	if not _moderation_duration_is_valid(duration, duration_mode, maximum):
		_send_admin_result(actor_pid, request_id, action, false, "invalid_duration", "")
		return
	var existing := _punishment_store.find_active_owned_by_subjects(
		target.punishment_address, target.installation_identity, -1, kind)
	if _network_change_includes_admin(existing, include_network
			or (existing.is_empty() and not PunishmentStoreScript.installation_identity_is_usable(target.installation_identity)),
			duration, duration_mode,
			target.punishment_address):
		_send_admin_result(actor_pid, request_id, action, false,
			"network_identity_includes_admin", "该IP下有在线管理员，不能新增或延长IP处罚")
		return
	var result: Dictionary
	if existing.is_empty():
		result = (
			_punishment_store.add_subject_mute(
				target.punishment_address, target.installation_identity,
				target.display_name, duration, actor.admin_id,
				include_network, duration_mode)
			if kind == PunishmentStoreScript.KIND_MUTE
			else _punishment_store.add_subject_ban(
				target.punishment_address, target.installation_identity,
				target.display_name, duration, actor.admin_id,
				include_network, duration_mode))
	else:
		result = _punishment_store.update_punishment(
			str(existing.get("id", "")), duration, duration_mode,
			include_network, target.punishment_address, target.installation_identity)
	if not bool(result.get("ok", false)):
		_send_admin_result(actor_pid, request_id, action, false,
			"punishment_update_failed", str(result.get("error", "")))
		return
	_advance_moderation_revision()
	_refresh_all_peer_punishments()
	_append_audit("remote", actor.admin_id, action, target_pid,
		target.display_name, duration, "", "ok")
	_send_admin_result(actor_pid, request_id, action, true, "ok",
		str((result.get("ban", {}) as Dictionary).get("id", "")))


func _moderation_duration_is_valid(
		duration: int, duration_mode: String, maximum: int) -> bool:
	if duration_mode == PunishmentStoreScript.DURATION_PERMANENT:
		return duration == 0
	return (duration_mode == PunishmentStoreScript.DURATION_FINITE
		and duration >= 60 and duration <= maximum)


func _execute_remote_revoke_player_punishment(
		actor_pid: int, actor: PeerEntry, request_id: String, action: String,
		target_pid: int, target: PeerEntry) -> void:
	if _punishment_store == null:
		_send_admin_result(actor_pid, request_id, action, false,
			"punishment_store_unavailable", "")
		return
	var kind := (
		PunishmentStoreScript.KIND_MUTE
		if action == "revoke_mute"
		else PunishmentStoreScript.KIND_BAN)
	var result := _punishment_store.revoke_active_for_subjects(
		target.punishment_address, target.installation_identity, kind, actor.admin_id)
	if not bool(result.get("ok", false)):
		if str(result.get("error", "")) == "active punishment not found":
			_send_admin_result(actor_pid, request_id, action, true, "already_expired", "")
			return
		_send_admin_result(actor_pid, request_id, action, false,
			"punishment_revoke_failed", str(result.get("error", "")))
		return
	_advance_moderation_revision()
	_refresh_all_peer_punishments()
	_append_audit("remote", actor.admin_id, action, target_pid,
		target.display_name, 0, "", "ok")
	_send_admin_result(actor_pid, request_id, action, true, "ok", "")


func _network_change_includes_admin(
		existing: Dictionary, include_network: bool, duration: int,
		duration_mode: String, address: String) -> bool:
	var has_network := PunishmentStoreScript.record_has_network_scope(existing)
	# Legacy network-only records cannot drop their only subject by clearing a flag.
	var retains_network := include_network or str(existing.get("scope", "")) == "network"
	if not retains_network:
		return false
	if has_network:
		if str(existing.get("duration_mode", "finite")) == "permanent":
			return false
		var new_expiry := int(Time.get_unix_time_from_system()) + duration
		if duration_mode != "permanent" and new_expiry <= int(existing.get("expires_at", 0)):
			return false
	for value in _peers.values():
		var candidate := value as PeerEntry
		if not _peer_is_fully_admitted(candidate) or candidate.admin_id.is_empty():
			continue
		if has_network:
			# Empty installation identity restricts this comparison to the stored
			# network digest, not the record owner's present address/installation.
			if _punishment_store.record_matches_subjects(existing, candidate.punishment_address, ""):
				return true
		elif (PunishmentStoreScript.address_is_usable(address)
				and PunishmentStoreScript.normalize_address(candidate.punishment_address)
				== PunishmentStoreScript.normalize_address(address)):
			return true
	return false


func _execute_remote_unban(
		pid: int, actor: PeerEntry, request_id: String, ban_id: String) -> void:
	if _punishment_store == null:
		_send_admin_result(pid, request_id, "unban", false, "ban_store_unavailable", "")
		return
	var result := _punishment_store.revoke(ban_id, actor.admin_id)
	if not bool(result.get("ok", false)):
		_send_admin_result(pid, request_id, "unban", false, "unban_failed",
			str(result.get("error", "")))
		return
	_advance_moderation_revision()
	_refresh_all_peer_punishments()
	_append_audit("remote", actor.admin_id, "unban", 0, ban_id, 0, "", "ok")
	_send_admin_result(pid, request_id, "unban", true, "ok", ban_id)


func _set_peer_mute(entry: PeerEntry, until_unix: int) -> void:
	entry.muted_until_unix = until_unix
	entry.muted_permanent = false


func _peer_is_banned(entry: PeerEntry, now_unix: int = -1) -> bool:
	if entry.banned_permanent:
		return true
	var current := int(Time.get_unix_time_from_system()) if now_unix < 0 else now_unix
	return entry.banned_until_unix > current


func _force_ban_mode(pid: int, entry: PeerEntry, now_msec: int) -> void:
	if entry.privacy_pre_ban_mode < 0:
		entry.privacy_pre_ban_mode = entry.privacy_mode
	entry.privacy_pending = false
	_pending_privacy_updates.erase(pid)
	_apply_privacy_mode(pid, entry, 1, now_msec)


func _refresh_peer_punishments(
		pid: int, entry: PeerEntry, now_unix: int, notify: bool = true) -> void:
	var active_mute: Dictionary = {}
	var active_ban: Dictionary = {}
	if _punishment_store != null:
		if entry.position_seen:
			_punishment_store.update_active_profile_for_subjects(
				entry.punishment_address, entry.installation_identity,
				_peer_profile(entry), now_unix)
		active_mute = _punishment_store.find_active_for_subjects(
			entry.punishment_address, entry.installation_identity,
			now_unix, PunishmentStoreScript.KIND_MUTE)
		active_ban = _punishment_store.find_active_for_subjects(
			entry.punishment_address, entry.installation_identity,
			now_unix, PunishmentStoreScript.KIND_BAN)

	entry.muted_until_unix = int(active_mute.get("expires_at", 0))
	entry.banned_until_unix = int(active_ban.get("expires_at", 0))
	entry.muted_permanent = (
		str(active_mute.get("duration_mode", "finite")) == "permanent")
	entry.banned_permanent = (
		str(active_ban.get("duration_mode", "finite")) == "permanent")
	entry.muted_network_scope = (
		not active_mute.is_empty()
		and PunishmentStoreScript.record_has_network_scope(active_mute))
	entry.banned_network_scope = (
		not active_ban.is_empty()
		and PunishmentStoreScript.record_has_network_scope(active_ban))

	var now_msec := Time.get_ticks_msec()
	if _peer_is_banned(entry, now_unix):
		_force_ban_mode(pid, entry, now_msec)
	elif entry.privacy_pre_ban_mode >= 0:
		var restore_mode := entry.privacy_pre_ban_mode
		entry.privacy_pre_ban_mode = -1
		_apply_privacy_mode(pid, entry, restore_mode, now_msec)
		# The local countdown can reach zero before the periodic mod_status packet,
		# so a client cannot reliably infer this transition from its timer alone.
		# Send the authoritative privacy state with the last accepted sequence; the
		# matching client then performs the required strict room rejoin.
		if entry.privacy_capable:
			_queue_privacy_status(
				pid, "accepted", restore_mode, entry.privacy_request_seq, 0)

	if notify:
		_send_moderation_status(pid, entry, now_unix)


func _refresh_all_peer_punishments() -> void:
	var now_unix := int(Time.get_unix_time_from_system())
	for pid_value in _peers.keys():
		var pid := int(pid_value)
		_refresh_peer_punishments(pid, _peers[pid] as PeerEntry, now_unix)


func _send_moderation_status(
		pid: int, entry: PeerEntry, server_unix: int = -1) -> void:
	var current := int(Time.get_unix_time_from_system()) if server_unix < 0 else server_unix
	_send_control(pid, "mod_status", _build("mod_status", [
		str(current),
		"permanent" if entry.muted_permanent else "finite",
		str(entry.muted_until_unix if entry.muted_until_unix > current else 0),
		"permanent" if entry.banned_permanent else "finite",
		str(entry.banned_until_unix if entry.banned_until_unix > current else 0),
	]))


func _process_moderation_status(now_msec: int) -> void:
	var now_unix := int(Time.get_unix_time_from_system())
	if now_msec >= _next_punishment_maintenance_msec:
		_next_punishment_maintenance_msec = (
			now_msec + PUNISHMENT_STORE_MAINTENANCE_INTERVAL_MSEC)
		if _punishment_store != null and _punishment_store.prune_expired(now_unix):
			_advance_moderation_revision()
	if now_msec >= _next_moderation_expiry_check_msec:
		_next_moderation_expiry_check_msec = (
			now_msec + MODERATION_EXPIRY_CHECK_INTERVAL_MSEC)
		for pid_value in _peers.keys():
			var pid := int(pid_value)
			var entry := _peers[pid] as PeerEntry
			if ((not entry.muted_permanent
						and entry.muted_until_unix > 0 and entry.muted_until_unix <= now_unix)
					or (not entry.banned_permanent
						and entry.banned_until_unix > 0 and entry.banned_until_unix <= now_unix)):
				_refresh_peer_punishments(pid, entry, now_unix)

	if now_msec < _next_moderation_sync_msec:
		return
	_next_moderation_sync_msec = now_msec + MODERATION_STATUS_SYNC_INTERVAL_MSEC
	for pid_value in _peers.keys():
		var entry := _peers[pid_value] as PeerEntry
		if (entry.moderation_capable
				and (entry.muted_permanent or entry.banned_permanent
					or entry.muted_until_unix > now_unix
					or entry.banned_until_unix > now_unix)):
			_send_moderation_status(int(pid_value), entry, now_unix)


func _send_admin_result(
		pid: int, request_id: String, action: String, success: bool,
		code: String, detail: String) -> void:
	_send_admin_packet(pid, _build("adm_result", [
		request_id, action, "1" if success else "0", code, detail.left(200)]))


func _queue_list_query(entry: PeerEntry, kind: String, request_id: String) -> void:
	if not entry.list_snapshot.is_empty() and entry.list_snapshot.kind == kind:
		if str(entry.list_snapshot.id) != request_id:
			_list_query_failure(entry, kind, request_id, "busy")
		return
	if entry.list_waiting.has(kind) and str(entry.list_waiting[kind].id) == request_id:
		return
	entry.list_waiting[kind] = {"id": request_id, "started": Time.get_ticks_msec()}


func _list_query_failure(entry: PeerEntry, kind: String, request_id: String, code: String) -> void:
	if kind == "plist":
		if entry.list_query_capable:
			_send_control(entry.id, "list:" + kind, _build("plist_fail", [request_id, code]))
	else:
		_send_control(entry.id, "list:" + kind,
			_build("adm_result", [request_id, kind, "0", code, ""]))


func _release_list_snapshot(entry: PeerEntry) -> void:
	if not entry.list_snapshot.is_empty():
		_list_snapshot_bytes -= int(entry.list_snapshot.bytes) + MAX_OUTBOUND_FRAME_BYTES
	entry.list_snapshot.clear()
	entry.list_frame = PackedByteArray()
	entry.list_frame_sequence = 0
	entry.list_frame_end = 0


func _cancel_server_list_queries(entry: PeerEntry) -> void:
	_release_list_snapshot(entry)
	entry.list_waiting.clear()
	for kind in ["plist", "roster", "bans"]:
		entry.pending_control.erase("list:" + kind)


func _append_list_packet(view: Dictionary, packet: String) -> bool:
	if not str(view.error).is_empty():
		return false
	var fields := packet.split(PARAM_DELIM, true)
	if packet.length() > MAX_MESSAGE_CHARS or fields.size() - 1 > MAX_PACKET_ARGS:
		view.error = "invalid_data"
		return false
	for field in fields:
		if field.length() > MAX_ARG_CHARS or field.contains(MSG_DELIM):
			view.error = "invalid_data"
			return false
	var bytes := packet.to_utf8_buffer()
	if bytes.has(0) or bytes.size() > MAX_OUTBOUND_FRAME_BYTES:
		view.error = "invalid_data"
		return false
	if int(view.bytes) + bytes.size() > MAX_LIST_SNAPSHOT_BYTES:
		view.error = "too_large"
		return false
	view.bytes += bytes.size()
	view.records.append(bytes)
	return true


func _freeze_list_packets(packets: Array) -> Dictionary:
	var view := {"records": [], "bytes": 0, "error": ""}
	for packet in packets:
		if not _append_list_packet(view, str(packet)):
			break
	return view


func _build_bans_snapshot(entry: PeerEntry, request_id: String) -> Dictionary:
	var view := _freeze_list_packets([_build("adm_bans_begin", [request_id, str(_moderation_revision)])])
	var rows: Array = []
	if _punishment_store != null:
		_punishment_store.visit_active_for_snapshot(func(record: Dictionary) -> bool:
			# Reject stored values that would change the wire fields. Never alter a stored ID.
			for field in ["id", "actor", "last_name", "last_system_name", "last_sprite_name"]:
				var value := str(record.get(field, ""))
				var limit := 32 if field in ["id", "actor"] else MAX_ARG_CHARS
				if (value.length() > limit or value.contains(PARAM_DELIM)
						or value.contains(MSG_DELIM) or value.to_utf8_buffer().has(0)):
					view.error = "invalid_data"
					return false
			for field in ["created_at", "expires_at"]:
				if not _is_bounded_int(str(record.get(field, 0)), 0, MAX_PROTOCOL_COUNTER):
					view.error = "invalid_data"
					return false
			var start: int = view.records.size()
			if not _append_list_packet(view, _build("adm_bans_item", [request_id,
				str(record.id), str(record.kind), str(record.get("last_name", "")),
				str(record.get("network_label", "")), str(record.get("expires_at", 0)),
				str(record.get("actor", ""))])):
				return false
			if entry.player_list_capable:
				if (not _append_list_packet(view, _build_punishment_profile_packet(request_id, record))
						or not _append_list_packet(view, _build_punishment_identity_packet(request_id, record))):
					return false
			rows.append({"finite": PunishmentStoreScript.record_duration_mode(record) == PunishmentStoreScript.DURATION_FINITE,
				"expires": int(record.get("expires_at", 0)), "packets": view.records.slice(start)})
			return true)
	if not str(view.error).is_empty():
		return view
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return bool(a.finite) if a.finite != b.finite else int(a.expires) < int(b.expires))
	var ordered: Array = [view.records[0]]
	for row in rows:
		ordered.append_array(row.packets)
	view.records = ordered
	_append_list_packet(view, _build("adm_bans_end", [request_id, str(_moderation_revision)]))
	return view


func _pump_list_frame(entry: PeerEntry, now: int) -> void:
	for kind in entry.list_waiting.keys():
		var waiting: Dictionary = entry.list_waiting[kind]
		if now - int(waiting.started) >= LIST_QUERY_IDLE_MSEC:
			entry.list_waiting.erase(kind)
			_list_query_failure(entry, kind, str(waiting.id), "timeout")
	if not entry.list_snapshot.is_empty():
		var active := entry.list_snapshot
		if (now - int(active.progress) >= LIST_QUERY_IDLE_MSEC
				or now - int(active.started) >= LIST_QUERY_TOTAL_MSEC):
			_list_query_failure(entry, str(active.kind), str(active.id), "timeout")
			_release_list_snapshot(entry)
	if not entry.list_frame.is_empty():
		return
	if entry.list_snapshot.is_empty():
		if (entry.list_waiting.is_empty()
				or _list_snapshot_bytes + MAX_LIST_SNAPSHOT_BYTES + MAX_OUTBOUND_FRAME_BYTES > MAX_LIST_SNAPSHOTS_BYTES):
			return
		if not _seal_global_batch(entry) or not _seal_room_batch(entry):
			return
		var kind: String = entry.list_waiting.keys()[0]
		var request: Dictionary = entry.list_waiting[kind]
		entry.list_waiting.erase(kind)
		var request_id := str(request.id)
		if ((kind == "plist" and (entry.room_id < 0 or entry.privacy_mode != 0))
				or (kind != "plist" and not _admin_request_is_valid(entry, [request_id]))):
			_list_query_failure(entry, kind, request_id, "unavailable")
			return
		var view: Dictionary
		match kind:
			"plist": view = _build_plist_snapshot(entry, [request_id])
			"roster": view = _build_roster_snapshot(entry, [request_id])
			_: view = _build_bans_snapshot(entry, request_id)
		if not str(view.error).is_empty():
			_list_query_failure(entry, kind, request_id, str(view.error))
			return
		view.merge({"kind": kind, "id": request_id, "cursor": 0,
			"started": int(request.started), "progress": now})
		entry.list_snapshot = view
		_list_snapshot_bytes += int(view.bytes) + MAX_OUTBOUND_FRAME_BYTES
	# Freeze and begin sequence are assigned without yielding to new state changes.
	if not _seal_global_batch(entry) or not _seal_room_batch(entry):
		return
	var snapshot := entry.list_snapshot
	var index := int(snapshot.cursor)
	var records: Array = snapshot.records
	var frame := PackedByteArray()
	var messages := 0
	var delimiter := MSG_DELIM.to_utf8_buffer()
	while index < records.size() and messages < MAX_OUTBOUND_MESSAGES_PER_FRAME:
		var record: PackedByteArray = records[index]
		if not frame.is_empty() and frame.size() + delimiter.size() + record.size() > MAX_OUTBOUND_BATCH_BYTES:
			break
		if not frame.is_empty():
			frame.append_array(delimiter)
		frame.append_array(record)
		messages += 1
		index += 1
	entry.list_frame = frame
	entry.list_frame_end = index
	entry.list_frame_sequence = _take_output_sequence(entry)


func _complete_list_frame(entry: PeerEntry) -> void:
	var view := entry.list_snapshot
	var records: Array = view.records
	for index in range(int(view.cursor), entry.list_frame_end):
		var bytes: PackedByteArray = records[index]
		_list_snapshot_bytes -= bytes.size()
		view.bytes -= bytes.size()
		records[index] = PackedByteArray()
	view.cursor = entry.list_frame_end
	view.progress = Time.get_ticks_msec()
	entry.list_frame = PackedByteArray()
	entry.list_frame_sequence = 0
	if int(view.cursor) >= records.size():
		_release_list_snapshot(entry)


func _send_admin_packet(pid: int, packet: String) -> void:
	_send_admin_packets(pid, [packet])


func _send_admin_packets(pid: int, packets: Array) -> void:
	if not _peers.has(pid):
		return
	var entry := _peers[pid] as PeerEntry
	_queue_global_record(entry, packets)

func _handle_resume(pid: int, entry: PeerEntry, args: Array) -> void:
	if not entry.install_identity_complete:
		_warn_peer(pid, "identity_required",
			"[EasyServer] rejected resume before install identity from peer %d" % pid)
		_close_and_detach_peer(
			pid, CLIENT_UPDATE_REQUIRED_CLOSE_CODE, "identity required")
		return
	if not entry.resume_capable:
		_warn_peer(pid, "resume_unnegotiated",
			"[EasyServer] rejected unnegotiated resume from peer %d" % pid)
		return
	if entry.resume_complete or not entry.resume_token.is_empty():
		_warn_peer(pid, "resume_repeated",
			"[EasyServer] ignored repeated resume from peer %d" % pid)
		return
	if (args.size() != 2
			or typeof(args[0]) != TYPE_STRING
			or (not (args[0] as String).is_empty()
				and not _is_valid_resume_token(args[0] as String))
			or not _is_bounded_int(args[1], 1, MAX_ROOM_ID)):
		_warn_peer(pid, "resume_shape",
			"[EasyServer] rejected malformed resume from peer %d" % pid)
		_close_and_detach_peer(pid, 1008, "invalid resume handshake")
		return

	var requested_token := (args[0] as String).to_lower()
	var attempt := int(args[1])
	var now_msec := Time.get_ticks_msec()
	var session: ResumeSession = null
	if not requested_token.is_empty() and _resume_sessions.has(requested_token):
		session = _resume_sessions[requested_token] as ResumeSession
		if (session.current_pid < 0
				and session.expires_msec > 0
				and now_msec >= session.expires_msec):
			_erase_resume_session(requested_token)
			session = null

	var token := requested_token
	if session == null:
		# Empty, unknown, and expired credentials all begin a fresh anonymous
		# process session. Only the server chooses bearer-token values.
		token = _generate_resume_token()
		session = ResumeSession.new()
		session.token = token
		var crypto := Crypto.new()
		session.public_chat_id = crypto.generate_random_bytes(16).hex_encode()
		while _public_chat_sessions.has(session.public_chat_id):
			session.public_chat_id = crypto.generate_random_bytes(16).hex_encode()
		session.installation_identity = entry.installation_identity
		_resume_sessions[token] = session
		_public_chat_sessions[session.public_chat_id] = session
	elif session.installation_identity != entry.installation_identity:
		_warn_peer(pid, "resume_identity",
			"[EasyServer] rejected resume identity mismatch from peer %d" % pid)
		_close_and_detach_peer(
			pid, INVALID_INSTALL_IDENTITY_CLOSE_CODE, "identity invalid")
		return
	elif attempt <= session.highest_attempt:
		_warn_peer(pid, "resume_stale",
			"[EasyServer] rejected stale resume attempt %d from peer %d" % [attempt, pid])
		# A stale connection must not keep incrementing and steal the session back.
		# The client treats 4001 as terminal for this reconnect generation.
		_close_and_detach_peer(pid, SESSION_REPLACED_CLOSE_CODE, "session replaced")
		return

	var old_pid := session.current_pid
	if old_pid >= 0 and old_pid != pid and _peers.has(old_pid):
		_sync_privacy_to_resume_session(_peers[old_pid] as PeerEntry)
		_sync_global_chat_to_resume_session(_peers[old_pid] as PeerEntry)
	# Privacy request sequence numbers belong to one transport/resume-attempt.
	# Preserve the authoritative mode and cooldown deadline, but never let an
	# ownerless queued target fire after handoff. The new client reasserts its
	# desired state with sequence 1 after resume_ok.
	session.privacy_requested = session.privacy_mode
	session.privacy_request_seq = 0
	session.privacy_pending = false
	# Install the new owner first. Cleanup of the old transport is compare-safe
	# and therefore cannot turn this newly active session into an inactive one.
	session.current_pid = pid
	session.highest_attempt = attempt
	session.expires_msec = 0
	entry.resume_token = token
	entry.resume_attempt = attempt
	_restore_privacy_from_resume_session(entry, session)
	_restore_global_chat_from_resume_session(entry, session, now_msec)
	entry.privacy_pre_ban_mode = -1
	if _peer_is_banned(entry):
		_force_ban_mode(pid, entry, now_msec)

	if old_pid >= 0 and old_pid != pid and _peers.has(old_pid):
		var old_entry := _peers[old_pid] as PeerEntry
		old_entry.superseded = true
		_detach_peer(old_pid, old_entry, now_msec)
		old_entry.ws.close(SESSION_REPLACED_CLOSE_CODE, "session replaced")

	# resume_complete is set only after this control packet is successfully
	# written. Until then, every room-scoped client packet remains rejected.
	var resume_args: Array = [token, str(attempt)]
	if entry.chat_mentions_capable:
		resume_args.append(session.public_chat_id)
	_send_control(pid, "resume_ok", _build("resume_ok", resume_args))
	_send_moderation_status(pid, entry)


func _handle_privacy(pid: int, entry: PeerEntry, args: Array) -> void:
	if (not entry.privacy_capable
			or entry.protocol_mode == ProtocolMode.LEGACY
			or not entry.room_barrier_capable):
		_warn_peer(pid, "privacy_unnegotiated",
			"[EasyServer] rejected unnegotiated privacy request from peer %d" % pid)
		return
	if (args.size() != 2
			or not _is_bounded_int(args[0], 0, 1)
			or not _is_bounded_int(args[1], 1, MAX_ROOM_ID)):
		_warn_peer(pid, "privacy_shape",
			"[EasyServer] rejected malformed privacy request from peer %d" % pid)
		return

	var requested := int(args[0])
	var request_seq := int(args[1])
	var now_msec := Time.get_ticks_msec()
	if request_seq < entry.privacy_request_seq:
		_warn_peer(pid, "privacy_stale",
			"[EasyServer] ignored stale privacy request from peer %d" % pid)
		return
	if _peer_is_banned(entry):
		# Ban isolation is server-owned. A client may acknowledge it through the
		# normal privacy handshake, but cannot change the underlying privacy choice
		# or leave the isolated room while the punishment is active.
		entry.privacy_request_seq = request_seq
		entry.privacy_pending = false
		_pending_privacy_updates.erase(pid)
		_force_ban_mode(pid, entry, now_msec)
		_queue_privacy_status(pid, "accepted", 1, request_seq, 0)
		return
	if request_seq == entry.privacy_request_seq and request_seq > 0:
		if requested != entry.privacy_requested:
			_warn_peer(pid, "privacy_sequence_reuse",
				"[EasyServer] ignored reused privacy sequence from peer %d" % pid)
			return
		var duplicate_remaining := maxi(
			0, entry.privacy_cooldown_until_msec - now_msec)
		_queue_privacy_status(pid,
			"pending" if entry.privacy_pending else "accepted",
			entry.privacy_mode, request_seq, duplicate_remaining)
		return

	entry.privacy_requested = requested
	entry.privacy_request_seq = request_seq
	entry.privacy_revision += 1

	# A request for the already authoritative state is idempotent and also
	# cancels an opposite transition that had not yet left its cooldown.
	if requested == entry.privacy_mode:
		entry.privacy_pending = false
		_pending_privacy_updates.erase(pid)
		_sync_privacy_to_resume_session(entry)
		_queue_privacy_status(pid, "accepted", entry.privacy_mode, request_seq,
			maxi(0, entry.privacy_cooldown_until_msec - now_msec))
		return

	# Restrictive transitions never wait: once accepted, no further public
	# traffic can be sent by or delivered to this peer.
	if requested == 1:
		entry.privacy_pending = false
		_pending_privacy_updates.erase(pid)
		_apply_privacy_mode(pid, entry, 1, now_msec)
		_queue_privacy_status(pid, "accepted", 1, request_seq,
			maxi(0, entry.privacy_cooldown_until_msec - now_msec))
		return

	var remaining := maxi(0, entry.privacy_cooldown_until_msec - now_msec)
	if remaining > 0:
		entry.privacy_pending = true
		_pending_privacy_updates[pid] = true
		_sync_privacy_to_resume_session(entry)
		_queue_privacy_status(pid, "pending", entry.privacy_mode, request_seq, remaining)
		return

	entry.privacy_pending = false
	_pending_privacy_updates.erase(pid)
	_apply_privacy_mode(pid, entry, 0, now_msec)
	_queue_privacy_status(pid, "accepted", 0, request_seq,
		maxi(0, entry.privacy_cooldown_until_msec - now_msec))


func _apply_privacy_mode(
		pid: int, entry: PeerEntry, new_mode: int, now_msec: int) -> void:
	if entry.privacy_mode == new_mode:
		return
	_cancel_server_list_queries(entry)
	if new_mode == 1:
		var old_room := entry.room_id
		var intended_room := old_room if old_room >= 0 else entry.announced_room
		if intended_room >= 0:
			entry.private_room_id = intended_room
		# Departure must be ordered on every old public member's room stream
		# before this peer is removed from that public membership index.
		if old_room >= 0:
			_broadcast_departure(old_room, entry.id, pid)
		entry.privacy_mode = 1
		entry.needs_revive = false
		entry.announced_room = -1
		entry.room_epoch += 1
		_clear_room_output(entry)
		if old_room >= 0:
			_set_peer_room(entry, -1)
			_broadcast_cu_player_count(old_room)
	else:
		# Becoming public only changes eligibility. Membership is deliberately
		# left empty until a strict sr -> basic/m barrier commit rebuilds it.
		entry.privacy_mode = 0
		entry.needs_revive = true
		entry.announced_room = -1
		entry.room_epoch += 1
		_clear_room_output(entry)

	_pending_same_room_resyncs.erase(pid)
	entry.same_room_resync_room_id = -1
	entry.same_room_resync_due_msec = 0
	entry.same_room_snapshot_in_flight = false
	entry.privacy_cooldown_until_msec = now_msec + PRIVACY_COOLDOWN_MSEC
	_sync_privacy_to_resume_session(entry)

func _handle_sr(pid: int, entry: PeerEntry, args: Array) -> void:
	if entry.resume_capable and not entry.resume_complete:
		_warn_peer(pid, "resume_required",
			"[EasyServer] rejected room request before resume from peer %d" % pid)
		return
	if args.size() != 1 or not _is_bounded_int(args[0], 0, MAX_ROOM_ID):
		_warn_peer(pid, "room_request",
			"[EasyServer] rejected invalid room request from peer %d" % pid)
		return
	var new_room := int(args[0])
	if entry.protocol_mode == ProtocolMode.UNKNOWN:
		entry.protocol_mode = (ProtocolMode.STRICT
			if entry.room_barrier_capable else ProtocolMode.LEGACY)
	if entry.privacy_mode == 1:
		if entry.protocol_mode != ProtocolMode.STRICT:
			_warn_peer(pid, "privacy_protocol",
				"[EasyServer] rejected private room request without strict barrier from peer %d" % pid)
			return
		_handle_private_sr(pid, entry, new_room)
		return
	if entry.announced_room == new_room:
		return
	if entry.room_id == new_room:
		_handle_same_room_sr(pid, entry, new_room)
		return
	_begin_room_announcement(pid, entry, new_room,
		entry.protocol_mode == ProtocolMode.STRICT)
	if entry.protocol_mode == ProtocolMode.LEGACY:
		_commit_announced_room(pid, entry)


func _handle_private_sr(pid: int, entry: PeerEntry, new_room: int) -> void:
	# A private room is deliberately absent from the public membership index.
	# Its barrier still advances the epoch so stale public/private room output
	# cannot cross this request and reappear later.
	entry.room_epoch += 1
	_clear_room_output(entry)
	entry.announced_room = -1
	entry.private_room_id = new_room
	_pending_same_room_resyncs.erase(pid)
	entry.same_room_resync_room_id = -1
	entry.same_room_resync_due_msec = 0
	entry.same_room_snapshot_in_flight = false
	_send_room_barrier(pid, _build("ri", [str(new_room)]))
	_send_cu_snapshot(pid, new_room, true)


func _begin_room_announcement(
		pid: int, entry: PeerEntry, new_room: int, reset_stable_state: bool) -> void:
	var old_room := entry.room_id
	# Publish the new intent before leaving the old room. This keeps global-scope
	# delivery available throughout the barrier while room membership is absent.
	entry.room_epoch += 1
	_clear_room_output(entry)
	entry.announced_room = new_room
	if old_room >= 0:
		_broadcast_departure(old_room, entry.id, pid)
		entry.needs_revive = true
		_set_peer_room(entry, -1)
		_broadcast_cu_player_count(old_room)
	_pending_same_room_resyncs.erase(pid)
	entry.same_room_resync_room_id = new_room
	entry.same_room_resync_due_msec = 0
	entry.same_room_snapshot_in_flight = false
	if reset_stable_state:
		_reset_stable_state_for_strict_announcement(entry)


func _reset_stable_state_for_strict_announcement(entry: PeerEntry) -> void:
	entry.prev_map_id = 0
	entry.x = -1
	entry.y = -1
	entry.position_seen = false
	entry.facing = 2
	entry.speed = 4
	entry.sprite_name = ""
	entry.sprite_idx = 0
	entry.hidden = false
	entry.transparency = 0
	entry.sys_name = ""
	entry.display_name = ""


func _commit_announced_room(pid: int, entry: PeerEntry) -> void:
	if entry.announced_room < 0:
		return
	if entry.protocol_mode == ProtocolMode.STRICT and not entry.position_seen:
		return
	var new_room := entry.announced_room
	var revive_public_visibility := entry.needs_revive
	entry.announced_room = -1
	_set_peer_room(entry, new_room)
	Log.server_info("[EasyServer] peer %d joined room %d" % [pid, new_room])
	_send_room_barrier(pid, _build("ri", [str(new_room)]))
	_send_cu_snapshot(pid, new_room)
	_queue_presence(pid)
	var now_msec := Time.get_ticks_msec()
	var snapshot_result := _queue_room_snapshot_to(pid, new_room)
	entry.same_room_snapshot_in_flight = snapshot_result == SnapshotQueueResult.QUEUED
	entry.last_same_room_resync_msec = now_msec
	if snapshot_result == SnapshotQueueResult.DEFERRED:
		_schedule_same_room_snapshot_retry(pid, entry, now_msec)
	_broadcast_canonical_peer_state(
		new_room, entry, pid, revive_public_visibility)
	entry.needs_revive = false
	entry.private_room_id = -1
	_broadcast_cu_player_count(new_room)


func _handle_same_room_sr(pid: int, entry: PeerEntry, room_id: int) -> void:
	# Always acknowledge legitimate recovery requests immediately. CU data and
	# presence are absolute/latest values and are cheap to coalesce downstream.
	_send_room_barrier(pid, _build("ri", [str(room_id)]))
	_send_cu_snapshot(pid, room_id)
	if entry.presence_capable:
		_queue_presence(pid)

	var now_msec := Time.get_ticks_msec()
	if entry.same_room_resync_room_id != room_id:
		entry.same_room_resync_room_id = room_id
		entry.last_same_room_resync_msec = now_msec - SAME_ROOM_RESYNC_INTERVAL_MSEC
		entry.same_room_resync_due_msec = 0
		entry.same_room_snapshot_in_flight = false
	if (not entry.same_room_snapshot_in_flight
			and now_msec - entry.last_same_room_resync_msec
			>= SAME_ROOM_RESYNC_INTERVAL_MSEC):
		_pending_same_room_resyncs.erase(pid)
		entry.same_room_resync_due_msec = 0
		entry.last_same_room_resync_msec = now_msec
		var snapshot_result := _queue_room_snapshot_to(pid, room_id)
		entry.same_room_snapshot_in_flight = (
			snapshot_result == SnapshotQueueResult.QUEUED)
		if snapshot_result == SnapshotQueueResult.DEFERRED:
			_schedule_same_room_snapshot_retry(pid, entry, now_msec)
		return

	# Repeated requests never clear the first snapshot already queued. Keep one
	# pending retry and service it after both the interval and current snapshot.
	entry.same_room_resync_due_msec = maxi(
		now_msec, entry.last_same_room_resync_msec + SAME_ROOM_RESYNC_INTERVAL_MSEC)
	_pending_same_room_resyncs[pid] = true


func _queue_room_snapshot_to(target_pid: int, room_id: int) -> int:
	if not _peers.has(target_pid):
		return SnapshotQueueResult.EMPTY
	var target := _peers[target_pid] as PeerEntry
	if (not target.room_sync.is_empty() or target.identity_recovery_in_flight
			or (target.room_sync_last_kind == "full" and not target.identity_recovery_dirty.is_empty())):
		return SnapshotQueueResult.DEFERRED
	var sources: Array = []
	for source_pid in _room_member_ids(room_id):
		if source_pid != target_pid and _peers.has(source_pid):
			sources.append([source_pid, (_peers[source_pid] as PeerEntry).room_epoch])
	if sources.is_empty():
		return SnapshotQueueResult.EMPTY
	target.room_sync = {"kind": "full", "epoch": target.room_epoch,
		"sources": sources, "index": 0, "fence": 0}
	target.same_room_snapshot_in_flight = true
	_pump_room_sync_page(target)
	# QUEUED means accepted: remaining pages need not fit the transient queue.
	return SnapshotQueueResult.EMPTY if target.room_sync.is_empty() else SnapshotQueueResult.QUEUED

func _mark_identity_recovery(
		target: PeerEntry, source_pid: int, requires_clear: bool) -> void:
	if (target.detaching or target.room_id < 0 or not _peers.has(target.id)
			or not _peers.has(source_pid)):
		return
	var source := _peers[source_pid] as PeerEntry
	if source.room_id != target.room_id:
		return
	target.identity_recovery_revision += 1
	var revision := target.identity_recovery_revision
	var current := target.identity_recovery_dirty.get(source_pid, [0, 0]) as Array
	var required_clear_revision := int(current[1])
	if requires_clear:
		required_clear_revision = revision
	target.identity_recovery_dirty[source_pid] = [revision, required_clear_revision]
	var due_msec := Time.get_ticks_msec() + IDENTITY_RECOVERY_RETRY_MSEC
	if target.identity_recovery_due_msec <= 0:
		target.identity_recovery_due_msec = due_msec
	else:
		target.identity_recovery_due_msec = mini(
			target.identity_recovery_due_msec, due_msec)
	_pending_identity_recoveries[target.id] = true


func _discard_identity_recovery_source(target: PeerEntry, source_pid: int) -> void:
	target.identity_recovery_dirty.erase(source_pid)
	if target.identity_recovery_dirty.is_empty():
		target.identity_recovery_due_msec = 0
		if not target.identity_recovery_in_flight:
			_pending_identity_recoveries.erase(target.id)


func _clear_identity_recovery(target: PeerEntry) -> void:
	if target.room_sync.get("kind", "") == "recovery":
		target.room_sync.clear()
	_pending_identity_recoveries.erase(target.id)
	target.identity_recovery_dirty.clear()
	target.identity_recovery_revision = 0
	target.identity_recovery_due_msec = 0
	target.identity_recovery_in_flight = false
	target.identity_recovery_fence_batch_id = 0
	target.identity_recovery_fence_state_revisions.clear()
	target.identity_recovery_fence_clear_revisions.clear()


func _queue_identity_recovery_to(target_pid: int) -> int:
	if not _peers.has(target_pid):
		return SnapshotQueueResult.EMPTY
	var target := _peers[target_pid] as PeerEntry
	if (not target.room_sync.is_empty() or target.identity_recovery_in_flight
			or target.same_room_snapshot_in_flight
			or (target.room_sync_last_kind == "recovery" and _pending_same_room_resyncs.has(target_pid))):
		return SnapshotQueueResult.DEFERRED
	if target.room_id < 0:
		_clear_identity_recovery(target)
		return SnapshotQueueResult.EMPTY
	var sources: Array = []
	for source_pid in target.identity_recovery_dirty.keys():
		if not _peers.has(source_pid) or (_peers[source_pid] as PeerEntry).room_id != target.room_id:
			target.identity_recovery_dirty.erase(source_pid)
		else:
			sources.append([int(source_pid), 0])
	if sources.is_empty():
		target.identity_recovery_due_msec = 0
		_pending_identity_recoveries.erase(target_pid)
		return SnapshotQueueResult.EMPTY
	sources.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) < int(b[0]))
	target.room_sync = {"kind": "recovery", "epoch": target.room_epoch,
		"sources": sources, "index": 0, "fence": 0}
	target.identity_recovery_in_flight = true
	_pump_room_sync_page(target)
	return SnapshotQueueResult.QUEUED


func _pump_room_sync_page(target: PeerEntry) -> void:
	var task := target.room_sync
	if task.is_empty() or int(task.fence) != 0:
		return
	if int(task.epoch) != target.room_epoch:
		return # The epoch owner clears the task together with its room output.
	var available := mini(MAX_OUTBOUND_BATCHES_PER_PEER_PER_TICK - target.room_sync_produced,
		MAX_TRANSIENT_BATCHES - target.room_batches.size())
	if available <= 0 or not _seal_global_batch(target) or not _seal_room_batch(target):
		return
	available = mini(available, MAX_TRANSIENT_BATCHES - target.room_batches.size())
	if available <= 0:
		return
	var batches: Array[String] = []
	var current := ""
	var count := 0
	var index := int(task.index)
	var sources: Array = task.sources
	var state_revisions := {}
	var clear_revisions := {}
	while index < sources.size():
		var source_id := int(sources[index][0])
		var recovery: bool = task.kind == "recovery"
		if not _peers.has(source_id):
			target.identity_recovery_dirty.erase(source_id)
			index += 1
			continue
		var source := _peers[source_id] as PeerEntry
		if (source.room_id != target.room_id
				or (not recovery and source.room_epoch != int(sources[index][1]))
				or (recovery and not target.identity_recovery_dirty.has(source_id))):
			index += 1
			continue
		var record := _canonical_peer_state(source, target.system_theme_sync_capable)
		if record.is_empty():
			index += 1 # Leave an unready dirty source for a later finite pass.
			continue
		var dirty: Array = target.identity_recovery_dirty.get(source_id, [0, 0])
		if recovery and int(dirty[1]) > 0:
			record.push_front(_build("c", [str(source_id)]))
		var text := _record_text(record)
		var candidate := text if current.is_empty() else current + MSG_DELIM + text
		if (not current.is_empty() and (count + record.size() > MAX_OUTBOUND_MESSAGES_PER_FRAME
				or candidate.to_utf8_buffer().size() > MAX_OUTBOUND_BATCH_BYTES)):
			if batches.size() + 1 >= available:
				break
			batches.append(current)
			current = ""
			count = 0
			candidate = text
		current = candidate
		count += record.size()
		if recovery:
			state_revisions[source_id] = int(dirty[0])
			if int(dirty[1]) > 0:
				clear_revisions[source_id] = int(dirty[1])
		index += 1
	if not current.is_empty():
		batches.append(current)
	task.index = index
	for packet in batches:
		var batch_id := target.next_room_batch_id
		target.next_room_batch_id += 1
		target.room_batches.append([_take_output_sequence(target), batch_id, target.room_epoch, packet])
		task.fence = batch_id
		target.room_sync_produced += 1
	if batches.is_empty():
		_finish_room_sync(target)
	elif task.kind == "full":
		target.snapshot_fence_batch_id = int(task.fence)
	else:
		target.identity_recovery_fence_batch_id = int(task.fence)
		target.identity_recovery_fence_state_revisions = state_revisions
		target.identity_recovery_fence_clear_revisions = clear_revisions


func _finish_room_sync(target: PeerEntry) -> void:
	if target.room_sync.is_empty():
		return
	target.room_sync_last_kind = str(target.room_sync.kind)
	target.room_sync.clear()
	target.snapshot_fence_batch_id = 0
	target.same_room_snapshot_in_flight = false
	target.identity_recovery_in_flight = false
	if not target.identity_recovery_dirty.is_empty():
		target.identity_recovery_due_msec = Time.get_ticks_msec() + IDENTITY_RECOVERY_RETRY_MSEC
		_pending_identity_recoveries[target.id] = true


func _complete_room_sync_page(target: PeerEntry, batch_id: int) -> void:
	if target.room_sync.is_empty() or int(target.room_sync.fence) != batch_id:
		return
	if target.room_sync.kind == "recovery":
		_ack_identity_recovery(target)
	target.snapshot_fence_batch_id = 0
	if target.room_sync.is_empty():
		return
	target.room_sync.fence = 0
	if int(target.room_sync.index) >= (target.room_sync.sources as Array).size():
		_finish_room_sync(target)

func _ack_identity_recovery(target: PeerEntry) -> void:
	for source_pid_value in target.identity_recovery_fence_state_revisions.keys():
		var source_pid := int(source_pid_value)
		if not target.identity_recovery_dirty.has(source_pid):
			continue
		var dirty := target.identity_recovery_dirty[source_pid] as Array
		var sent_state_revision := int(
			target.identity_recovery_fence_state_revisions[source_pid])
		if int(dirty[0]) <= sent_state_revision:
			target.identity_recovery_dirty.erase(source_pid)
			continue
		var sent_clear_revision := int(
			target.identity_recovery_fence_clear_revisions.get(source_pid, 0))
		if sent_clear_revision > 0 and int(dirty[1]) <= sent_clear_revision:
			dirty[1] = 0
			target.identity_recovery_dirty[source_pid] = dirty
	target.identity_recovery_in_flight = not target.room_sync.is_empty()
	target.identity_recovery_fence_batch_id = 0
	target.identity_recovery_fence_state_revisions.clear()
	target.identity_recovery_fence_clear_revisions.clear()
	if not target.room_sync.is_empty():
		target.room_sync.fence = 0
		if int(target.room_sync.index) >= (target.room_sync.sources as Array).size():
			_finish_room_sync(target)
	if target.identity_recovery_dirty.is_empty():
		target.identity_recovery_due_msec = 0
		_pending_identity_recoveries.erase(target.id)
	else:
		target.identity_recovery_due_msec = Time.get_ticks_msec() + IDENTITY_RECOVERY_RETRY_MSEC
		_pending_identity_recoveries[target.id] = true


func _schedule_same_room_snapshot_retry(
		pid: int, entry: PeerEntry, now_msec: int) -> void:
	if entry.room_id < 0:
		return
	entry.same_room_resync_room_id = entry.room_id
	entry.same_room_resync_due_msec = now_msec + SAME_ROOM_RESYNC_INTERVAL_MSEC
	_pending_same_room_resyncs[pid] = true


func _handle_previous_location(pid: int, entry: PeerEntry, args: Array) -> void:
	if args.size() != 1 or not _is_bounded_int(args[0], 0, MAX_ROOM_ID):
		_warn_peer(pid, "previous_location",
			"[EasyServer] rejected invalid previous map from peer %d" % pid)
		return
	if entry.room_id < 0 and not (
			entry.privacy_mode == 1 and entry.private_room_id >= 0):
		_warn_peer(pid, "prejoin_packet",
			"[EasyServer] rejected previous map before room join from peer %d" % pid)
		return
	entry.prev_map_id = int(args[0])


func _handle_move(pid: int, entry: PeerEntry, pkt_name: String, args: Array) -> void:
	if (args.size() != 2
			or not _is_bounded_int(args[0], 0, MAX_COORDINATE)
			or not _is_bounded_int(args[1], 0, MAX_COORDINATE)):
		_warn_peer(pid, "position",
			"[EasyServer] rejected invalid position from peer %d" % pid)
		return
	var new_x := int(args[0])
	var new_y := int(args[1])
	var changed := not entry.position_seen or entry.x != new_x or entry.y != new_y
	entry.x = new_x
	entry.y = new_y
	entry.position_seen = true
	if entry.announced_room >= 0:
		if entry.protocol_mode == ProtocolMode.STRICT and pkt_name == "m":
			_commit_announced_room(pid, entry)
		return
	if entry.room_id < 0 or not changed:
		return
	_broadcast_canonical_delta(entry.room_id, _build("m", [
		str(entry.id),
		str(entry.x),
		str(entry.y),
	]), pid)

func _handle_jump(pid: int, entry: PeerEntry, args: Array) -> void:
	if (args.size() != 2
			or not _is_bounded_int(args[0], 0, MAX_COORDINATE)
			or not _is_bounded_int(args[1], 0, MAX_COORDINATE)):
		_warn_peer(pid, "jump",
			"[EasyServer] rejected invalid jump position from peer %d" % pid)
		return
	if entry.room_id < 0 and not (
			entry.privacy_mode == 1 and entry.private_room_id >= 0):
		_warn_peer(pid, "prejoin_packet",
			"[EasyServer] rejected jump before room join from peer %d" % pid)
		return
	entry.x = int(args[0])
	entry.y = int(args[1])
	entry.position_seen = true
	if entry.room_id < 0:
		return
	_broadcast_canonical_delta(entry.room_id, _build("jmp", [
		str(entry.id),
		str(entry.x),
		str(entry.y),
	]), pid)

func _handle_facing(pid: int, entry: PeerEntry, args: Array) -> void:
	if args.size() != 1 or not _is_bounded_int(args[0], 0, 3):
		_warn_peer(pid, "facing", "[EasyServer] rejected invalid facing from peer %d" % pid)
		return
	var facing := int(args[0])
	if entry.facing == facing:
		return
	entry.facing = facing
	if entry.room_id < 0:
		return
	_broadcast_canonical_delta(entry.room_id, _build("f", [str(entry.id)] + args), pid)

func _handle_speed(pid: int, entry: PeerEntry, args: Array) -> void:
	if args.size() != 1 or not _is_bounded_int(args[0], 0, 10):
		_warn_peer(pid, "speed", "[EasyServer] rejected invalid speed from peer %d" % pid)
		return
	var speed := int(args[0])
	if entry.speed == speed:
		return
	entry.speed = speed
	if entry.room_id < 0:
		return
	_broadcast_canonical_delta(entry.room_id, _build("spd", [str(entry.id)] + args), pid)

func _handle_sprite(pid: int, entry: PeerEntry, args: Array) -> void:
	if (args.size() != 2
			or not ResourceNameRules.is_safe_flat_resource_name(args[0], true)
			or not _is_bounded_int(args[1], 0, 7)):
		_warn_peer(pid, "sprite", "[EasyServer] rejected invalid sprite from peer %d" % pid)
		return
	var sprite_name := args[0] as String
	var sprite_index := int(args[1])
	if entry.sprite_name == sprite_name and entry.sprite_idx == sprite_index:
		return
	entry.sprite_name = sprite_name
	entry.sprite_idx = sprite_index
	if entry.room_id < 0:
		return
	_broadcast_canonical_delta(entry.room_id, _build("spr", [str(entry.id)] + args), pid)

func _handle_transparency(pid: int, entry: PeerEntry, args: Array) -> void:
	if args.size() != 1 or not _is_bounded_int(args[0], 0, 7):
		_warn_peer(pid, "transparency",
			"[EasyServer] rejected invalid transparency from peer %d" % pid)
		return
	var transparency := int(args[0])
	if entry.transparency == transparency:
		return
	entry.transparency = transparency
	if entry.room_id < 0:
		return
	_broadcast_canonical_delta(entry.room_id, _build("tr", [str(entry.id)] + args), pid)

func _handle_hidden(pid: int, entry: PeerEntry, args: Array) -> void:
	if args.size() != 1 or not _is_bounded_int(args[0], 0, 1):
		_warn_peer(pid, "hidden", "[EasyServer] rejected invalid hidden state from peer %d" % pid)
		return
	var hidden := int(args[0]) == 1
	if entry.hidden == hidden:
		return
	entry.hidden = hidden
	if entry.room_id < 0:
		return
	_broadcast_canonical_delta(entry.room_id, _build("h", [str(entry.id)] + args), pid)

func _handle_sys(pid: int, entry: PeerEntry, args: Array) -> void:
	if args.size() != 1 or not ResourceNameRules.is_safe_flat_resource_name(args[0], false):
		_warn_peer(pid, "system", "[EasyServer] rejected invalid system graphic from peer %d" % pid)
		return
	var sys_name := args[0] as String
	if entry.sys_name == sys_name and entry.system_stretch == 1:
		return
	entry.sys_name = sys_name
	# Legacy clients never supplied this RPG Maker flag. Preserve their historical
	# stretched-background fallback instead of leaking a value restored from an
	# earlier stretch-aware session.
	entry.system_stretch = 1
	if entry.room_id < 0:
		return
	_broadcast_system_theme(entry.room_id, entry, pid)

func _system_state_packet(target: PeerEntry, source: PeerEntry) -> String:
	if target.system_theme_sync_capable:
		return _build("sys2", [
			str(source.id), source.sys_name, str(source.system_stretch)])
	return _build("sys", [str(source.id), source.sys_name])


func _broadcast_system_theme(
		room_id: int, source: PeerEntry, exclude_pid: int = -1) -> void:
	if room_id < 0:
		return
	for target_pid in _room_member_ids(room_id):
		if target_pid == exclude_pid or not _peers.has(target_pid):
			continue
		var target := _peers[target_pid] as PeerEntry
		if not _send_to(target_pid, _system_state_packet(target, source)):
			_mark_identity_recovery(target, source.id, false)


func _handle_name_pkt(pid: int, entry: PeerEntry, args: Array) -> void:
	if args.size() != 1 or typeof(args[0]) != TYPE_STRING:
		_warn_peer(pid, "name", "[EasyServer] rejected invalid name packet from peer %d" % pid)
		return
	var display_name := InputLimits.sanitize_nickname(args[0] as String)
	if display_name.is_empty():
		_warn_peer(pid, "name",
			"[EasyServer] rejected empty canonical name from peer %d" % pid)
		return
	if entry.display_name == display_name:
		return
	entry.display_name = display_name
	if entry.room_id < 0:
		return
	for target_pid in _room_member_ids(entry.room_id):
		if target_pid == pid or not _peers.has(target_pid):
			continue
		var target := _peers[target_pid] as PeerEntry
		var record: Array = [_build("name", [str(entry.id), display_name])]
		if not entry.sys_name.is_empty():
			record.append(_system_state_packet(target, entry))
		if not _queue_room_record(target, record):
			_mark_identity_recovery(target, entry.id, false)

func _handle_chat(pid: int, entry: PeerEntry, args: Array) -> void:
	if args.size() != 1:
		_warn_peer(pid, "chat", "[EasyServer] rejected invalid chat packet from peer %d" % pid)
		_send_room_chat_rejected(pid, entry, maxi(0, entry.chat_ready_msec - Time.get_ticks_msec()))
		return
	_handle_room_chat_message(pid, entry, args[0] as String, 0)


func _handle_chat_metadata(pid: int, entry: PeerEntry, args: Array) -> void:
	if (not entry.chat_metadata_capable or args.size() != 2
			or not _is_bounded_int(args[1], 0, MAX_ROOM_ID)):
		_warn_peer(pid, "chat_metadata",
			"[EasyServer] rejected invalid metadata chat packet from peer %d" % pid)
		_send_room_chat_rejected(pid, entry, maxi(0, entry.chat_ready_msec - Time.get_ticks_msec()))
		return
	_handle_room_chat_message(pid, entry, args[0] as String, int(args[1]))


func _handle_room_chat_message(
		pid: int, entry: PeerEntry, msg: String, requested_target_pid: int, mentions: Array = []) -> void:
	if not entry.chat_enabled:
		_warn_peer(pid, "chat_disabled",
			"[EasyServer] chat attempted while disabled from PID %d" % pid)
		_send_room_chat_rejected(pid, entry, maxi(0, entry.chat_ready_msec - Time.get_ticks_msec()))
		return
	if _peer_is_muted(entry):
		_send_moderation_status(pid, entry)
		_send_room_chat_rejected(pid, entry, maxi(0, entry.chat_ready_msec - Time.get_ticks_msec()))
		return
	if msg.strip_edges().is_empty() or msg.length() > InputLimits.CHAT_MESSAGE_MAX_CHARACTERS or entry.room_id < 0 or entry.privacy_mode == 1:
		_send_room_chat_rejected(pid, entry, maxi(0, entry.chat_ready_msec - Time.get_ticks_msec()))
		return
	var now_msec := Time.get_ticks_msec()
	var remaining := maxi(0, entry.chat_ready_msec - now_msec)
	if remaining > 0:
		_send_room_chat_rejected(pid, entry, remaining)
		return
	entry.chat_ready_msec = now_msec + ROOM_CHAT_COOLDOWN_MSEC
	if entry.chat_ack_capable:
		_queue_room_chat_status(pid, "accepted", ROOM_CHAT_COOLDOWN_MSEC)
	var mention_target_pid := _validated_mention_target(
		requested_target_pid, entry.room_id)
	var resolved_mentions := _resolve_chat_mentions(msg, mentions, entry.room_id)
	var mention_fields := ChatMentions.encode(resolved_mentions)
	var snapshot_fields := ChatMentions.encode(mentions)
	var admin_flag := "0" if entry.admin_id.is_empty() else "1"
	# basically _broadcast_to_room, but skips over
	# peers that have chat disabled, and also
	# broadcasts sender's message back to the sender
	for other_pid in _room_member_ids(entry.room_id):
		if not _peers.has(other_pid):
			continue
		var cur_peer := _peers[other_pid] as PeerEntry
		if not cur_peer.chat_enabled:
			continue
		if cur_peer.chat_snapshot_capable:
			var notify: bool = (other_pid == mention_target_pid
				or ChatMentions.contains_target(resolved_mentions, _public_chat_id(cur_peer)))
			_send_to(other_pid, _build("chat5", [str(pid), entry.display_name,
				entry.sys_name, str(entry.system_stretch), _public_chat_id(entry), msg,
				snapshot_fields[0], snapshot_fields[1], admin_flag, "1" if notify else "0"]))
		elif cur_peer.chat_mentions_capable:
			_send_to(other_pid, _build("chat4", [str(pid), entry.display_name,
				entry.sys_name, str(entry.system_stretch), _public_chat_id(entry), msg,
				mention_fields[0], mention_fields[1]]))
		elif cur_peer.chat_metadata_capable:
			if cur_peer.system_theme_sync_capable:
				_send_to(other_pid, _build("chat3", [
					str(pid), entry.display_name, entry.sys_name, str(entry.system_stretch),
					str(mention_target_pid), msg]))
			else:
				_send_to(other_pid, _build("chat2", [
					str(pid), entry.display_name, entry.sys_name,
					str(mention_target_pid), msg]))
		else:
			_send_to(other_pid, _build("chat", [str(pid), msg]))


func _handle_global_chat(pid: int, entry: PeerEntry, args: Array) -> void:
	if args.size() != 1:
		_warn_peer(pid, "global_chat",
			"[EasyServer] rejected invalid global chat packet from PID %d" % pid)
		_send_global_chat_rejected(pid, entry, 0)
		return
	_handle_global_chat_message(pid, entry, args[0] as String, 0)


func _handle_global_chat_metadata(pid: int, entry: PeerEntry, args: Array) -> void:
	if (not entry.chat_metadata_capable or args.size() != 2
			or not _is_bounded_int(args[1], 0, MAX_ROOM_ID)):
		_warn_peer(pid, "global_chat_metadata",
			"[EasyServer] rejected invalid metadata global chat packet from PID %d" % pid)
		_send_global_chat_rejected(pid, entry, 0)
		return
	_handle_global_chat_message(pid, entry, args[0] as String, int(args[1]))


func _handle_global_chat_message(
		pid: int, entry: PeerEntry, msg: String, requested_target_pid: int, mentions: Array = []) -> void:
	if not entry.chat_enabled:
		_warn_peer(pid, "chat_disabled",
			"[EasyServer] global chat attempted while disabled from PID %d" % pid)
		_send_global_chat_rejected(pid, entry, 0)
		return
	if _peer_is_muted(entry):
		_send_moderation_status(pid, entry)
		_send_global_chat_rejected(pid, entry, 0)
		return
	if entry.privacy_mode == 1 or entry.room_id < 0:
		_send_global_chat_rejected(pid, entry, 0)
		return

	if msg.strip_edges().is_empty() or msg.length() > InputLimits.CHAT_MESSAGE_MAX_CHARACTERS:
		_send_global_chat_rejected(pid, entry, 0)
		return
	var now_msec := Time.get_ticks_msec()
	var remaining := maxi(0, entry.gchat_ready_msec - now_msec)
	if remaining > 0:
		_send_global_chat_rejected(pid, entry, remaining)
		return
	entry.gchat_ready_msec = now_msec + GLOBAL_CHAT_COOLDOWN_MSEC
	_schedule_global_chat_ready(pid, entry.gchat_ready_msec)
	if entry.gchat_ack_capable:
		_queue_global_chat_status(pid, "accepted", GLOBAL_CHAT_COOLDOWN_MSEC)

	var mention_target_pid := _validated_mention_target(requested_target_pid)
	var resolved_mentions := _resolve_chat_mentions(msg, mentions, -1)
	var mention_fields := ChatMentions.encode(resolved_mentions)
	var snapshot_fields := ChatMentions.encode(mentions)
	var admin_flag := "0" if entry.admin_id.is_empty() else "1"
	# Send only raw state. Every receiving client resolves language-specific
	# labels and wiki URLs through its own location catalog.
	for other_pid in _peers.keys():
		var cur_peer := _peers[other_pid] as PeerEntry
		if (cur_peer.privacy_mode == 0
				and (cur_peer.room_id >= 0 or cur_peer.announced_room >= 0)
				and cur_peer.chat_enabled):
			var packet: String
			if cur_peer.chat_snapshot_capable:
				var notify: bool = (other_pid == mention_target_pid
					or ChatMentions.contains_target(resolved_mentions, _public_chat_id(cur_peer)))
				packet = _build("gchat6", [str(pid), entry.display_name, entry.sys_name,
					str(entry.system_stretch), str(entry.room_id), str(entry.prev_map_id),
					str(entry.x), str(entry.y), _public_chat_id(entry), msg,
					snapshot_fields[0], snapshot_fields[1], admin_flag, "1" if notify else "0"])
			elif cur_peer.chat_mentions_capable:
				packet = _build("gchat5", [str(pid), entry.display_name, entry.sys_name,
					str(entry.system_stretch), str(entry.room_id), str(entry.prev_map_id),
					str(entry.x), str(entry.y), _public_chat_id(entry), msg,
					mention_fields[0], mention_fields[1]])
			elif cur_peer.chat_metadata_capable:
				if cur_peer.system_theme_sync_capable:
					packet = _build("gchat4", [
						str(pid), entry.display_name, entry.sys_name, str(entry.system_stretch),
						str(entry.room_id), str(entry.prev_map_id), str(entry.x), str(entry.y),
						str(mention_target_pid), msg])
				else:
					packet = _build("gchat3", [
						str(pid), entry.display_name, entry.sys_name,
						str(entry.room_id), str(entry.prev_map_id), str(entry.x), str(entry.y),
						str(mention_target_pid), msg])
			else:
				packet = _build("gchat2", [
					str(pid), entry.display_name, str(entry.room_id), str(entry.prev_map_id),
					str(entry.x), str(entry.y), msg])
			_send_global_event(other_pid, packet)


func _validated_mention_target(requested_pid: int, required_room_id: int = -1) -> int:
	if requested_pid <= 0 or not _peers.has(requested_pid):
		return 0
	var target := _peers[requested_pid] as PeerEntry
	if (not target.chat_enabled or target.privacy_mode != 0
			or (target.room_id < 0 and target.announced_room < 0)):
		return 0
	if required_room_id >= 0 and target.room_id != required_room_id:
		return 0
	return requested_pid


func _handle_chat_mentions(pid: int, entry: PeerEntry, args: Array, global: bool) -> void:
	if not entry.chat_mentions_capable or args.size() != 3:
		if global:
			_send_global_chat_rejected(pid, entry, 0)
		else:
			_send_room_chat_rejected(pid, entry, maxi(0, entry.chat_ready_msec - Time.get_ticks_msec()))
		return
	var body := str(args[0])
	var decoded: Variant = ChatMentions.decode(body, str(args[1]), str(args[2]))
	if decoded == null or (not entry.unnamed_chat_capable and ChatMentions.has_unnamed(body, decoded)):
		if global:
			_send_global_chat_rejected(pid, entry, 0)
		else:
			_send_room_chat_rejected(pid, entry, maxi(0, entry.chat_ready_msec - Time.get_ticks_msec()))
		return
	# Structural tags are message facts. Current reachability only decides
	# notifications (and the filtered spans used by pre-snapshot clients).
	if global:
		_handle_global_chat_message(pid, entry, body, 0, decoded)
	else:
		_handle_room_chat_message(pid, entry, body, 0, decoded)


func _resolve_chat_mentions(body: String, spans: Array, room: int) -> Array[Dictionary]:
	var accepted: Array[Dictionary] = []
	for span in spans:
		var session: ResumeSession = _public_chat_sessions.get(str(span.public_chat_id))
		if session == null:
			continue
		var target: PeerEntry = _peers.get(session.current_pid)
		if not _peer_is_fully_admitted(target):
			continue
		if _validated_mention_target(target.id, room) == 0:
			continue
		var token := ChatMentions.UNNAMED_TOKEN if target.display_name.is_empty() else "@" + target.display_name
		if body.substr(int(span.start), int(span.length)) != token:
			continue
		accepted.append(span.duplicate(true))
	return accepted


func _send_global_chat_rejected(pid: int, entry: PeerEntry, remaining_msec: int) -> void:
	if entry.gchat_ack_capable:
		_queue_global_chat_status(pid, "rejected", maxi(0, remaining_msec))


func _send_room_chat_rejected(pid: int, entry: PeerEntry, remaining_msec: int) -> void:
	if entry.chat_ack_capable:
		_queue_room_chat_status(pid, "rejected", maxi(0, remaining_msec))


func _peer_is_muted(entry: PeerEntry) -> bool:
	if entry.muted_permanent:
		return true
	if entry.muted_until_unix <= 0:
		return false
	if entry.muted_until_unix > int(Time.get_unix_time_from_system()):
		return true
	_set_peer_mute(entry, 0)
	return false

func _handle_chaton(pid: int, entry: PeerEntry, args: Array) -> void:
	if args.size() != 1 or not _is_bounded_int(args[0], 0, 1):
		_warn_peer(pid, "chat_enabled",
			"[EasyServer] rejected invalid chat-enabled state from PID %d" % pid)
		return
	Log.server_debug("[EasyServer] chaton from PID %d: %s" % [pid, args[0]])
	entry.chat_enabled = args[0] == "1" # yeah

func _handle_relay(pid: int, entry: PeerEntry, pkt_name: String, args: Array) -> void:
	if entry.room_id < 0:
		_warn_peer(pid, "prejoin_packet",
			"[EasyServer] rejected relay before room join from peer %d" % pid)
		return
	if not _validate_relay_packet(pkt_name, args):
		_warn_peer(pid, "relay_" + pkt_name,
			"[EasyServer] rejected malformed '%s' packet from peer %d" % [pkt_name, pid])
		return
	if pkt_name == "se" and not _bad_sound_names.is_empty() \
			and _bad_sound_names.has(ServerBadSounds.normalize_name(args[0])):
		# Local playback has already happened; only suppress this relay record.
		return
	if pkt_name in ["fl", "rfl"] and int(args[4]) > InputLimits.NORMAL_FLASH_FRAMES:
		_warn_peer(pid, "flash_frames_soft",
			"[EasyServer] accepted extended flash duration %s from peer %d"
				% [args[4], pid])
	if _global_variables and pkt_name == "sv" and not args.is_empty() and _is_bounded_int(args[0], 1231, 1237):
		_warn_peer(pid, "reserved_cu_variable",
			"[EasyServer] rejected write to reserved CU variable from peer %d" % pid)
		return
	_broadcast_to_room(entry.room_id, _build(pkt_name, [str(entry.id)] + args), pid)

func _canonical_peer_state(other: PeerEntry, system_theme_sync: bool = false) -> Array:
	if other.room_id < 0 or other.announced_room >= 0 or not other.position_seen:
		return []
	var record: Array = [
		_build("m", [str(other.id), str(other.x), str(other.y)]),
		_build("spr", [str(other.id), other.sprite_name, str(other.sprite_idx)]),
		_build("f", [str(other.id), str(other.facing)]),
		_build("spd", [str(other.id), str(other.speed)]),
		_build("h", [str(other.id), "1" if other.hidden else "0"]),
		_build("tr", [str(other.id), str(other.transparency)]),
	]
	if not other.display_name.is_empty():
		record.append(_build("name", [str(other.id), other.display_name]))
	if not other.sys_name.is_empty():
		if system_theme_sync:
			record.append(_build("sys2", [
				str(other.id), other.sys_name, str(other.system_stretch)]))
		else:
			record.append(_build("sys", [str(other.id), other.sys_name]))
	return record


func _send_peer_state_to(target_pid: int, other: PeerEntry) -> bool:
	if not _peers.has(target_pid):
		return false
	var target := _peers[target_pid] as PeerEntry
	var record := _canonical_peer_state(other, target.system_theme_sync_capable)
	if record.is_empty():
		return false
	return _queue_room_record(target, record)


func _broadcast_canonical_peer_state(
		room_id: int, other: PeerEntry, exclude_pid: int = -1,
		revive_visibility: bool = false) -> void:
	for target_pid in _room_member_ids(room_id):
		if target_pid == exclude_pid or not _peers.has(target_pid):
			continue
		var target := _peers[target_pid] as PeerEntry
		var record := _canonical_peer_state(other, target.system_theme_sync_capable)
		if record.is_empty():
			continue
		if revive_visibility:
			# The clear and replacement state are one indivisible room record. A
			# recipient can therefore never clear its tombstone without also getting
			# the canonical state that recreates this peer.
			record.push_front(_build("c", [str(other.id)]))
		if not _queue_room_record(target, record):
			_mark_identity_recovery(target, other.id, revive_visibility)

func _build(type: String, args: Array = []) -> String:
	var s := type
	for a in args:
		s += PARAM_DELIM + str(a)
	return s

func _send_to(pid: int, msg: String) -> bool:
	if not _peers.has(pid):
		return false
	var entry: PeerEntry = _peers[pid]
	if entry.ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return false
	if OS.is_debug_build():
		if (msg.begins_with("chat" + PARAM_DELIM)
				or msg.begins_with("gchat" + PARAM_DELIM)
				or msg.begins_with("gchat2" + PARAM_DELIM)):
			Log.server_debug("[EasyServer] TX -> peer=%d chat bytes=%d" \
					% [pid, msg.to_utf8_buffer().size()])
		else:
			Log.server_debug("[EasyServer] TX -> peer=%d '%s'" % [pid, msg.substr(0, 60)])
	return _queue_room_record(entry, [msg])


func _send_control(pid: int, key: String, msg: String) -> void:
	if not _peers.has(pid):
		return
	var entry := _peers[pid] as PeerEntry
	# One newest value per semantic control key bounds memory while retaining
	# the authoritative state needed after transient send backpressure.
	entry.pending_control[key] = msg


func _queue_global_chat_status(pid: int, status: String, remaining_msec: int) -> void:
	if not _peers.has(pid):
		return
	var entry := _peers[pid] as PeerEntry
	var packet := _build("gchat_status", [status, str(maxi(0, remaining_msec))])
	# accepted -> ready is an ordered state transition and must never be replaced.
	# Repeated identical non-accepting states carry only their newest countdown.
	if status != "accepted" and not entry.pending_gchat_status.is_empty():
		var prefix := _build("gchat_status", [status]) + PARAM_DELIM
		if (entry.pending_gchat_status[-1] as String).begins_with(prefix):
			entry.pending_gchat_status[-1] = packet
			return
	entry.pending_gchat_status.append(packet)


func _queue_room_chat_status(pid: int, status: String, remaining_msec: int) -> void:
	if not _peers.has(pid):
		return
	var entry := _peers[pid] as PeerEntry
	var packet := _build("chat_status", [status, str(maxi(0, remaining_msec))])
	# accepted -> ready is an ordered state transition and must never be replaced.
	# Repeated identical non-accepting states carry only their newest countdown.
	if status != "accepted" and not entry.pending_chat_status.is_empty():
		var prefix := _build("chat_status", [status]) + PARAM_DELIM
		if (entry.pending_chat_status[-1] as String).begins_with(prefix):
			entry.pending_chat_status[-1] = packet
			return
	entry.pending_chat_status.append(packet)


func _queue_privacy_status(
		pid: int, kind: String, state: int, request_seq: int,
		remaining_msec: int) -> void:
	if not _peers.has(pid):
		return
	var entry := _peers[pid] as PeerEntry
	var packet := _build("privacy_status", [
		kind, str(state), str(request_seq), str(maxi(0, remaining_msec))])
	# Only the newest LWW acknowledgement is generally useful. Preserve one
	# unsent accepted transition in front of a newer pending request so the
	# client can issue the private/public room barrier for the authoritative
	# state while it waits. This bounds the reliable queue to two packets.
	if kind == "accepted":
		entry.pending_privacy_status.clear()
		entry.pending_privacy_status.append([kind, packet])
		return
	if (not entry.pending_privacy_status.is_empty()
			and (entry.pending_privacy_status[-1] as Array)[0] == "pending"):
		entry.pending_privacy_status[-1] = [kind, packet]
		return
	entry.pending_privacy_status.append([kind, packet])


func _send_room_barrier(pid: int, msg: String) -> void:
	if not _peers.has(pid):
		return
	var entry := _peers[pid] as PeerEntry
	# Repeated same-room recovery requests are idempotent. Retain the original
	# sequence so already-queued post-barrier state can never overtake `ri`.
	if (not entry.pending_room_barrier.is_empty()
			and entry.pending_room_barrier_epoch == entry.room_epoch
			and entry.pending_room_barrier == msg):
		return
	# Close earlier event batches before assigning the barrier's global order.
	_seal_global_batch(entry)
	_seal_room_batch(entry)
	entry.pending_room_barrier = msg
	entry.pending_room_barrier_epoch = entry.room_epoch
	entry.pending_room_barrier_sequence = _take_output_sequence(entry)


func _send_room_state(pid: int, key: String, msg: String) -> void:
	if not _peers.has(pid):
		return
	var entry := _peers[pid] as PeerEntry
	if entry.pending_room_state.has(key):
		var current := entry.pending_room_state[key] as Array
		var requires_post_barrier_copy := (
			not entry.pending_room_barrier.is_empty()
			and entry.pending_room_barrier_epoch == entry.room_epoch
			and int(current[0]) < entry.pending_room_barrier_sequence)
		if (not requires_post_barrier_copy
				and int(current[1]) == entry.room_epoch
				and (current[2] as String) == msg):
			return
	_seal_global_batch(entry)
	_seal_room_batch(entry)
	entry.pending_room_state[key] = [
		_take_output_sequence(entry), entry.room_epoch, msg]


func _send_global_event(pid: int, msg: String) -> void:
	if not _peers.has(pid):
		return
	var entry := _peers[pid] as PeerEntry
	if entry.ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	_queue_global_record(entry, [msg])


func _record_text(messages: Array) -> String:
	var result := ""
	for msg_value in messages:
		var msg := msg_value as String
		result = msg if result.is_empty() else result + MSG_DELIM + msg
	return result


func _queue_global_record(entry: PeerEntry, messages: Array) -> bool:
	if not _seal_room_batch(entry):
		_warn_peer(entry.id, "outbound_queue",
			"[EasyServer] dropped excess global output for peer %d" % entry.id)
		return false
	return _queue_scoped_record(entry, messages, false)


func _queue_room_record(entry: PeerEntry, messages: Array) -> bool:
	if not _seal_global_batch(entry):
		_warn_peer(entry.id, "outbound_queue",
			"[EasyServer] dropped excess room output for peer %d" % entry.id)
		return false
	return _queue_scoped_record(entry, messages, true)


func _queue_scoped_record(entry: PeerEntry, messages: Array, room_scoped: bool) -> bool:
	if messages.is_empty() or messages.size() > MAX_OUTBOUND_MESSAGES_PER_FRAME:
		return false
	var record := _record_text(messages)
	var current := entry.room_batch if room_scoped else entry.global_batch
	var current_count := (
		entry.room_batch_messages if room_scoped else entry.global_batch_messages)
	var current_sequence := (
		entry.room_batch_sequence if room_scoped else entry.global_batch_sequence)
	# A barrier or coalesced state may have been queued since this partial batch
	# began. Such a batch is closed before accepting a later record of the same
	# scope, otherwise the later record could jump across that ordered item.
	if (not current.is_empty()
			and current_sequence != entry.next_output_sequence - 1):
		var closed := _seal_room_batch(entry) if room_scoped else _seal_global_batch(entry)
		if not closed:
			_warn_peer(entry.id, "outbound_queue",
				"[EasyServer] dropped excess scoped output for peer %d" % entry.id)
			return false
		current = ""
		current_count = 0
		current_sequence = 0
	var candidate := record if current.is_empty() else current + MSG_DELIM + record
	if (not current.is_empty()
			and (current_count + messages.size() > MAX_OUTBOUND_MESSAGES_PER_FRAME
				or candidate.to_utf8_buffer().size() > MAX_OUTBOUND_BATCH_BYTES)):
		var sealed := _seal_room_batch(entry) if room_scoped else _seal_global_batch(entry)
		if not sealed:
			_warn_peer(entry.id, "outbound_queue",
				"[EasyServer] dropped excess scoped output for peer %d" % entry.id)
			return false
		current = ""
		current_count = 0
		current_sequence = 0
		candidate = record
	if current.is_empty():
		current_sequence = _take_output_sequence(entry)
	if room_scoped:
		entry.room_batch = candidate
		entry.room_batch_messages = current_count + messages.size()
		entry.room_batch_sequence = current_sequence
	else:
		entry.global_batch = candidate
		entry.global_batch_messages = current_count + messages.size()
		entry.global_batch_sequence = current_sequence
	return true


func _take_output_sequence(entry: PeerEntry) -> int:
	var result := entry.next_output_sequence
	entry.next_output_sequence += 1
	return result


func _seal_global_batch(entry: PeerEntry) -> bool:
	if entry.global_batch.is_empty():
		return true
	if entry.global_batches.size() >= MAX_TRANSIENT_BATCHES:
		return false
	entry.global_batches.append([entry.global_batch_sequence, entry.global_batch])
	entry.global_batch = ""
	entry.global_batch_messages = 0
	entry.global_batch_sequence = 0
	return true


func _seal_room_batch(entry: PeerEntry) -> bool:
	if entry.room_batch.is_empty():
		return true
	if entry.room_batches.size() >= MAX_TRANSIENT_BATCHES:
		return false
	var batch_id := entry.next_room_batch_id
	entry.next_room_batch_id += 1
	entry.room_batches.append([
		entry.room_batch_sequence, batch_id, entry.room_epoch, entry.room_batch])
	entry.room_batch = ""
	entry.room_batch_messages = 0
	entry.room_batch_sequence = 0
	return true


func _clear_room_output(entry: PeerEntry) -> void:
	entry.room_sync.clear()
	entry.room_sync_last_kind = ""
	_clear_identity_recovery(entry)
	entry.committed_room_epoch = -1
	entry.pending_room_barrier = ""
	entry.pending_room_barrier_epoch = -1
	entry.pending_room_barrier_sequence = 0
	entry.pending_room_state.clear()
	entry.pending_presence = ""
	entry.pending_presence_epoch = -1
	entry.pending_presence_sequence = 0
	entry.room_batches.clear()
	entry.room_batch = ""
	entry.room_batch_messages = 0
	entry.room_batch_sequence = 0
	entry.snapshot_fence_batch_id = 0
	entry.same_room_snapshot_in_flight = false


func _flush_pending_outputs() -> void:
	var peer_ids := _peers.keys()
	if peer_ids.is_empty():
		return
	_list_peer_cursor = (_list_peer_cursor + 1) % peer_ids.size()
	for peer_index in peer_ids.size():
		var pid_value: Variant = peer_ids[(peer_index + _list_peer_cursor) % peer_ids.size()]
		var pid := int(pid_value)
		# Detaching one peer can cascade through a non-droppable departure and
		# remove another peer that is still present in this keys() snapshot.
		if not _peers.has(pid):
			continue
		var entry := _peers[pid] as PeerEntry
		if entry.ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
			continue
		_pump_list_frame(entry, Time.get_ticks_msec())
		var pending_gchat_status_count := entry.pending_gchat_status.size()
		if (pending_gchat_status_count > MAX_PENDING_GCHAT_STATUS_PACKETS
				or entry.pending_chat_status.size() > MAX_PENDING_GCHAT_STATUS_PACKETS):
			_warn_peer(pid, "chat_status_overflow",
				("[EasyServer] closing peer %d after chat status overflow "
				+ "global=%d room=%d channel_limit=%d") % [
					pid, pending_gchat_status_count, entry.pending_chat_status.size(), MAX_PENDING_GCHAT_STATUS_PACKETS])
			_close_and_detach_peer(pid, 1011, "outbound state overflow")
			continue

		var control_blocked := false
		for key in entry.pending_control.keys():
			var control_key := key as String
			var err := _send_raw(entry, entry.pending_control[control_key] as String)
			if err != OK:
				control_blocked = true
				break
			entry.pending_control.erase(control_key)
			if control_key == "resume_ok":
				entry.resume_complete = true
				entry.resume_deadline_msec = 0
		if control_blocked or not entry.pending_control.is_empty():
			continue

		while not entry.pending_gchat_status.is_empty():
			if _send_raw(entry, entry.pending_gchat_status[0] as String) != OK:
				control_blocked = true
				break
			entry.pending_gchat_status.pop_front()
		if control_blocked:
			continue
		while not entry.pending_chat_status.is_empty():
			if _send_raw(entry, entry.pending_chat_status[0] as String) != OK:
				control_blocked = true
				break
			entry.pending_chat_status.pop_front()
		if control_blocked:
			continue
		while not entry.pending_privacy_status.is_empty():
			var privacy_status := entry.pending_privacy_status[0] as Array
			if _send_raw(entry, privacy_status[1] as String) != OK:
				control_blocked = true
				break
			entry.pending_privacy_status.pop_front()
		if control_blocked:
			continue
		entry.room_sync_produced = 0
		var batches_sent := 0
		while true:
			# A partial batch already owns its sequence. Re-attempt sealing after
			# every successful send so a temporarily full queue cannot reorder it.
			_seal_global_batch(entry)
			_seal_room_batch(entry)
			_pump_list_frame(entry, Time.get_ticks_msec())
			_pump_room_sync_page(entry)
			var candidate := _next_ordered_output(entry)
			var kind := int(candidate[0])
			if kind == OrderedOutputKind.NONE:
				break
			if (kind in [OrderedOutputKind.GLOBAL_BATCH, OrderedOutputKind.ROOM_BATCH, OrderedOutputKind.LIST_FRAME]
					and batches_sent >= MAX_OUTBOUND_BATCHES_PER_PEER_PER_TICK):
				break

			var packet := ""
			var candidate_key: Variant = candidate[1]
			match kind:
				OrderedOutputKind.ROOM_BARRIER:
					packet = entry.pending_room_barrier
				OrderedOutputKind.GLOBAL_BATCH:
					packet = (entry.global_batches[0] as Array)[1] as String
				OrderedOutputKind.ROOM_STATE:
					packet = (entry.pending_room_state[candidate_key] as Array)[2] as String
				OrderedOutputKind.PRESENCE:
					packet = entry.pending_presence
				OrderedOutputKind.ROOM_BATCH:
					packet = (entry.room_batches[0] as Array)[3] as String
			var send_error := (entry.ws.send(entry.list_frame, WebSocketPeer.WRITE_MODE_BINARY)
				if kind == OrderedOutputKind.LIST_FRAME else _send_raw(entry, packet))
			if send_error != OK:
				if kind in [OrderedOutputKind.GLOBAL_BATCH, OrderedOutputKind.ROOM_BATCH, OrderedOutputKind.LIST_FRAME]:
					_warn_peer(pid, "outbound_backpressure",
						"[EasyServer] deferred ordered output for slow peer %d" % pid)
				break

			match kind:
				OrderedOutputKind.LIST_FRAME:
					_complete_list_frame(entry)
					batches_sent += 1
				OrderedOutputKind.ROOM_BARRIER:
					entry.pending_room_barrier = ""
					entry.pending_room_barrier_epoch = -1
					entry.pending_room_barrier_sequence = 0
					entry.committed_room_epoch = entry.room_epoch
				OrderedOutputKind.GLOBAL_BATCH:
					entry.global_batches.pop_front()
					batches_sent += 1
				OrderedOutputKind.ROOM_STATE:
					entry.pending_room_state.erase(candidate_key)
				OrderedOutputKind.PRESENCE:
					entry.pending_presence = ""
					entry.pending_presence_epoch = -1
					entry.pending_presence_sequence = 0
				OrderedOutputKind.ROOM_BATCH:
					var sent_batch := entry.room_batches.pop_front() as Array
					batches_sent += 1
					_complete_room_sync_page(entry, int(sent_batch[1]))


func _next_ordered_output(entry: PeerEntry) -> Array:
	if (not entry.pending_room_barrier.is_empty()
			and entry.pending_room_barrier_epoch != entry.room_epoch):
		entry.pending_room_barrier = ""
		entry.pending_room_barrier_epoch = -1
		entry.pending_room_barrier_sequence = 0
	for key in entry.pending_room_state.keys():
		var state := entry.pending_room_state[key] as Array
		if int(state[1]) != entry.room_epoch:
			entry.pending_room_state.erase(key)
	if (not entry.pending_presence.is_empty()
			and entry.pending_presence_epoch != entry.room_epoch):
		entry.pending_presence = ""
		entry.pending_presence_epoch = -1
		entry.pending_presence_sequence = 0
	while (not entry.room_batches.is_empty()
			and int((entry.room_batches[0] as Array)[2]) != entry.room_epoch):
		var stale_batch := entry.room_batches.pop_front() as Array
		if int(stale_batch[1]) == entry.snapshot_fence_batch_id:
			entry.snapshot_fence_batch_id = 0
			entry.same_room_snapshot_in_flight = false
		if int(stale_batch[1]) == entry.identity_recovery_fence_batch_id:
			_clear_identity_recovery(entry)

	var best_kind := OrderedOutputKind.NONE
	var best_sequence := -1
	var best_key: Variant = null
	if not entry.pending_room_barrier.is_empty():
		best_kind = OrderedOutputKind.ROOM_BARRIER
		best_sequence = entry.pending_room_barrier_sequence
	if not entry.global_batches.is_empty():
		var global_sequence := int((entry.global_batches[0] as Array)[0])
		if best_sequence < 0 or global_sequence < best_sequence:
			best_kind = OrderedOutputKind.GLOBAL_BATCH
			best_sequence = global_sequence
	if not entry.list_frame.is_empty() and (best_sequence < 0 or entry.list_frame_sequence < best_sequence):
		best_kind = OrderedOutputKind.LIST_FRAME
		best_sequence = entry.list_frame_sequence
	if entry.committed_room_epoch == entry.room_epoch:
		for key in entry.pending_room_state.keys():
			var state_sequence := int((entry.pending_room_state[key] as Array)[0])
			if best_sequence < 0 or state_sequence < best_sequence:
				best_kind = OrderedOutputKind.ROOM_STATE
				best_sequence = state_sequence
				best_key = key
		if not entry.pending_presence.is_empty():
			if best_sequence < 0 or entry.pending_presence_sequence < best_sequence:
				best_kind = OrderedOutputKind.PRESENCE
				best_sequence = entry.pending_presence_sequence
				best_key = null
		if not entry.room_batches.is_empty():
			var room_sequence := int((entry.room_batches[0] as Array)[0])
			if best_sequence < 0 or room_sequence < best_sequence:
				best_kind = OrderedOutputKind.ROOM_BATCH
				best_sequence = room_sequence
				best_key = null
	return [best_kind, best_key]


func _send_raw(entry: PeerEntry, msg: String) -> Error:
	return entry.ws.send(msg.to_utf8_buffer(), WebSocketPeer.WRITE_MODE_BINARY)

func _broadcast_to_room(room_id: int, msg: String, exclude_pid: int = -1) -> void:
	if room_id < 0:
		return
	for pid in _room_member_ids(room_id):
		if pid == exclude_pid:
			continue
		if _peers.has(pid):
			_send_to(pid, msg)


func _broadcast_canonical_delta(room_id: int, msg: String, source_pid: int) -> void:
	for target_pid in _room_member_ids(room_id):
		if target_pid == source_pid or not _peers.has(target_pid):
			continue
		if not _send_to(target_pid, msg):
			_mark_identity_recovery(_peers[target_pid] as PeerEntry, source_pid, false)


func _broadcast_room_record(
		room_id: int, messages: Array, exclude_pid: int = -1) -> void:
	if room_id < 0 or messages.is_empty():
		return
	for pid in _room_member_ids(room_id):
		if pid == exclude_pid or not _peers.has(pid):
			continue
		_queue_room_record(_peers[pid] as PeerEntry, messages)


func _broadcast_departure(room_id: int, departing_pid: int, exclude_pid: int) -> void:
	# `d` shares the recipient's ordered room stream with canonical snapshots and
	# state. A previously queued state record can therefore never arrive after
	# this departure and recreate the removed PID. If a slow recipient cannot
	# queue this non-droppable record, close that transport: its reconnect path
	# performs an immediate client clear and receives a fresh room snapshot.
	var messages := [_build("d", [str(departing_pid)])]
	for pid_value in _room_member_ids(room_id):
		var pid := int(pid_value)
		if pid == exclude_pid or not _peers.has(pid):
			continue
		var recipient := _peers[pid] as PeerEntry
		if recipient.detaching:
			continue
		_discard_identity_recovery_source(recipient, departing_pid)
		if not _queue_room_record(recipient, messages):
			_warn_peer(pid, "departure_overflow",
				"[EasyServer] closing peer %d after non-droppable departure overflow" % pid)
			_close_and_detach_peer(pid, 1011, "outbound state overflow")


func _broadcast_global_event(msg: String) -> void:
	for pid in _peers.keys():
		var entry := _peers[pid] as PeerEntry
		if (entry.room_id >= 0
				or entry.announced_room >= 0
				or entry.private_room_id >= 0):
			_send_global_event(int(pid), msg)


func _on_cu_minute_tick(raw_time: int, new_randint: int) -> void:
	var msg := _build("cut", [str(raw_time), str(new_randint)])
	_broadcast_global_event(msg)


func _on_cu_weather_tick(new_temperature: int, new_precipitation: int) -> void:
	var msg := _build("cuw", [str(new_temperature), str(new_precipitation)])
	_broadcast_global_event(msg)


func _on_cu_holiday_changed(holiday: int) -> void:
	var msg := _build("ssv", ["1237", str(holiday)])
	_broadcast_global_event(msg)


func _send_cu_snapshot(pid: int, room_id: int, private_snapshot: bool = false) -> void:
	if not _global_variables:
		return
	_send_global_event(pid, _build("cut", [
		str(_global_variables.current_raw_time()),
		str(_global_variables.randint),
	]))
	_send_global_event(pid, _build("cuw", [
		str(_global_variables.temperature),
		str(_global_variables.precipitation),
	]))
	_send_global_event(pid, _build(
		"ssv", ["1237", str(_global_variables.current_holiday())]))
	_send_room_state(pid, "ssv:1232", _build(
		"ssv", ["1232", "1" if private_snapshot else str(_room_player_count(room_id))]))


func _broadcast_cu_player_count(room_id: int) -> void:
	if not _global_variables or room_id < 0:
		return
	var msg := _build("ssv", ["1232", str(_room_player_count(room_id))])
	for pid in _room_member_ids(room_id):
		_send_room_state(int(pid), "ssv:1232", msg)


func _room_player_count(room_id: int) -> int:
	if not _room_members.has(room_id):
		return 0
	return (_room_members[room_id] as Dictionary).size()


func _room_member_ids(room_id: int) -> Array:
	if not _room_members.has(room_id):
		return []
	return (_room_members[room_id] as Dictionary).keys()


func _set_peer_room(entry: PeerEntry, new_room: int) -> void:
	var old_room := entry.room_id
	if old_room == new_room:
		return
	var was_joined := old_room >= 0
	var will_be_joined := new_room >= 0
	if was_joined and _room_members.has(old_room):
		var old_members := _room_members[old_room] as Dictionary
		old_members.erase(entry.id)
		_joined_player_count = maxi(0, _joined_player_count - 1)
		if old_members.is_empty():
			_room_members.erase(old_room)
	if will_be_joined:
		if not _room_members.has(new_room):
			_room_members[new_room] = {}
		var new_members := _room_members[new_room] as Dictionary
		new_members[entry.id] = true
		_joined_player_count += 1
	entry.room_id = new_room
	_advance_presence_revision()
	if was_joined != will_be_joined:
		_presence_global_dirty = true
	else:
		if old_room >= 0:
			_presence_dirty_rooms[old_room] = true
		if new_room >= 0:
			_presence_dirty_rooms[new_room] = true


func _queue_presence(pid: int) -> void:
	if not _peers.has(pid):
		return
	var entry := _peers[pid] as PeerEntry
	if not entry.presence_capable or entry.room_id < 0:
		return
	var packet := _build("presence", [
		str(_presence_revision),
		str(_joined_player_count),
		str(entry.room_id),
		str(_room_player_count(entry.room_id)),
	])
	var requires_post_barrier_copy := (
		not entry.pending_room_barrier.is_empty()
		and entry.pending_room_barrier_epoch == entry.room_epoch
		and entry.pending_presence_sequence < entry.pending_room_barrier_sequence)
	if (not requires_post_barrier_copy
			and entry.pending_presence_epoch == entry.room_epoch
			and entry.pending_presence == packet):
		return
	_seal_global_batch(entry)
	_seal_room_batch(entry)
	entry.pending_presence = packet
	entry.pending_presence_epoch = entry.room_epoch
	entry.pending_presence_sequence = _take_output_sequence(entry)


func _flush_presence_updates(now_msec: int) -> void:
	var periodic := now_msec >= _next_presence_refresh_msec
	if periodic:
		_next_presence_refresh_msec = now_msec + PRESENCE_REFRESH_MSEC
	if periodic or _presence_global_dirty:
		for pid in _peers.keys():
			_queue_presence(int(pid))
	elif not _presence_dirty_rooms.is_empty():
		for room_id in _presence_dirty_rooms.keys():
			for pid in _room_member_ids(int(room_id)):
				_queue_presence(int(pid))
	_presence_global_dirty = false
	_presence_dirty_rooms.clear()


func _schedule_global_chat_ready(pid: int, deadline_msec: int) -> void:
	var node := [deadline_msec, pid]
	_gchat_ready_heap.append(node)
	var child := _gchat_ready_heap.size() - 1
	while child > 0:
		var parent := int((child - 1) / 2)
		if int((_gchat_ready_heap[parent] as Array)[0]) <= deadline_msec:
			break
		var swap: Variant = _gchat_ready_heap[parent]
		_gchat_ready_heap[parent] = _gchat_ready_heap[child]
		_gchat_ready_heap[child] = swap
		child = parent


func _pop_global_chat_deadline() -> Array:
	var root := _gchat_ready_heap[0] as Array
	var last: Variant = _gchat_ready_heap.pop_back()
	if _gchat_ready_heap.is_empty():
		return root
	_gchat_ready_heap[0] = last
	var parent := 0
	while true:
		var left := parent * 2 + 1
		if left >= _gchat_ready_heap.size():
			break
		var right := left + 1
		var smallest := left
		if (right < _gchat_ready_heap.size()
				and int((_gchat_ready_heap[right] as Array)[0])
				< int((_gchat_ready_heap[left] as Array)[0])):
			smallest = right
		if (int((_gchat_ready_heap[parent] as Array)[0])
				<= int((_gchat_ready_heap[smallest] as Array)[0])):
			break
		var swap: Variant = _gchat_ready_heap[parent]
		_gchat_ready_heap[parent] = _gchat_ready_heap[smallest]
		_gchat_ready_heap[smallest] = swap
		parent = smallest
	return root


func _process_due_global_chat_ready(now_msec: int) -> void:
	while (not _gchat_ready_heap.is_empty()
			and int((_gchat_ready_heap[0] as Array)[0]) <= now_msec):
		var deadline := _pop_global_chat_deadline()
		var deadline_msec := int(deadline[0])
		var pid := int(deadline[1])
		if not _peers.has(pid):
			continue
		var entry := _peers[pid] as PeerEntry
		if entry.gchat_ready_msec != deadline_msec:
			continue
		entry.gchat_ready_msec = 0
		if entry.gchat_ack_capable:
			_queue_global_chat_status(pid, "ready", 0)


func _process_room_chat_ready(entry: PeerEntry, now_msec: int) -> void:
	if entry.chat_ready_msec <= 0 or now_msec < entry.chat_ready_msec:
		return
	entry.chat_ready_msec = 0
	if entry.chat_ack_capable:
		_queue_room_chat_status(entry.id, "ready", 0)


func _process_due_privacy_updates(now_msec: int) -> void:
	for pid_value in _pending_privacy_updates.keys():
		var pid := int(pid_value)
		if not _peers.has(pid):
			_pending_privacy_updates.erase(pid)
			continue
		var entry := _peers[pid] as PeerEntry
		if not entry.privacy_pending:
			_pending_privacy_updates.erase(pid)
			continue
		if now_msec < entry.privacy_cooldown_until_msec:
			continue
		entry.privacy_pending = false
		_pending_privacy_updates.erase(pid)
		if entry.privacy_requested != entry.privacy_mode:
			_apply_privacy_mode(
				pid, entry, entry.privacy_requested, now_msec)
		else:
			_sync_privacy_to_resume_session(entry)
		_queue_privacy_status(pid, "accepted", entry.privacy_mode,
			entry.privacy_request_seq,
			maxi(0, entry.privacy_cooldown_until_msec - now_msec))


func _process_due_same_room_resyncs(now_msec: int) -> void:
	for pid_value in _pending_same_room_resyncs.keys():
		var pid := int(pid_value)
		if not _peers.has(pid):
			_pending_same_room_resyncs.erase(pid)
			continue
		var entry := _peers[pid] as PeerEntry
		if (entry.room_id < 0
				or entry.room_id != entry.same_room_resync_room_id):
			_pending_same_room_resyncs.erase(pid)
			entry.same_room_resync_due_msec = 0
			continue
		if (now_msec < entry.same_room_resync_due_msec
				or entry.same_room_snapshot_in_flight):
			continue
		_pending_same_room_resyncs.erase(pid)
		entry.same_room_resync_due_msec = 0
		entry.last_same_room_resync_msec = now_msec
		var snapshot_result := _queue_room_snapshot_to(pid, entry.room_id)
		entry.same_room_snapshot_in_flight = (
			snapshot_result == SnapshotQueueResult.QUEUED)
		if snapshot_result == SnapshotQueueResult.DEFERRED:
			_schedule_same_room_snapshot_retry(pid, entry, now_msec)


func _process_due_identity_recoveries(now_msec: int) -> void:
	for pid_value in _pending_identity_recoveries.keys():
		var pid := int(pid_value)
		if not _peers.has(pid):
			_pending_identity_recoveries.erase(pid)
			continue
		var entry := _peers[pid] as PeerEntry
		if entry.room_id < 0:
			_clear_identity_recovery(entry)
			continue
		if (entry.identity_recovery_in_flight
				or now_msec < entry.identity_recovery_due_msec):
			continue
		var recovery_result := _queue_identity_recovery_to(pid)
		if recovery_result == SnapshotQueueResult.DEFERRED:
			entry.identity_recovery_due_msec = (
				now_msec + IDENTITY_RECOVERY_RETRY_MSEC)


func execute_console_command(line: String) -> String:
	var tokens := Array(line.strip_edges().split(" ", false))
	if tokens.is_empty():
		return ""
	var command := str(tokens[0]).to_lower()
	match command:
		"help", "?":
			return "Commands: help, status, players, admin list|add|rotate|revoke|reload, mute, unmute, ban, bans, unban, announce, stop, restart"
		"status":
			return ("running=%s peers=%d/%d connections=%d/%d queries=%d pending_admissions=%d/%d joined=%d "
				+ "admins=%d punishments=%d next_pid=%d presence_revision=%d "
				+ "moderation_revision=%d protocol_limit=%s protocol_limit_reason=%s "
				+ "auth_subjects=%d/%d auth_capacity_rejects=%d "
				+ "auth_rate_replies_suppressed=%d") % [
				str(_running), _peers.size(), max_connections,
				_connection_count(), max_connections, _status_service.connection_count(),
				_pending_admission_count(), max_pending_admissions, _joined_player_count,
				_admin_store.list_records().size() if _admin_store != null else 0,
				_punishment_store.list_active().size() if _punishment_store != null else 0,
				_next_id, _presence_revision, _moderation_revision,
				str(_protocol_limit_reached),
				_protocol_limit_reason if not _protocol_limit_reason.is_empty() else "-",
				_auth_failures_by_subject.size(), MAX_AUTH_FAILURE_SUBJECTS,
				_auth_failure_capacity_rejects, _auth_rate_limit_replies_suppressed]
		"players":
			return _console_players()
		"admin":
			return _console_admin_command(tokens)
		"mute", "unmute", "ban":
			return _console_player_action(command, tokens)
		"bans":
			return _console_bans()
		"unban":
			if tokens.size() != 2 or _punishment_store == null:
				return "Usage: unban B-000001|M-000001"
			var unban_result := _punishment_store.revoke(str(tokens[1]), "console")
			if not bool(unban_result.get("ok", false)):
				return "ERROR: %s" % str(unban_result.get("error", "unban failed"))
			_advance_moderation_revision()
			_refresh_all_peer_punishments()
			_append_audit("console", "owner", "unban", 0, str(tokens[1]), 0, "", "ok")
			return "Unbanned %s" % str(tokens[1])
		"announce":
			var announcement := _join_tokens(tokens, 1).strip_edges()
			if announcement.is_empty() or announcement.length() > 100:
				return "Usage: announce <1-100 characters>"
			_broadcast_global_event(_build("server_notice", ["announcement", announcement]))
			_append_audit("console", "owner", "announce", 0, "", 0, announcement, "ok")
			return "Announcement sent"
		"stop", "restart":
			return _console_schedule_shutdown(command == "restart", tokens)
		_:
			return "Unknown command. Type 'help'."


func _console_players() -> String:
	if _peers.is_empty():
		return "No connected players"
	var lines: Array[String] = []
	var ids := _peers.keys()
	ids.sort()
	var now := int(Time.get_unix_time_from_system())
	for pid_value in ids:
		var entry := _peers[pid_value] as PeerEntry
		if not _peer_is_fully_admitted(entry):
			continue
		lines.append("#%d name=%s room=%s muted_until=%d banned_until=%d admin=%s network=%s" % [
			entry.id,
			entry.display_name if not entry.display_name.is_empty() else "<unnamed>",
			"private" if entry.privacy_mode == 1 else str(entry.room_id),
			entry.muted_until_unix if entry.muted_until_unix > now else 0,
			entry.banned_until_unix if entry.banned_until_unix > now else 0,
			entry.admin_id if not entry.admin_id.is_empty() else "-",
			_network_label_for_entry(entry),
		])
	return "No connected players" if lines.is_empty() else "\n".join(lines)


func _console_admin_command(tokens: Array) -> String:
	if _admin_store == null:
		return "Administrator store is disabled"
	if tokens.size() < 2:
		return "Usage: admin list|add|rotate|revoke|reload [id]"
	var operation := str(tokens[1]).to_lower()
	if operation == "list":
		var lines: Array[String] = []
		for record in _admin_store.list_records():
			var admin_id := str(record.get("id", ""))
			lines.append("%s enabled=%s online=%s" % [
				admin_id, str(record.get("enabled", false)), str(_admin_is_online(admin_id))])
		return "No administrators" if lines.is_empty() else "\n".join(lines)
	if operation == "reload":
		var replacement: AdminStore = AdminStoreScript.new()
		if not replacement.load_or_create(admins_file):
			return "ERROR: %s" % replacement.last_error
		_admin_store = replacement
		_revalidate_online_admins()
		return "Administrator file reloaded"
	if tokens.size() != 3:
		return "Usage: admin %s <id>" % operation
	var result: Dictionary
	match operation:
		"add": result = _admin_store.add(str(tokens[2]))
		"rotate": result = _admin_store.rotate(str(tokens[2]))
		"revoke": result = _admin_store.revoke(str(tokens[2]))
		_: return "Unknown admin operation"
	if not bool(result.get("ok", false)):
		return "ERROR: %s" % str(result.get("error", "operation failed"))
	var admin_id := str(result.get("admin_id", ""))
	if operation in ["rotate", "revoke"]:
		_revoke_online_admin(admin_id)
	_append_audit("console", "owner", "admin_" + operation, 0, admin_id, 0, "", "ok")
	if result.has("credential"):
		return "%s succeeded. Administrator password (credential_digest, shown once): %s" % [operation.capitalize(), result["credential"]]
	return "%s succeeded for %s" % [operation.capitalize(), admin_id]


func _admin_is_online(admin_id: String) -> bool:
	for entry_value in _peers.values():
		if (entry_value as PeerEntry).admin_id == admin_id:
			return true
	return false


func _revoke_online_admin(admin_id: String) -> void:
	for entry_value in _peers.values():
		var entry := entry_value as PeerEntry
		if entry.admin_id == admin_id:
			_cancel_server_list_queries(entry)
			entry.admin_id = ""
			_send_admin_packet(entry.id, _build("adm_fail", ["credential_revoked"]))


func _revalidate_online_admins() -> void:
	for entry_value in _peers.values():
		var entry := entry_value as PeerEntry
		if not entry.admin_id.is_empty() and not _admin_store.has_enabled(entry.admin_id):
			_cancel_server_list_queries(entry)
			entry.admin_id = ""
			_send_admin_packet(entry.id, _build("adm_fail", ["credential_revoked"]))


func _console_player_action(action: String, tokens: Array) -> String:
	var expected_tokens := 2 if action == "unmute" else 3
	if tokens.size() != expected_tokens:
		return "Usage: %s #PID%s" % [action,
			"" if action == "unmute" else " <duration>"]
	var target_text := str(tokens[1]).trim_prefix("#")
	if not _is_bounded_int(target_text, 1, MAX_ROOM_ID) or not _peers.has(int(target_text)):
		return "ERROR: target is not online"
	var target := _peers[int(target_text)] as PeerEntry
	if not _peer_is_fully_admitted(target):
		return "ERROR: target is not online"
	var duration := 0
	if action in ["mute", "ban"]:
		duration = _parse_duration(str(tokens[2]))
		var maximum := MAX_MUTE_DURATION_SECONDS if action == "mute" else MAX_MODERATION_DURATION_SECONDS
		if duration < 60 or duration > maximum:
			return "ERROR: duration must be 1m..%s" % ("7d" if action == "mute" else "30d")
	if _punishment_store == null:
		return "ERROR: punishment store is disabled"
	match action:
		"mute":
			var result := _punishment_store.add_subject_mute(
				target.punishment_address, target.installation_identity,
				target.display_name, duration, "console")
			if not bool(result.get("ok", false)):
				return "ERROR: %s" % str(result.get("error", "mute failed"))
		"unmute":
			var result := _punishment_store.revoke_active_for_subjects(
				target.punishment_address, target.installation_identity,
				PunishmentStoreScript.KIND_MUTE, "console")
			if not bool(result.get("ok", false)):
				return "ERROR: %s" % str(result.get("error", "unmute failed"))
		"ban":
			var result := _punishment_store.add_subject_ban(
				target.punishment_address, target.installation_identity,
				target.display_name, duration, "console")
			if not bool(result.get("ok", false)):
				return "ERROR: %s" % str(result.get("error", "ban failed"))
	_refresh_all_peer_punishments()
	_advance_moderation_revision()
	_append_audit("console", "owner", action, target.id, target.display_name, duration, "", "ok")
	return "%s succeeded for #%d %s" % [action.capitalize(), target.id, target.display_name]


func _console_bans() -> String:
	if _punishment_store == null:
		return "Punishment store is disabled"
	var lines: Array[String] = []
	for ban in _punishment_store.list_active():
		lines.append("%s kind=%s name=%s scope=%s duration=%s network=%s expires=%d actor=%s" % [
			ban.get("id", ""), ban.get("kind", PunishmentStoreScript.KIND_BAN),
			ban.get("last_name", ""), ban.get("scope", "installation"),
			ban.get("duration_mode", "finite"), ban.get("network_label", ""),
			ban.get("expires_at", 0), ban.get("actor", "")])
	return "No active punishments" if lines.is_empty() else "\n".join(lines)


func _network_label_for_entry(entry: PeerEntry) -> String:
	if (_punishment_store == null
			or not PunishmentStoreScript.address_is_usable(entry.punishment_address)):
		return "unavailable"
	return _punishment_store.network_label_for_address(entry.punishment_address)


func _console_schedule_shutdown(restart: bool, tokens: Array) -> String:
	var delay_seconds := 0
	var message_index := 1
	if tokens.size() >= 2:
		var parsed := _parse_duration(str(tokens[1]), true)
		if parsed >= 0:
			delay_seconds = parsed
			message_index = 2
	var message := _join_tokens(tokens, message_index).strip_edges()
	if message.is_empty():
		message = "Server restart" if restart else "Server shutdown"
	if message.length() > 100:
		return "ERROR: message must be at most 100 characters"
	_shutdown_restart = restart
	_shutdown_message = message
	_shutdown_deadline_msec = Time.get_ticks_msec() + delay_seconds * 1000
	_next_shutdown_notice_second = -1
	_shutdown_origin = "console"
	_broadcast_global_event(_build("server_notice", [
		"restart" if restart else "shutdown",
		"%s in %d seconds" % [message, delay_seconds],
	]))
	return "%s scheduled in %d seconds" % ["Restart" if restart else "Shutdown", delay_seconds]


func _schedule_protocol_limit_shutdown() -> void:
	if not _protocol_limit_reached or _protocol_limit_shutdown_scheduled:
		return
	_protocol_limit_shutdown_scheduled = true
	var now_msec := maxi(1, Time.get_ticks_msec())
	var has_existing_shutdown := _shutdown_deadline_msec > 0
	var should_restart := _shutdown_restart if has_existing_shutdown \
		else exit_process_on_protocol_limit
	var action := "restart" if should_restart else "shutdown"
	_broadcast_global_event(_build("server_notice", [
		action,
		"Server protocol capacity reached; %s is required" % action,
	]))
	if has_existing_shutdown:
		_shutdown_deadline_msec = mini(_shutdown_deadline_msec, now_msec)
		_next_shutdown_notice_second = -1
		return
	_shutdown_restart = exit_process_on_protocol_limit
	_shutdown_message = "Protocol counter capacity reached: %s" % _protocol_limit_reason
	_shutdown_deadline_msec = now_msec
	_next_shutdown_notice_second = -1
	_shutdown_origin = "protocol_limit"


func _process_scheduled_shutdown() -> void:
	if _shutdown_deadline_msec <= 0:
		return
	var remaining_msec := maxi(0, _shutdown_deadline_msec - Time.get_ticks_msec())
	var remaining_seconds := int(ceil(float(remaining_msec) / 1000.0))
	if (remaining_seconds != _next_shutdown_notice_second
			and remaining_seconds in [300, 60, 30, 10, 5, 4, 3, 2, 1]):
		_next_shutdown_notice_second = remaining_seconds
		_broadcast_global_event(_build("server_notice", [
			"restart" if _shutdown_restart else "shutdown",
			"%s in %d seconds" % [_shutdown_message, remaining_seconds],
		]))
	if remaining_msec > 0:
		return
	var should_restart := _shutdown_restart
	var final_message := _shutdown_message
	var protocol_limit_shutdown := _shutdown_origin == "protocol_limit"
	_append_audit("server" if protocol_limit_shutdown else "console",
		"system" if protocol_limit_shutdown else "owner",
		"restart" if should_restart else "stop",
		0, "", 0, final_message, "ok")
	var should_exit_process := not protocol_limit_shutdown or exit_process_on_protocol_limit
	stop()
	if should_exit_process:
		get_tree().quit(RESTART_EXIT_CODE if should_restart else 0)


func _parse_duration(value: String, allow_zero: bool = false) -> int:
	var text := value.strip_edges().to_lower()
	if allow_zero and text == "0":
		return 0
	if text.length() < 2:
		return -1
	var suffix := text.right(1)
	var number_text := text.left(text.length() - 1)
	if not number_text.is_valid_int():
		return -1
	var multiplier := int({"s": 1, "m": 60, "h": 3600, "d": 86400}.get(suffix, 0))
	if multiplier == 0:
		return -1
	return int(number_text) * multiplier


func _join_tokens(tokens: Array, start_index: int) -> String:
	if start_index >= tokens.size():
		return ""
	var parts: Array[String] = []
	for index in range(start_index, tokens.size()):
		parts.append(str(tokens[index]))
	return " ".join(parts)


func _append_audit(
		source: String, actor: String, action: String, target_pid: int,
		target_name: String, duration: int, message: String, result: String) -> void:
	if audit_file.is_empty():
		return
	var absolute_path := ProjectSettings.globalize_path(audit_file)
	var directory := absolute_path.get_base_dir()
	if not directory.is_empty() and DirAccess.make_dir_recursive_absolute(directory) != OK:
		Log.server_error("[EasyServer] could not create audit directory")
		return
	var exists := FileAccess.file_exists(audit_file)
	var file := FileAccess.open(audit_file, FileAccess.READ_WRITE if exists else FileAccess.WRITE)
	if file == null:
		Log.server_error("[EasyServer] could not open audit file")
		return
	if exists:
		file.seek_end()
	var record := {
		"time_utc": int(Time.get_unix_time_from_system()),
		"source": source,
		"actor": actor,
		"action": action,
		"target_pid": target_pid,
		"target_name": target_name,
		"duration_seconds": duration,
		"result": result,
	}
	if not message.is_empty():
		record["message"] = message
	file.store_line(JSON.stringify(record))
	file.flush()


func _validate_relay_packet(pkt_name: String, args: Array) -> bool:
	match pkt_name:
		"fl", "rfl":
			return (args.size() == 5
				and _is_bounded_int(args[0], 0, 255)
				and _is_bounded_int(args[1], 0, 255)
				and _is_bounded_int(args[2], 0, 255)
				and _is_bounded_int(args[3], 0, MAX_COORDINATE)
				and _is_bounded_int(
					args[4], 0, InputLimits.HARD_FLASH_FRAMES))
		"rrfl":
			return args.is_empty()
		"se":
			return (args.size() == 4
				and ResourceNameRules.is_safe_resource_path(args[0], false)
				and _is_bounded_int(args[1], 0, 100)
				and _is_bounded_int(args[2], 10, 400)
				and _is_bounded_int(args[3], 0, 100))
		"ba":
			return args.size() == 1 and _is_bounded_int(args[0], 0, MAX_COORDINATE)
		"ap", "mp":
			return _validate_picture_packet(pkt_name, args)
		"rp":
			return args.size() == 1 and _is_bounded_int(args[0], 1, 1000)
		"ss":
			return (args.size() == 2
				and _is_bounded_int(args[0], 1, MAX_COORDINATE)
				and _is_bounded_int(args[1], 0, 1))
		"sv":
			return (args.size() == 2
				and _is_bounded_int(args[0], 1, MAX_COORDINATE)
				and _is_bounded_int(args[1], MIN_SIGNED_INT, MAX_COORDINATE))
		"sev":
			return (args.size() == 2
				and _is_bounded_int(args[0], 1, MAX_COORDINATE)
				and _is_bounded_int(args[1], 0, 1))
	return false


func _peer_uses_strict_room_barrier(entry: PeerEntry) -> bool:
	return (entry.protocol_mode == ProtocolMode.STRICT
		or (entry.protocol_mode == ProtocolMode.UNKNOWN
			and entry.room_barrier_capable))


func _validate_picture_packet(pkt_name: String, args: Array) -> bool:
	var is_show := pkt_name == "ap"
	if args.size() != (31 if is_show else 17):
		return false
	if not _is_bounded_int(args[0], 1, 1000):
		return false
	for index in range(1, 7):
		if not _is_bounded_int(args[index], MIN_SIGNED_INT, MAX_COORDINATE):
			return false
	for index in range(7, 10):
		if not _is_bounded_int(args[index], 0, MAX_COORDINATE):
			return false
	for index in range(10, 14):
		if not _is_bounded_int(args[index], 0, 200):
			return false
	if (not _is_bounded_int(args[14], 0, MAX_COORDINATE)
			or not _is_bounded_int(args[15], MIN_SIGNED_INT, MAX_COORDINATE)):
		return false
	if not is_show:
		return _is_bounded_int(args[16], 0, MAX_COORDINATE)
	if not ResourceNameRules.is_safe_resource_path(args[16], false):
		return false
	for index in range(17, 31):
		if not _is_bounded_int(args[index], MIN_SIGNED_INT, MAX_COORDINATE):
			return false
	return true


func _require_joined(pid: int, entry: PeerEntry) -> bool:
	if entry.room_id >= 0:
		return true
	_warn_peer(pid, "prejoin_packet",
		"[EasyServer] rejected packet before room join from peer %d" % pid)
	return false


func _warn_peer(pid: int, category: String, message: String, now_msec: int = -1) -> void:
	if now_msec < 0:
		now_msec = Time.get_ticks_msec()
	if not _peers.has(pid):
		Log.server_warn(message)
		return
	var entry := _peers[pid] as PeerEntry
	var last_msec := int(entry.warning_times.get(category, -WARNING_INTERVAL_MSEC))
	if now_msec - last_msec < WARNING_INTERVAL_MSEC:
		return
	entry.warning_times[category] = now_msec
	Log.server_warn(message)


func _is_valid_resume_token(token: String) -> bool:
	if token.length() != 64:
		return false
	for index in range(token.length()):
		var code := token.unicode_at(index)
		if not ((code >= 48 and code <= 57)
				or (code >= 65 and code <= 70)
				or (code >= 97 and code <= 102)):
			return false
	return true


func _is_bounded_int(value: Variant, minimum: int, maximum: int) -> bool:
	if typeof(value) != TYPE_STRING:
		return false
	var text := value as String
	if text.length() > 32 or not text.is_valid_int():
		return false
	var parsed := int(text)
	return parsed >= minimum and parsed <= maximum
