class_name EasyConnection
extends RefCounted

const PARAM_DELIM := "\uFFFF" # separates fields within one message
const MSG_DELIM := "\uFFFE" # separates multiple messages in one ws frame
const MAX_QUEUE_SIZE := 4088
const MAX_INBOUND_FRAME_BYTES := 64 * 1024
const MAX_MESSAGES_PER_FRAME := 1024
const MAX_OUTBOUND_MESSAGES_PER_FRAME := 128
const MAX_MESSAGE_CHARACTERS := 4096
const MAX_ARGUMENTS := 32
const MAX_ARGUMENT_CHARACTERS := 1024
const MAX_INBOUND_FRAMES_PER_POLL := 64
const MAX_INBOUND_MESSAGES_PER_POLL := 4096
const MAX_INBOUND_BYTES_PER_POLL := 4 * 1024 * 1024
const PROTOCOL_WARNING_INTERVAL_MSEC := 5000
const TRANSPORT_STALL_MSEC := 10_000
const MSG_DELIM_UTF8_BYTES := 3

enum OutboundScope {
	CONNECTION,
	GLOBAL,
	BARRIER,
	ROOM,
}

class OutboundItem:
	var message: String
	var scope: int

	func _init(message_value: String, scope_value: int) -> void:
		message = message_value
		scope = scope_value

signal connected(socket_epoch: int)
signal disconnected(code: int, socket_epoch: int)
signal disconnected_with_reason(code: int, reason: String, socket_epoch: int)
signal packet_received(name: String, args: Array, socket_epoch: int)
signal transport_stalled(socket_epoch: int)

var _ws: WebSocketPeer = null
var _is_open: bool = false
var _queue: Array = []
var _url: String = ""
var _socket_epoch: int = 0
var _pending_inbound_messages: Array[PackedStringArray] = []
var _perf_pending_since_usec := 0
var _perf_last_poll_usec := 0
var _protocol_warning_times: Dictionary = {}
var _protocol_warning_suppressed: Dictionary = {}
var _send_failure_started_msec: int = -1
var _transport_stalled_emitted: bool = false

func open(uri: String) -> Error:
	if _ws != null:
		close()
	_reset_send_failure_state()
	_url = uri
	_socket_epoch += 1
	_ws = WebSocketPeer.new()
	_ws.supported_protocols = PackedStringArray(["binary"])
	Log.info("[EasyConnection] connecting to %s" % uri)
	var err := _ws.connect_to_url(uri)
	if err != OK:
		Log.error("[EasyConnection] connect_to_url failed (%s): %s" % [uri, error_string(err)])
		_ws = null
		return err
	_is_open = false
	return OK

func close() -> void:
	Log.debug("[EasyConnection] closing")
	_perf_pending_since_usec = 0
	_perf_last_poll_usec = 0
	_queue.clear()
	_pending_inbound_messages.clear()
	_reset_send_failure_state()
	_is_open = false
	if _ws != null:
		_ws.close()
		_ws = null
		_socket_epoch += 1

func get_socket_epoch() -> int:
	return _socket_epoch

func is_connected_to_server() -> bool:
	return _is_open

func poll() -> void:
	if ClientPerformance.enabled:
		var now := Time.get_ticks_usec()
		if _perf_last_poll_usec > 0:
			ClientPerformance.gauge(&"net.poll_gap_us", now - _perf_last_poll_usec)
		if _perf_pending_since_usec > 0:
			ClientPerformance.gauge(&"net.pending_age_us", now - _perf_pending_since_usec)
		_perf_last_poll_usec = now
	var perf_start := ClientPerformance.begin()
	poll_measured()
	ClientPerformance.end(&"net.poll_inclusive", perf_start)
	if ClientPerformance.enabled:
		ClientPerformance.gauge(&"net.pending_messages", _pending_inbound_messages.size())
		ClientPerformance.gauge(&"net.pending_age_us", Time.get_ticks_usec() - _perf_pending_since_usec if _perf_pending_since_usec > 0 else 0)
		if _pending_inbound_messages.is_empty():
			_perf_pending_since_usec = 0
		ClientPerformance.gauge(&"net.buffered_packets", _ws.get_available_packet_count() if _ws != null else 0)


func poll_measured() -> void:
	if _ws == null:
		return
	var perf_ws := ClientPerformance.begin()
	_ws.poll()
	ClientPerformance.end(&"net.websocket_poll", perf_ws)
	match _ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not _is_open:
				_is_open = true
				Log.info("[EasyConnection] OPEN %s" % _url)
				connected.emit(_socket_epoch)
			_receive_budgeted(_socket_epoch)
		WebSocketPeer.STATE_CLOSED:
			var code := _ws.get_close_code()
			ClientPerformance.count_event(&"net.disconnects")
			if ClientPerformance.enabled:
				ClientPerformance.mark("connection_closed_code=" + str(code))
			var reason := _ws.get_close_reason()
			Log.info("[EasyConnection] CLOSED code=%d reason='%s'" % [code, reason])
			_is_open = false
			_ws = null
			_pending_inbound_messages.clear()
			disconnected.emit(code, _socket_epoch)
			disconnected_with_reason.emit(code, reason, _socket_epoch)
		_:
			pass

func send_packet(name: String, args: Array = []) -> void:
	var packet_type := _strip_protocol_delimiters(name)
	var message := _build_message(packet_type, args)
	_queue.append(OutboundItem.new(message, _scope_for_packet(packet_type)))

func clear_queue() -> Array[String]:
	var discarded := _discarded_chats(_queue)
	_queue.clear()
	_reset_send_failure_state()
	return discarded

func clear_room_queue() -> Array[String]:
	# Room data and a not-yet-sent room barrier become stale together when the
	# client selects another room. Connection and global messages keep their
	# relative positions and survive the room transition.
	var discarded: Array = []
	for index in range(_queue.size() - 1, -1, -1):
		var item: OutboundItem = _queue[index] as OutboundItem
		if item.scope == OutboundScope.ROOM or item.scope == OutboundScope.BARRIER:
			discarded.append(item)
			_queue.remove_at(index)
	if _queue.is_empty():
		_reset_send_failure_state()
	return _discarded_chats(discarded)


func clear_room_payload_queue() -> Array[String]:
	# A privacy request is itself a barrier but is independent of the selected
	# room. Preserve it while discarding only stale room payload queued behind it.
	var discarded: Array = []
	for index in range(_queue.size() - 1, -1, -1):
		var item: OutboundItem = _queue[index] as OutboundItem
		if item.scope == OutboundScope.ROOM:
			discarded.append(item)
			_queue.remove_at(index)
	if _queue.is_empty():
		_reset_send_failure_state()
	return _discarded_chats(discarded)


func _discarded_chats(items: Array) -> Array[String]:
	var channels: Array[String] = []
	for item: OutboundItem in items:
		var packet_type := item.message.get_slice(PARAM_DELIM, 0)
		if packet_type in ["chat", "chatm", "chatx"] and not channels.has("room"):
			channels.append("room")
		elif packet_type in ["gchat", "gchatm", "gchatx"] and not channels.has("global"):
			channels.append("global")
	return channels

func flush_queue() -> void:
	if not _is_open or _ws == null:
		return
	if _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return

	# Preserve enqueue order. A room switch is a protocol barrier and must be sent
	# alone. Frames are removed only after WebSocketPeer accepts them, so temporary
	# backpressure cannot reorder or silently discard protocol state.
	while not _queue.is_empty():
		var first: OutboundItem = _queue[0] as OutboundItem
		var frame := first.message
		var frame_bytes := frame.to_utf8_buffer().size()
		var item_count := 1

		# A legal single message larger than the preferred batching threshold is
		# still sent by itself. Only additional messages are constrained by 4088
		# UTF-8 bytes and the 128-message outbound frame limit.
		if first.scope != OutboundScope.BARRIER and frame_bytes <= MAX_QUEUE_SIZE:
			while (item_count < _queue.size()
					and item_count < MAX_OUTBOUND_MESSAGES_PER_FRAME):
				var next_item: OutboundItem = _queue[item_count] as OutboundItem
				if next_item.scope == OutboundScope.BARRIER:
					break
				var next_bytes := next_item.message.to_utf8_buffer().size()
				if frame_bytes + MSG_DELIM_UTF8_BYTES + next_bytes > MAX_QUEUE_SIZE:
					break
				frame += MSG_DELIM + next_item.message
				frame_bytes += MSG_DELIM_UTF8_BYTES + next_bytes
				item_count += 1

		var send_error := _send_raw(frame)
		if send_error != OK:
			_record_send_failure()
			return
		_reset_send_failure_state()
		for _index in range(item_count):
			_queue.pop_front()

func _build_message(name: String, args: Array) -> String:
	var s := _strip_protocol_delimiters(name)
	for a in args:
		s += PARAM_DELIM + _strip_protocol_delimiters(str(a))
	return s

func _strip_protocol_delimiters(value: String) -> String:
	return value.replace(PARAM_DELIM, "").replace(MSG_DELIM, "")

func _send_raw(data: String) -> Error:
	if _ws == null or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return ERR_UNAVAILABLE
	var data_bytes := data.to_utf8_buffer()
	if OS.is_debug_build():
		Log.debug("[EasyConnection] TX bytes=%d" % data_bytes.size())
	return _ws.send(data_bytes, WebSocketPeer.WRITE_MODE_BINARY)

func _scope_for_packet(packet_type: String) -> int:
	match packet_type:
		"cap", "install_identity", "resume", "chaton", "adm_auth", "adm_logout", "adm_roster", \
				"adm_bans", "adm_act", "plist": return OutboundScope.CONNECTION
		"gchat", "gchatm", "gchatx": return OutboundScope.GLOBAL
		"sr", "privacy": return OutboundScope.BARRIER
		_: return OutboundScope.ROOM

func _record_send_failure() -> void:
	var now_msec := Time.get_ticks_msec()
	if _send_failure_started_msec < 0:
		_send_failure_started_msec = now_msec
		return
	if (not _transport_stalled_emitted
			and now_msec - _send_failure_started_msec >= TRANSPORT_STALL_MSEC):
		_transport_stalled_emitted = true
		transport_stalled.emit(_socket_epoch)

func _reset_send_failure_state() -> void:
	_send_failure_started_msec = -1
	_transport_stalled_emitted = false

func _receive_budgeted(active_epoch: int) -> void:
	var messages_left := MAX_INBOUND_MESSAGES_PER_POLL
	while messages_left > 0 and not _pending_inbound_messages.is_empty():
		var pending: PackedStringArray = _pending_inbound_messages.pop_front()
		_dispatch_message(pending, active_epoch)
		if active_epoch != _socket_epoch:
			return
		messages_left -= 1

	if _pending_inbound_messages.is_empty():
		_perf_pending_since_usec = 0
	var frames_read := 0
	var bytes_read := 0
	while (messages_left > 0 and active_epoch == _socket_epoch and _ws != null
			and _ws.get_available_packet_count() > 0
			and frames_read < MAX_INBOUND_FRAMES_PER_POLL
			and bytes_read < MAX_INBOUND_BYTES_PER_POLL):
		var raw := _ws.get_packet()
		frames_read += 1
		bytes_read += raw.size()
		if OS.is_debug_build():
			Log.debug("[EasyConnection] RX bytes=%d" % raw.size())
		ClientPerformance.count_event(&"net.frames")
		ClientPerformance.count_event(&"net.bytes", raw.size())
		var perf_parse := ClientPerformance.begin()
		var messages := _parse_frame(raw)
		ClientPerformance.end(&"net.parse", perf_parse)
		for msg in messages:
			if messages_left <= 0:
				if ClientPerformance.enabled and _perf_pending_since_usec == 0:
					_perf_pending_since_usec = Time.get_ticks_usec()
				_pending_inbound_messages.append(msg)
				continue
			_dispatch_message(msg, active_epoch)
			if active_epoch != _socket_epoch:
				return
			messages_left -= 1

func _parse_frame(raw: PackedByteArray) -> Array[PackedStringArray]:
	var result: Array[PackedStringArray] = []
	if raw.is_empty() or raw.size() > MAX_INBOUND_FRAME_BYTES:
		_warn_protocol("frame_size", "rejected S2C frame with %d bytes" % raw.size())
		return result
	# The protocol is text even on binary WebSocket frames; NUL is not a
	# delimiter. Reject before decoding, without touching queued messages.
	var has_nul: bool = raw.has(0)
	var text := "" if has_nul else raw.get_string_from_utf8()
	if has_nul or text.to_utf8_buffer() != raw:
		_warn_protocol("utf8", "rejected S2C frame with invalid UTF-8")
		return result
	# Limit splitting itself so a delimiter flood cannot allocate an unbounded
	# temporary array before the structural message-count check runs.
	var messages := text.split(MSG_DELIM, true, MAX_MESSAGES_PER_FRAME)
	if messages.size() > MAX_MESSAGES_PER_FRAME:
		_warn_protocol("message_count", "rejected S2C frame with %d messages" % messages.size())
		return result
	for raw_message in messages:
		var msg := raw_message as String
		if msg.is_empty() or msg.length() > MAX_MESSAGE_CHARACTERS:
			_warn_protocol("message_size", "rejected malformed S2C message")
			return []
		var fields := msg.split(PARAM_DELIM, true)
		if fields[0].is_empty() or fields.size() - 1 > MAX_ARGUMENTS:
			_warn_protocol("argument_count", "rejected S2C message with invalid field count")
			return []
		for field_index in range(1, fields.size()):
			if (fields[field_index] as String).length() > MAX_ARGUMENT_CHARACTERS:
				_warn_protocol("argument_size", "rejected S2C message with oversized field")
				return []
		result.append(fields)
	return result

func _dispatch_message(fields: PackedStringArray, active_epoch: int) -> void:
	ClientPerformance.count_event(&"net.messages")
	var perf_start := ClientPerformance.begin()
	_dispatch_message_measured(fields, active_epoch)
	ClientPerformance.end(&"net.dispatch_inclusive", perf_start)


func _dispatch_message_measured(fields: PackedStringArray, active_epoch: int) -> void:
	var name := fields[0]
	if fields.size() == 1:
		if OS.is_debug_build():
			Log.debug("[EasyConnection] S2C '%s'" % name)
		packet_received.emit(name, [], active_epoch)
	else:
		if ClientPerformance.enabled:
			match name:
				"m": ClientPerformance.count_event(&"net.moves")
				"chat", "chat2", "chat3", "chat4", "chat5", "gchat", "gchat2", "gchat3", "gchat4", "gchat5", "gchat6": ClientPerformance.count_event(&"net.chats")
				"plist_item": ClientPerformance.count_event(&"net.player_list_records")
				"plist_end": ClientPerformance.count_event(&"net.player_list_responses")
		var args := Array(fields.slice(1))
		# Resume/admin values are bearer credentials, and the installation value is
		# a stable server-scoped pseudonym. Keep all of them out of debug logs.
		if OS.is_debug_build():
			if name in ["install_identity", "resume", "resume_ok", "adm_auth"]:
				Log.debug("[EasyConnection] S2C '%s' args=[<redacted>, %s]" \
					% [name, str(args[1]) if args.size() > 1 else "<missing>"])
			else:
				Log.debug("[EasyConnection] S2C '%s' args=%s" % [name, str(args)])
		packet_received.emit(name, args, active_epoch)

func _warn_protocol(category: String, message: String) -> void:
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
		Log.warn("[EasyConnection] %s (%d similar warnings suppressed)" % [message, suppressed])
	else:
		Log.warn("[EasyConnection] %s" % message)
