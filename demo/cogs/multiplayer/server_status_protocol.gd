class_name ServerStatusProtocol
extends RefCounted

const SUBPROTOCOL := "launcher-status1"
const TIMEOUT_MSEC := 5000
const COOLDOWN_MSEC := 2000
const MAX_PACKET_BYTES := 1024
const REQUEST_ID_LENGTH := 32
const NONCE_LENGTH := 64
const PROOF_LENGTH := 64
const _AUTH_PURPOSE := "rpg-godo/launcher-status1/admin\n"


static func decode_packet(raw: PackedByteArray) -> Dictionary:
	if raw.is_empty() or raw.size() > MAX_PACKET_BYTES or raw.has(0):
		return {}
	var text := raw.get_string_from_utf8()
	if text.to_utf8_buffer() != raw:
		return {}
	var parser := JSON.new()
	if parser.parse(text) != OK or typeof(parser.data) != TYPE_DICTIONARY:
		return {}
	return parser.data as Dictionary


static func has_keys(packet: Dictionary, keys: Array) -> bool:
	if packet.size() != keys.size():
		return false
	for key in keys:
		if not packet.has(key):
			return false
	return true


static func is_hex(value: Variant, length: int) -> bool:
	if typeof(value) != TYPE_STRING or (value as String).length() != length:
		return false
	for character in value:
		if character not in "0123456789abcdef":
			return false
	return true


static func is_count(value: Variant) -> bool:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return false
	var number := float(value)
	return is_finite(number) and number >= 0.0 and number <= 2147483647.0 \
		and floor(number) == number


static func make_proof(credential: String, request_id: String, nonce: String) -> String:
	if (credential.is_empty() or credential.length() > 160
			or not is_hex(request_id, REQUEST_ID_LENGTH)
			or not is_hex(nonce, NONCE_LENGTH)):
		return ""
	var message := (_AUTH_PURPOSE + request_id + "\n" + nonce).to_utf8_buffer()
	return Crypto.new().hmac_digest(
		HashingContext.HASH_SHA256, credential.to_utf8_buffer(), message).hex_encode()
