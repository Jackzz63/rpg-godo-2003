class_name ClientIdentityStore
extends RefCounted

const FORMAT_VERSION := 1
const SECRET_BYTES := 32
const DEFAULT_PATH := "user://multiplayer-client-identity.json"

var path: String = DEFAULT_PATH
var last_error: String = ""
var _instance_secret: PackedByteArray = PackedByteArray()


func load_or_create(file_path: String = DEFAULT_PATH) -> bool:
	path = file_path.strip_edges()
	last_error = ""
	_instance_secret = PackedByteArray()
	if path.is_empty():
		last_error = "client identity path is empty"
		return false
	if FileAccess.file_exists(path):
		return _load_existing()

	var generated := Crypto.new().generate_random_bytes(SECRET_BYTES)
	if generated.size() != SECRET_BYTES:
		last_error = "could not generate client identity secret"
		return false
	if not _write_new_atomic(generated):
		return false
	if not _load_existing():
		return false
	if _instance_secret != generated:
		last_error = "client identity verification mismatch"
		_instance_secret = PackedByteArray()
		return false
	return true


func get_instance_secret() -> PackedByteArray:
	return _instance_secret.duplicate()


func derive_installation_identity(server_namespace: String) -> String:
	return derive_installation_identity_from_secret(_instance_secret, server_namespace)


static func derive_installation_identity_from_secret(
	secret: PackedByteArray,
	server_namespace: String
) -> String:
	var normalized_namespace := server_namespace.strip_edges()
	if secret.size() != SECRET_BYTES or not _is_lower_hex_64(normalized_namespace):
		return ""
	return Crypto.new().hmac_digest(
		HashingContext.HASH_SHA256,
		secret,
		normalized_namespace.hex_decode()).hex_encode()


func _load_existing() -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		last_error = "cannot open client identity file: %s" \
			% error_string(FileAccess.get_open_error())
		return false
	var contents := file.get_as_text()
	file = null
	var parsed: Variant = JSON.parse_string(contents)
	if typeof(parsed) != TYPE_DICTIONARY:
		last_error = "client identity file is not a JSON object"
		return false
	var document := parsed as Dictionary
	if int(document.get("version", 0)) != FORMAT_VERSION:
		last_error = "unsupported client identity file version"
		return false
	var secret_hex_value: Variant = document.get("instance_secret", "")
	if typeof(secret_hex_value) != TYPE_STRING:
		last_error = "invalid client identity secret"
		return false
	var secret_hex := secret_hex_value as String
	if not _is_lower_hex_64(secret_hex):
		last_error = "invalid client identity secret"
		return false
	var loaded_secret := secret_hex.hex_decode()
	if loaded_secret.size() != SECRET_BYTES:
		last_error = "invalid client identity secret"
		return false
	_instance_secret = loaded_secret
	return true


func _write_new_atomic(secret: PackedByteArray) -> bool:
	var absolute_path := ProjectSettings.globalize_path(path)
	var directory := absolute_path.get_base_dir()
	if not directory.is_empty():
		var directory_error := DirAccess.make_dir_recursive_absolute(directory)
		if directory_error != OK:
			last_error = "cannot create client identity directory: %s" \
				% error_string(directory_error)
			return false
	var temporary_path := "%s.%d.tmp" % [absolute_path, OS.get_process_id()]
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		last_error = "cannot write client identity file: %s" \
			% error_string(FileAccess.get_open_error())
		return false
	file.store_string(JSON.stringify({
		"version": FORMAT_VERSION,
		"instance_secret": secret.hex_encode(),
	}, "\t") + "\n")
	file.flush()
	file = null
	var rename_error := DirAccess.rename_absolute(temporary_path, absolute_path)
	if rename_error != OK:
		DirAccess.remove_absolute(temporary_path)
		last_error = "cannot replace client identity file: %s" % error_string(rename_error)
		return false
	return true


static func _is_lower_hex_64(value: String) -> bool:
	if value.length() != SECRET_BYTES * 2 or value != value.to_lower():
		return false
	for index in range(value.length()):
		var code := value.unicode_at(index)
		if not ((code >= 48 and code <= 57) or (code >= 97 and code <= 102)):
			return false
	return true
