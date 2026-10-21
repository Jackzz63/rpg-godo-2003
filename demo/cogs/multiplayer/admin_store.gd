class_name AdminStore
extends RefCounted

const FORMAT_VERSION := 1
const MAX_ADMIN_ID_LENGTH := 32
const MAX_CREDENTIAL_LENGTH := 160
const SECRET_BYTES := 32
const StatusProtocol := preload("res://cogs/multiplayer/server_status_protocol.gd")

var path: String = ""
var last_error: String = ""
var _admins: Dictionary = {}


func load_or_create(file_path: String) -> bool:
	path = file_path.strip_edges()
	last_error = ""
	if path.is_empty():
		last_error = "administrator file path is empty"
		return false
	if not FileAccess.file_exists(path):
		_admins.clear()
		return save()
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		last_error = "cannot open administrator file: %s" % error_string(FileAccess.get_open_error())
		return false
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		last_error = "administrator file is not a JSON object"
		return false
	var document := parsed as Dictionary
	if int(document.get("version", 0)) != FORMAT_VERSION:
		last_error = "unsupported administrator file version"
		return false
	var records: Variant = document.get("admins", [])
	if typeof(records) != TYPE_ARRAY:
		last_error = "administrator list is not an array"
		return false
	var loaded: Dictionary = {}
	var loaded_digests: Dictionary = {}
	for record_value in records as Array:
		if typeof(record_value) != TYPE_DICTIONARY:
			last_error = "administrator record is not an object"
			return false
		var record := record_value as Dictionary
		var admin_id := normalize_admin_id(str(record.get("id", "")))
		var digest_value: Variant = record.get("credential_digest", "")
		if typeof(digest_value) != TYPE_STRING:
			last_error = "administrator credential digest is not a string"
			return false
		var digest := digest_value as String
		if (admin_id.is_empty() or loaded.has(admin_id)
				or digest.is_empty() or digest.length() > MAX_CREDENTIAL_LENGTH
				or loaded_digests.has(digest)):
			last_error = "invalid or duplicate administrator record"
			return false
		loaded_digests[digest] = true
		loaded[admin_id] = {
			"id": admin_id,
			"credential_digest": digest,
			"enabled": bool(record.get("enabled", true)),
			"created_at": maxi(0, int(record.get("created_at", 0))),
			"updated_at": maxi(0, int(record.get("updated_at", 0))),
		}
	_admins = loaded
	return true


func save() -> bool:
	last_error = ""
	if path.is_empty():
		last_error = "administrator file path is empty"
		return false
	var records: Array = []
	var ids := _admins.keys()
	ids.sort()
	for id_value in ids:
		records.append((_admins[id_value] as Dictionary).duplicate(true))
	return _write_json_atomic({"version": FORMAT_VERSION, "admins": records})


func add(admin_id_value: String) -> Dictionary:
	var admin_id := normalize_admin_id(admin_id_value)
	if admin_id.is_empty():
		return {"ok": false, "error": "invalid admin id"}
	if _admins.has(admin_id):
		return {"ok": false, "error": "admin already exists"}
	var credential := _generate_credential(admin_id)
	var credential_digest := _credential_digest(credential)
	var now := int(Time.get_unix_time_from_system())
	_admins[admin_id] = {
		"id": admin_id,
		"credential_digest": credential_digest,
		"enabled": true,
		"created_at": now,
		"updated_at": now,
	}
	if not save():
		_admins.erase(admin_id)
		return {"ok": false, "error": last_error}
	return {"ok": true, "admin_id": admin_id, "credential": credential_digest}


func rotate(admin_id_value: String) -> Dictionary:
	var admin_id := normalize_admin_id(admin_id_value)
	if not _admins.has(admin_id):
		return {"ok": false, "error": "admin not found"}
	var previous := (_admins[admin_id] as Dictionary).duplicate(true)
	var credential := _generate_credential(admin_id)
	var credential_digest := _credential_digest(credential)
	var record := _admins[admin_id] as Dictionary
	record["credential_digest"] = credential_digest
	record["enabled"] = true
	record["updated_at"] = int(Time.get_unix_time_from_system())
	if not save():
		_admins[admin_id] = previous
		return {"ok": false, "error": last_error}
	return {"ok": true, "admin_id": admin_id, "credential": credential_digest}


func revoke(admin_id_value: String) -> Dictionary:
	var admin_id := normalize_admin_id(admin_id_value)
	if not _admins.has(admin_id):
		return {"ok": false, "error": "admin not found"}
	var previous := (_admins[admin_id] as Dictionary).duplicate(true)
	var record := _admins[admin_id] as Dictionary
	record["enabled"] = false
	record["updated_at"] = int(Time.get_unix_time_from_system())
	if not save():
		_admins[admin_id] = previous
		return {"ok": false, "error": last_error}
	return {"ok": true, "admin_id": admin_id}


func verify(credential_digest: String) -> String:
	if credential_digest.is_empty() or credential_digest.length() > MAX_CREDENTIAL_LENGTH:
		return ""
	for admin_id_value in _admins:
		var record := _admins[admin_id_value] as Dictionary
		if (bool(record.get("enabled", false))
				and str(record.get("credential_digest", "")) == credential_digest):
			return str(admin_id_value)
	return ""


func verify_status_proof(request_id: String, nonce: String, proof: String) -> bool:
	if (not StatusProtocol.is_hex(request_id, 32)
			or not StatusProtocol.is_hex(nonce, 64)
			or not StatusProtocol.is_hex(proof, 64)):
		return false
	var supplied := proof.hex_decode()
	var crypto := Crypto.new()
	var verified := false
	for admin_id_value in _admins:
		var record := _admins[admin_id_value] as Dictionary
		if not bool(record.get("enabled", false)):
			continue
		var expected := StatusProtocol.make_proof(
			str(record.get("credential_digest", "")), request_id, nonce).hex_decode()
		var matches := crypto.constant_time_compare(expected, supplied)
		verified = verified or matches
	return verified


func has_enabled(admin_id_value: String) -> bool:
	var admin_id := normalize_admin_id(admin_id_value)
	return (_admins.has(admin_id)
		and bool((_admins[admin_id] as Dictionary).get("enabled", false)))


# Local process only: never expose this credential through console or wire queries.
func get_or_create_local_host() -> Dictionary:
	const HOST_ID := "local_host"
	if not _admins.has(HOST_ID):
		return add(HOST_ID)
	if not has_enabled(HOST_ID):
		return {"ok": false, "error": "本地主机管理员已被禁用。"}
	return {"ok": true, "admin_id": HOST_ID,
		"credential": str((_admins[HOST_ID] as Dictionary)["credential_digest"])}


func list_records() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var ids := _admins.keys()
	ids.sort()
	for id_value in ids:
		var record := _admins[id_value] as Dictionary
		result.append({
			"id": str(record.get("id", "")),
			"enabled": bool(record.get("enabled", false)),
			"created_at": int(record.get("created_at", 0)),
			"updated_at": int(record.get("updated_at", 0)),
		})
	return result


static func normalize_admin_id(value: String) -> String:
	var normalized := value.strip_edges().to_lower()
	if normalized.is_empty() or normalized.length() > MAX_ADMIN_ID_LENGTH:
		return ""
	for character in normalized:
		if not (character >= "a" and character <= "z") \
				and not (character >= "0" and character <= "9") \
				and character != "_" and character != "-":
			return ""
	return normalized


func _generate_credential(admin_id: String) -> String:
	return "%s.%s" % [admin_id, Crypto.new().generate_random_bytes(SECRET_BYTES).hex_encode()]


func _credential_digest(credential: String) -> String:
	return credential.sha256_buffer().hex_encode()


func _write_json_atomic(document: Dictionary) -> bool:
	var absolute_path := ProjectSettings.globalize_path(path)
	var directory := absolute_path.get_base_dir()
	if not directory.is_empty():
		var directory_error := DirAccess.make_dir_recursive_absolute(directory)
		if directory_error != OK:
			last_error = "cannot create administrator directory: %s" % error_string(directory_error)
			return false
	var temporary_path := absolute_path + ".tmp"
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		last_error = "cannot write administrator file: %s" % error_string(FileAccess.get_open_error())
		return false
	file.store_string(JSON.stringify(document, "\t") + "\n")
	file.flush()
	file = null
	var rename_error := DirAccess.rename_absolute(temporary_path, absolute_path)
	if rename_error != OK:
		last_error = "cannot replace administrator file: %s" % error_string(rename_error)
		return false
	return true
