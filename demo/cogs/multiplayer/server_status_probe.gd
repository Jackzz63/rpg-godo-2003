class_name ServerStatusProbe
extends Node

const Protocol := preload("res://cogs/multiplayer/server_status_protocol.gd")

signal updated()

var state: String = "idle"
var ping_msec: int = -1
var online_count: int = -1
var authenticated: bool = false

var _ws: WebSocketPeer = null
var _phase: String = "idle"
var _credential: String = ""
var _request_id: String = ""
var _deadline_msec: int = 0
var _next_refresh_msec: int = 0
var _sent_usec: int = 0


func refresh(endpoint: String, credential: String) -> bool:
	if not can_refresh():
		return false
	var url := EasyMultiplayer.build_room_url(endpoint, 0)
	var now := Time.get_ticks_msec()
	_next_refresh_msec = now + Protocol.COOLDOWN_MSEC
	_deadline_msec = now + Protocol.TIMEOUT_MSEC
	_reset_result("pending")
	if url.is_empty() or credential.length() > 160:
		_finish()
		return true
	_credential = credential
	_request_id = Crypto.new().generate_random_bytes(16).hex_encode()
	_ws = WebSocketPeer.new()
	_ws.supported_protocols = PackedStringArray([Protocol.SUBPROTOCOL])
	_ws.inbound_buffer_size = 4096
	_ws.outbound_buffer_size = 4096
	_ws.max_queued_packets = 4
	_phase = "connecting"
	if _ws.connect_to_url(url) != OK:
		_finish()
	return true


func invalidate() -> void:
	_release_socket()
	_reset_result("idle")


func cooldown_remaining_msec() -> int:
	return maxi(0, _next_refresh_msec - Time.get_ticks_msec())


func can_refresh() -> bool:
	return _ws == null and cooldown_remaining_msec() == 0


func _exit_tree() -> void:
	_release_socket()


func _process(_delta: float) -> void:
	if _ws == null:
		return
	# One deadline covers DNS, transport setup, status and optional authentication.
	if Time.get_ticks_msec() >= _deadline_msec:
		if _phase != "closing":
			_finish()
		_release_socket()
		return
	_ws.poll()
	var ready_state := _ws.get_ready_state()
	if ready_state == WebSocketPeer.STATE_CLOSED:
		if _phase != "closing":
			_finish()
		_release_socket()
		return
	if _phase == "closing" or ready_state != WebSocketPeer.STATE_OPEN:
		return
	if _phase == "connecting":
		if _ws.get_selected_protocol() != Protocol.SUBPROTOCOL:
			_finish()
			return
		var error := _ws.send_text(JSON.stringify({
			"op": "status", "id": _request_id, "want_auth": not _credential.is_empty(),
		}))
		if error != OK:
			_finish()
			return
		_sent_usec = Time.get_ticks_usec()
		_phase = "status"
	# At most one status and one authentication result can belong to this request.
	var packets_read := 0
	while _ws != null and _phase != "closing" and _ws.get_available_packet_count() > 0:
		packets_read += 1
		if packets_read > 2:
			_finish()
			return
		var raw := _ws.get_packet()
		if _ws.get_packet_error() != OK or not _ws.was_string_packet():
			_finish()
			return
		_handle_packet(Protocol.decode_packet(raw))


func _handle_packet(packet: Dictionary) -> void:
	if packet.get("id") != _request_id:
		_finish()
		return
	if _phase == "status":
		if (not Protocol.has_keys(packet, ["op", "id", "online", "nonce"])
				or packet.get("op") != "status" or not Protocol.is_count(packet.get("online"))
				or typeof(packet.get("nonce")) != TYPE_STRING):
			_finish()
			return
		var nonce := packet["nonce"] as String
		if not nonce.is_empty() and not Protocol.is_hex(nonce, Protocol.NONCE_LENGTH):
			_finish()
			return
		ping_msec = maxi(0, roundi(float(Time.get_ticks_usec() - _sent_usec) / 1000.0))
		online_count = int(packet["online"])
		if _credential.is_empty() or nonce.is_empty():
			_finish()
			return
		var proof := Protocol.make_proof(_credential, _request_id, nonce)
		_credential = ""
		if proof.is_empty() or _ws.send_text(JSON.stringify({
			"op": "auth", "id": _request_id, "proof": proof,
		})) != OK:
			_finish()
			return
		_phase = "auth"
		updated.emit()
	elif _phase == "auth":
		if (not Protocol.has_keys(packet, ["op", "id", "authenticated"])
				or packet.get("op") != "auth"
				or typeof(packet.get("authenticated")) != TYPE_BOOL):
			_finish()
			return
		authenticated = packet["authenticated"] as bool
		_finish()
	else:
		_finish()


func _finish() -> void:
	_credential = ""
	_phase = "closing"
	state = "ready" if ping_msec >= 0 else "unreachable"
	# Read the final result before initiating the close handshake. Keep polling it.
	if _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.close(1000)
	updated.emit()


func _release_socket() -> void:
	if _ws != null:
		_ws.close(-1)
		_ws = null
	_phase = "idle"
	_credential = ""
	_request_id = ""


func _reset_result(next_state: String) -> void:
	state = next_state
	ping_msec = -1
	online_count = -1
	authenticated = false
	updated.emit()
