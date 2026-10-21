extends RefCounted

const Protocol := preload("res://cogs/multiplayer/server_status_protocol.gd")
const PunishmentStoreScript := preload("res://cogs/multiplayer/punishment_store.gd")

const MAX_CONNECTIONS := 32
const MAX_SOURCES := 2048
const SOURCE_IDLE_MSEC := 60000
const SOURCE_CLEANUP_MSEC := 10000
const STATUS_RATE := 20.0
const STATUS_BURST := 40.0
const AUTH_RATE := 10.0
const AUTH_BURST := 20.0
const SOURCE_RATE := 1.0
const SOURCE_BURST := 5.0

enum Phase { STATUS, AUTH, COMPLETE }

class Query:
	var ws: WebSocketPeer
	var address: String = ""
	var source: String = ""
	var deadline_msec: int = 0
	var phase: int = Phase.STATUS
	var request_id: String = ""
	var nonce: String = ""


class SourceBudget:
	var status_tokens: float = SOURCE_BURST
	var auth_tokens: float = SOURCE_BURST
	var updated_msec: int = 0
	var last_seen_msec: int = 0


var _queries: Array[Query] = []
var _sources: Dictionary = {}
var _authenticator: Callable
var _status_tokens: float = STATUS_BURST
var _auth_tokens: float = AUTH_BURST
var _updated_msec: int = 0
var _next_cleanup_msec: int = 0


func configure(authenticator: Callable) -> void:
	reset()
	_authenticator = authenticator
	_updated_msec = Time.get_ticks_msec()
	_next_cleanup_msec = _updated_msec + SOURCE_CLEANUP_MSEC


func reset() -> void:
	for query in _queries:
		query.ws.close(-1)
	_queries.clear()
	_sources.clear()
	_authenticator = Callable()
	_status_tokens = STATUS_BURST
	_auth_tokens = AUTH_BURST
	_updated_msec = 0
	_next_cleanup_msec = 0


func connection_count() -> int:
	# Includes completed replies and closing transports until they are actually
	# closed or the absolute query deadline forces their transport to close.
	return _queries.size()


func accept_query(
		ws: WebSocketPeer, address: String, accepted_msec: int, now_msec: int) -> bool:
	if (_queries.size() >= MAX_CONNECTIONS
			or now_msec - accepted_msec >= Protocol.TIMEOUT_MSEC):
		return false
	var source := _source_key(address)
	if not _take_budget(source, false, now_msec):
		return false
	var query := Query.new()
	query.ws = ws
	query.address = address if PunishmentStoreScript.address_is_usable(address) else ""
	query.source = source
	query.deadline_msec = accepted_msec + Protocol.TIMEOUT_MSEC
	_queries.append(query)
	return true


func poll(now_msec: int, online_count: int) -> void:
	_cleanup_sources(now_msec)
	for index in range(_queries.size() - 1, -1, -1):
		var query := _queries[index]
		if now_msec >= query.deadline_msec:
			query.ws.close(-1)
			_queries.remove_at(index)
			continue
		query.ws.poll()
		if query.ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			_queries.remove_at(index)
			continue
		if (query.ws.get_ready_state() != WebSocketPeer.STATE_OPEN
				or query.ws.get_available_packet_count() == 0):
			continue
		# At most one application packet per connection per tick, with at most
		# two accepted packets over its entire lifetime. Native WebSocket control
		# frames are handled by Godot's poll(), before this application budget.
		var raw := query.ws.get_packet()
		var packet: Dictionary = Protocol.decode_packet(raw)
		if (not query.ws.was_string_packet() or packet.is_empty()
				or not _handle_packet(query, packet, now_msec, online_count)):
			query.ws.close(-1)
			_queries.remove_at(index)


func _handle_packet(query: Query, packet: Dictionary, now_msec: int, online_count: int) -> bool:
	if query.phase == Phase.STATUS:
		if (not Protocol.has_keys(packet, ["op", "id", "want_auth"])
				or packet.get("op") != "status"
				or not Protocol.is_hex(packet.get("id"), 32)
				or typeof(packet.get("want_auth")) != TYPE_BOOL):
			return false
		query.request_id = packet["id"]
		if bool(packet["want_auth"]):
			query.nonce = Crypto.new().generate_random_bytes(32).hex_encode()
			if not Protocol.is_hex(query.nonce, 64):
				return false
			query.phase = Phase.AUTH
		else:
			query.phase = Phase.COMPLETE
		return _send(query, {
			"op": "status", "id": query.request_id,
			"online": online_count, "nonce": query.nonce,
		})
	if query.phase == Phase.AUTH:
		if (not Protocol.has_keys(packet, ["op", "id", "proof"])
				or packet.get("op") != "auth"
				or packet.get("id") != query.request_id
				or not Protocol.is_hex(packet.get("proof"), 64)):
			return false
		query.phase = Phase.COMPLETE
		var authenticated := false
		if _take_budget(query.source, true, now_msec) and _authenticator.is_valid():
			authenticated = bool(_authenticator.call(
				query.address, query.request_id, query.nonce, packet["proof"], now_msec))
		query.nonce = ""
		return _send(query, {
			"op": "auth", "id": query.request_id, "authenticated": authenticated,
		})
	return false


func _send(query: Query, packet: Dictionary) -> bool:
	# Do not immediately send a close frame with the final data frame. Godot
	# exposes queued application packets only while OPEN. The client closes
	# after consuming the result; the absolute deadline covers silent clients.
	return query.ws.send_text(JSON.stringify(packet)) == OK


func _source_key(address: String) -> String:
	if PunishmentStoreScript.address_is_usable(address):
		return "network:" + PunishmentStoreScript.normalize_address(address)
	# No installation identity exists on a query connection. Unknown-address
	# deployments share a work budget instead of getting a fresh one per socket.
	return "unknown"


func _take_budget(source: String, authentication: bool, now_msec: int) -> bool:
	var elapsed := maxf(0.0, float(now_msec - _updated_msec) / 1000.0)
	_status_tokens = minf(STATUS_BURST, _status_tokens + elapsed * STATUS_RATE)
	_auth_tokens = minf(AUTH_BURST, _auth_tokens + elapsed * AUTH_RATE)
	_updated_msec = now_msec
	if (authentication and _auth_tokens < 1.0) or (not authentication and _status_tokens < 1.0):
		return false
	var budget: SourceBudget = _sources.get(source)
	if budget == null:
		_cleanup_sources(now_msec)
		if _sources.size() >= MAX_SOURCES:
			return false
		budget = SourceBudget.new()
		budget.updated_msec = now_msec
		_sources[source] = budget
	var source_elapsed := maxf(0.0, float(now_msec - budget.updated_msec) / 1000.0)
	budget.status_tokens = minf(SOURCE_BURST, budget.status_tokens + source_elapsed * SOURCE_RATE)
	budget.auth_tokens = minf(SOURCE_BURST, budget.auth_tokens + source_elapsed * SOURCE_RATE)
	budget.updated_msec = now_msec
	budget.last_seen_msec = now_msec
	if authentication:
		if budget.auth_tokens < 1.0:
			return false
		budget.auth_tokens -= 1.0
		_auth_tokens -= 1.0
	else:
		if budget.status_tokens < 1.0:
			return false
		budget.status_tokens -= 1.0
		_status_tokens -= 1.0
	return true


func _cleanup_sources(now_msec: int) -> void:
	if now_msec < _next_cleanup_msec:
		return
	_next_cleanup_msec = now_msec + SOURCE_CLEANUP_MSEC
	for source in _sources.keys():
		var budget := _sources[source] as SourceBudget
		if now_msec - budget.last_seen_msec >= SOURCE_IDLE_MSEC:
			_sources.erase(source)
