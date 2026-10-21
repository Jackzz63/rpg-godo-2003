class_name PunishmentStore
extends RefCounted

const FORMAT_VERSION := 4
const NETWORK_KEY_BYTES := 32
const SERVER_NAMESPACE_BYTES := 32
const SUBJECT_DIGEST_HEX_CHARS := 64

const KIND_MUTE := "mute"
const KIND_BAN := "ban"
const VALID_KINDS := [KIND_MUTE, KIND_BAN]

const SUBJECT_NETWORK := "network"
const SUBJECT_INSTALLATION := "installation"

const SCOPE_INSTALLATION := "installation"
const SCOPE_INSTALLATION_NETWORK := "installation_network"
const SCOPE_NETWORK := "network"
const VALID_SCOPES := [
	SCOPE_INSTALLATION,
	SCOPE_INSTALLATION_NETWORK,
	SCOPE_NETWORK,
]

const DURATION_FINITE := "finite"
const DURATION_PERMANENT := "permanent"
const VALID_DURATION_MODES := [DURATION_FINITE, DURATION_PERMANENT]

var path: String = ""
var last_error: String = ""
var _network_key: PackedByteArray = PackedByteArray()
var _server_namespace: String = ""
var _punishments: Array[Dictionary] = []
var _next_ban_sequence: int = 1
var _cleanup_persistence_pending: bool = false
var _cleanup_error_reported: bool = false


func load_or_create(file_path: String) -> bool:
	path = file_path.strip_edges()
	last_error = ""
	if path.is_empty():
		last_error = "punishment file path is empty"
		return false
	if not FileAccess.file_exists(path):
		_network_key = Crypto.new().generate_random_bytes(NETWORK_KEY_BYTES)
		_server_namespace = Crypto.new().generate_random_bytes(
			SERVER_NAMESPACE_BYTES).hex_encode()
		_punishments.clear()
		_next_ban_sequence = 1
		return save()

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		last_error = "cannot open punishment file: %s" % error_string(FileAccess.get_open_error())
		return false
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file = null
	if typeof(parsed) != TYPE_DICTIONARY:
		last_error = "punishment file is not a JSON object"
		return false
	var document := parsed as Dictionary
	var source_version := int(document.get("version", 0))
	if source_version not in [1, 2, 3, FORMAT_VERSION]:
		last_error = "unsupported punishment file version"
		return false

	var key_hex := str(document.get("network_key", "")).to_lower()
	if not _is_digest(key_hex):
		last_error = "invalid punishment network key"
		return false
	var namespace_hex := str(document.get("server_namespace", "")).to_lower()
	if source_version >= 3:
		if not _is_digest(namespace_hex):
			last_error = "invalid punishment server namespace"
			return false
	else:
		namespace_hex = Crypto.new().generate_random_bytes(
			SERVER_NAMESPACE_BYTES).hex_encode()

	var records_value: Variant = document.get("bans", [])
	if typeof(records_value) != TYPE_ARRAY:
		last_error = "punishment list is not an array"
		return false

	var now := int(Time.get_unix_time_from_system())
	var loaded: Array[Dictionary] = []
	var seen_ids: Dictionary = {}
	var highest_sequence := 0
	for record_value in records_value as Array:
		if typeof(record_value) != TYPE_DICTIONARY:
			last_error = "punishment record is not an object"
			return false
		var source := record_value as Dictionary
		var punishment_id := str(source.get("id", ""))
		var kind := str(source.get("kind", KIND_BAN)).to_lower()
		if punishment_id.is_empty() or seen_ids.has(punishment_id) or kind not in VALID_KINDS:
			last_error = "invalid or duplicate punishment record"
			return false
		seen_ids[punishment_id] = true
		highest_sequence = maxi(highest_sequence, _sequence_from_id(punishment_id))

		var subjects: Dictionary = {}
		if source_version >= 3:
			var subjects_value: Variant = source.get("subjects", {})
			if typeof(subjects_value) != TYPE_DICTIONARY:
				last_error = "punishment subjects are not an object"
				return false
			for subject_kind in [SUBJECT_NETWORK, SUBJECT_INSTALLATION]:
				var digest := str((subjects_value as Dictionary).get(subject_kind, "")).to_lower()
				if digest.is_empty():
					continue
				if not _is_digest(digest):
					last_error = "invalid punishment subject digest"
					return false
				subjects[subject_kind] = digest
		else:
			var network_digest := str(source.get("subject_digest", "")).to_lower()
			if not _is_digest(network_digest):
				last_error = "invalid punishment subject digest"
				return false
			subjects[SUBJECT_NETWORK] = network_digest

		var scope := str(source.get("scope", "")).to_lower()
		if source_version < FORMAT_VERSION:
			# V3's implicit installation/network OR is intentionally migrated to
			# installation-only. Legacy network-only records remain network scoped.
			if subjects.has(SUBJECT_INSTALLATION):
				scope = SCOPE_INSTALLATION
				subjects.erase(SUBJECT_NETWORK)
			else:
				scope = SCOPE_NETWORK
		if not _scope_matches_subjects(scope, subjects):
			last_error = "invalid punishment scope or subjects"
			return false

		var duration_mode := str(source.get("duration_mode", DURATION_FINITE)).to_lower()
		if source_version < FORMAT_VERSION:
			duration_mode = DURATION_FINITE
		if duration_mode not in VALID_DURATION_MODES:
			last_error = "invalid punishment duration mode"
			return false
		var expires_at := int(source.get("expires_at", 0))
		if duration_mode == DURATION_FINITE and expires_at <= 0:
			last_error = "invalid punishment expiry"
			return false
		if int(source.get("revoked_at", 0)) > 0:
			continue
		if duration_mode == DURATION_FINITE and expires_at <= now:
			continue
		if duration_mode == DURATION_PERMANENT:
			expires_at = 0
		loaded.append(_normalized_record(
			source, punishment_id, kind, subjects, scope, duration_mode, expires_at))

	_network_key = key_hex.hex_decode()
	_server_namespace = namespace_hex
	_punishments = loaded
	_next_ban_sequence = maxi(
		maxi(1, int(document.get("next_ban_sequence", 1))), highest_sequence + 1)
	var needs_rewrite := (
		source_version != FORMAT_VERSION
		or loaded.size() != (records_value as Array).size())
	return save() if needs_rewrite else true


func save() -> bool:
	last_error = ""
	if (path.is_empty() or _network_key.size() != NETWORK_KEY_BYTES
			or not _is_digest(_server_namespace)):
		last_error = "punishment store is not initialized"
		return false
	var written := _write_json_atomic({
		"version": FORMAT_VERSION,
		"network_key": _network_key.hex_encode(),
		"server_namespace": _server_namespace,
		"next_ban_sequence": _next_ban_sequence,
		"bans": _punishments,
	})
	if written:
		_cleanup_persistence_pending = false
		_cleanup_error_reported = false
	return written


func get_server_namespace() -> String:
	return _server_namespace


func add_subject_ban(
		address: String, installation_identity: String, last_name: String,
		duration_seconds: int, actor: String, include_network: bool = false,
		duration_mode: String = DURATION_FINITE) -> Dictionary:
	return _add_subject_punishment(
		KIND_BAN, address, installation_identity, last_name, duration_seconds,
		actor, include_network, duration_mode)


func add_subject_mute(
		address: String, installation_identity: String, last_name: String,
		duration_seconds: int, actor: String, include_network: bool = false,
		duration_mode: String = DURATION_FINITE) -> Dictionary:
	return _add_subject_punishment(
		KIND_MUTE, address, installation_identity, last_name, duration_seconds,
		actor, include_network, duration_mode)


func add_network_ban(
		address: String, last_name: String, duration_seconds: int,
		actor: String, duration_mode: String = DURATION_FINITE) -> Dictionary:
	return _add_subject_punishment(
		KIND_BAN, address, "", last_name, duration_seconds, actor, true, duration_mode)


func add_network_mute(
		address: String, last_name: String, duration_seconds: int,
		actor: String, duration_mode: String = DURATION_FINITE) -> Dictionary:
	return _add_subject_punishment(
		KIND_MUTE, address, "", last_name, duration_seconds, actor, true, duration_mode)


func _add_subject_punishment(
		kind: String, address: String, installation_identity: String,
		last_name: String, duration_seconds: int, actor: String,
		include_network: bool, duration_mode: String) -> Dictionary:
	if kind not in VALID_KINDS:
		return {"ok": false, "error": "unsupported punishment kind"}
	var duration_error := _duration_error(duration_seconds, duration_mode)
	if not duration_error.is_empty():
		return {"ok": false, "error": duration_error}

	var all_subjects := _subject_digests(address, installation_identity)
	var subjects: Dictionary = {}
	var scope := ""
	if all_subjects.has(SUBJECT_INSTALLATION):
		subjects[SUBJECT_INSTALLATION] = all_subjects[SUBJECT_INSTALLATION]
		if include_network:
			if not all_subjects.has(SUBJECT_NETWORK):
				return {"ok": false, "error": "network identity is unavailable"}
			subjects[SUBJECT_NETWORK] = all_subjects[SUBJECT_NETWORK]
			scope = SCOPE_INSTALLATION_NETWORK
		else:
			scope = SCOPE_INSTALLATION
	elif all_subjects.has(SUBJECT_NETWORK):
		subjects[SUBJECT_NETWORK] = all_subjects[SUBJECT_NETWORK]
		scope = SCOPE_NETWORK
	else:
		return {"ok": false, "error": "unusable punishment identity"}

	var now := int(Time.get_unix_time_from_system())
	_prune_expired(now)
	var previous_active := find_active_owned_by_subjects(
		address, installation_identity, now, kind)
	if not previous_active.is_empty():
		return {
			"ok": false,
			"error": "subject already has this punishment",
			"ban": previous_active,
		}

	var punishment_id := "%s-%06d" % [
		"M" if kind == KIND_MUTE else "B", _next_ban_sequence]
	_next_ban_sequence += 1
	var record: Dictionary = {
		"id": punishment_id,
		"kind": kind,
		"scope": scope,
		"duration_mode": duration_mode,
		"subjects": subjects,
		"network_label": _label_for_subject(subjects, SUBJECT_NETWORK),
		"installation_label": _label_for_subject(subjects, SUBJECT_INSTALLATION),
		"last_name": last_name.left(64),
		"created_at": now,
		"expires_at": 0 if duration_mode == DURATION_PERMANENT else now + duration_seconds,
		"actor": actor,
	}
	_punishments.append(record)
	if not save():
		_punishments.pop_back()
		return {"ok": false, "error": last_error}
	return {"ok": true, "ban": record.duplicate(true)}


func revoke(punishment_id: String, _actor: String) -> Dictionary:
	_prune_expired(int(Time.get_unix_time_from_system()))
	for index in range(_punishments.size()):
		var record := _punishments[index] as Dictionary
		if str(record.get("id", "")) != punishment_id:
			continue
		var removed := record.duplicate(true)
		_punishments.remove_at(index)
		if not save():
			_punishments.insert(index, record)
			return {"ok": false, "error": last_error}
		return {"ok": true, "ban": removed}
	return {"ok": false, "error": "punishment not found"}


func revoke_active_for_subjects(
		address: String, installation_identity: String, kind: String,
		_actor: String) -> Dictionary:
	if kind not in VALID_KINDS:
		return {"ok": false, "error": "unsupported punishment kind"}
	var candidate := _subject_digests(address, installation_identity)
	if candidate.is_empty():
		return {"ok": false, "error": "unusable punishment identity"}
	_prune_expired(int(Time.get_unix_time_from_system()))
	var previous := _punishments.duplicate(true)
	var removed: Array[Dictionary] = []
	for index in range(_punishments.size() - 1, -1, -1):
		var record := _punishments[index] as Dictionary
		if (str(record.get("kind", KIND_BAN)) == kind
				and _record_owned_by_subjects(record, candidate)):
			removed.append(record.duplicate(true))
			_punishments.remove_at(index)
	if removed.is_empty():
		return {"ok": false, "error": "active punishment not found"}
	if not save():
		_punishments = previous
		return {"ok": false, "error": last_error}
	return {"ok": true, "punishments": removed}


func revoke_active_for_address(address: String, kind: String, actor: String) -> Dictionary:
	return revoke_active_for_subjects(address, "", kind, actor)


func find_active_for_subjects(
		address: String, installation_identity: String, now: int = -1,
		kind: String = KIND_BAN) -> Dictionary:
	var current := int(Time.get_unix_time_from_system()) if now < 0 else now
	_prune_expired(current)
	var candidate := _subject_digests(address, installation_identity)
	if candidate.is_empty():
		return {}
	var effective: Dictionary = {}
	for record_value in _punishments:
		var record := record_value as Dictionary
		if ((kind.is_empty() or str(record.get("kind", KIND_BAN)) == kind)
				and punishment_applies_to(record, address, installation_identity)
				and (effective.is_empty() or _record_is_better(record, effective))):
			effective = record
	return effective.duplicate(true) if not effective.is_empty() else {}


func find_active_owned_by_subjects(
		address: String, installation_identity: String, now: int = -1,
		kind: String = KIND_BAN) -> Dictionary:
	var current := int(Time.get_unix_time_from_system()) if now < 0 else now
	_prune_expired(current)
	var candidate := _subject_digests(address, installation_identity)
	if candidate.is_empty():
		return {}
	var effective: Dictionary = {}
	for record_value in _punishments:
		var record := record_value as Dictionary
		if ((kind.is_empty() or str(record.get("kind", KIND_BAN)) == kind)
				and _record_owned_by_subjects(record, candidate)
				and (effective.is_empty() or _record_is_better(record, effective))):
			effective = record
	return effective.duplicate(true) if not effective.is_empty() else {}


func find_active_for_address(
		address: String, now: int = -1, kind: String = KIND_BAN) -> Dictionary:
	return find_active_for_subjects(address, "", now, kind)


func get_active(punishment_id: String, now: int = -1) -> Dictionary:
	var current := int(Time.get_unix_time_from_system()) if now < 0 else now
	_prune_expired(current)
	for record_value in _punishments:
		var record := record_value as Dictionary
		if str(record.get("id", "")) == punishment_id:
			return record.duplicate(true)
	return {}


# Synchronous read-only projection: the visitor must copy only its bounded wire values.
# Do not deep-copy the unbounded store before the caller can reject its budget.
func visit_active_for_snapshot(visitor: Callable, now: int = -1) -> bool:
	var current := int(Time.get_unix_time_from_system()) if now < 0 else now
	for record in _punishments:
		if record_duration_mode(record) == DURATION_FINITE and int(record.get("expires_at", 0)) <= current:
			continue
		if not bool(visitor.call(record)):
			return false
	return true


func list_active(now: int = -1, kind: String = "") -> Array[Dictionary]:
	var current := int(Time.get_unix_time_from_system()) if now < 0 else now
	_prune_expired(current)
	var result: Array[Dictionary] = []
	for record_value in _punishments:
		var record := record_value as Dictionary
		if kind.is_empty() or str(record.get("kind", KIND_BAN)) == kind:
			result.append(record.duplicate(true))
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if record_duration_mode(a) != record_duration_mode(b):
			return record_duration_mode(a) == DURATION_FINITE
		return int(a.get("expires_at", 0)) < int(b.get("expires_at", 0)))
	return result


func prune_expired(now: int = -1) -> bool:
	return _prune_expired(
		int(Time.get_unix_time_from_system()) if now < 0 else now)


func punishment_applies_to(
		record: Dictionary, address: String, installation_identity: String) -> bool:
	return _record_matches_subjects(
		record, _subject_digests(address, installation_identity))


func record_matches_subjects(
		record: Dictionary, address: String, installation_identity: String) -> bool:
	return punishment_applies_to(record, address, installation_identity)


func record_owned_by_subjects(
		record: Dictionary, address: String, installation_identity: String) -> bool:
	return _record_owned_by_subjects(
		record, _subject_digests(address, installation_identity))


func record_profile_match_strength(
		record: Dictionary, address: String, installation_identity: String) -> int:
	var candidate := _subject_digests(address, installation_identity)
	var record_subjects := record.get("subjects", {}) as Dictionary
	if (candidate.has(SUBJECT_INSTALLATION)
			and record_subjects.get(SUBJECT_INSTALLATION, "")
				== candidate[SUBJECT_INSTALLATION]):
		return 2
	if (not record_subjects.has(SUBJECT_INSTALLATION)
			and candidate.has(SUBJECT_NETWORK)
			and record_subjects.get(SUBJECT_NETWORK, "") == candidate[SUBJECT_NETWORK]):
		return 1
	return 0


func update_active_profile_for_subjects(
		address: String, installation_identity: String, profile: Dictionary,
		now: int = -1) -> void:
	if profile.is_empty():
		return
	var current := int(Time.get_unix_time_from_system()) if now < 0 else now
	_prune_expired(current)
	var changed := false
	for record_value in _punishments:
		var record := record_value as Dictionary
		if record_profile_match_strength(record, address, installation_identity) <= 0:
			continue
		var updates := {
			"last_name": str(profile.get("display_name", record.get("last_name", ""))).left(64),
			"last_system_name": str(profile.get("system_name", record.get("last_system_name", ""))),
			"last_system_stretch": clampi(int(profile.get("system_stretch", record.get("last_system_stretch", 1))), 0, 1),
			"last_sprite_name": str(profile.get("sprite_name", record.get("last_sprite_name", ""))),
			"last_sprite_index": clampi(int(profile.get("sprite_index", record.get("last_sprite_index", 0))), 0, 7),
			"last_facing": clampi(int(profile.get("facing", record.get("last_facing", 2))), 0, 3),
		}
		for key in updates:
			if record.get(key) != updates[key]:
				record[key] = updates[key]
				changed = true
	if changed:
		save()


func update_active_profile_for_address(
		address: String, profile: Dictionary, now: int = -1) -> void:
	update_active_profile_for_subjects(address, "", profile, now)


func update_punishment(
		punishment_id: String, duration_seconds: int, duration_mode: String,
		include_network: bool, address: String = "",
		installation_identity: String = "") -> Dictionary:
	if punishment_id.is_empty():
		return {"ok": false, "error": "invalid punishment id"}
	var duration_error := _duration_error(duration_seconds, duration_mode)
	if not duration_error.is_empty():
		return {"ok": false, "error": duration_error}
	var now := int(Time.get_unix_time_from_system())
	_prune_expired(now)
	for index in range(_punishments.size()):
		var record := _punishments[index] as Dictionary
		if str(record.get("id", "")) != punishment_id:
			continue
		var previous := record.duplicate(true)
		var subjects := (record.get("subjects", {}) as Dictionary).duplicate(true)
		if subjects.has(SUBJECT_INSTALLATION):
			if include_network:
				if not subjects.has(SUBJECT_NETWORK):
					var candidates := _subject_digests(address, installation_identity)
					if not candidates.has(SUBJECT_NETWORK):
						return {"ok": false, "error": "network identity is unavailable"}
					subjects[SUBJECT_NETWORK] = candidates[SUBJECT_NETWORK]
				record["scope"] = SCOPE_INSTALLATION_NETWORK
			else:
				subjects.erase(SUBJECT_NETWORK)
				record["scope"] = SCOPE_INSTALLATION
		else:
			if not subjects.has(SUBJECT_NETWORK):
				return {"ok": false, "error": "network punishment has no network identity"}
			record["scope"] = SCOPE_NETWORK
		record["subjects"] = subjects
		record["network_label"] = _label_for_subject(subjects, SUBJECT_NETWORK)
		record["installation_label"] = _label_for_subject(subjects, SUBJECT_INSTALLATION)
		record["duration_mode"] = duration_mode
		record["expires_at"] = (
			0 if duration_mode == DURATION_PERMANENT else now + duration_seconds)
		if not save():
			_punishments[index] = previous
			return {"ok": false, "error": last_error}
		return {"ok": true, "ban": record.duplicate(true)}
	return {"ok": false, "error": "punishment not found"}


func change_duration(punishment_id: String, duration_seconds: int) -> Dictionary:
	var record := get_active(punishment_id)
	if record.is_empty():
		return {"ok": false, "error": "punishment not found"}
	return update_punishment(
		punishment_id, duration_seconds, DURATION_FINITE,
		record_has_network_scope(record))


func network_label_for_address(address: String) -> String:
	var normalized := normalize_address(address)
	if not address_is_usable(normalized):
		return ""
	return _network_digest(normalized).left(10).to_upper()


func installation_label_for_identity(installation_identity: String) -> String:
	if not installation_identity_is_usable(installation_identity):
		return ""
	return _installation_digest(installation_identity.to_lower()).left(10).to_upper()


func subject_group_id_for_record(record: Dictionary) -> String:
	var subjects_value: Variant = record.get("subjects", {})
	if typeof(subjects_value) != TYPE_DICTIONARY:
		return ""
	var digest := str((subjects_value as Dictionary).get(
		SUBJECT_INSTALLATION, "")).to_lower()
	return digest if _is_digest(digest) else ""


func subject_group_id_for_installation(installation_identity: String) -> String:
	var normalized := installation_identity.strip_edges().to_lower()
	if not installation_identity_is_usable(normalized):
		return ""
	return _installation_digest(normalized)


static func record_duration_mode(record: Dictionary) -> String:
	var mode := str(record.get("duration_mode", DURATION_FINITE)).to_lower()
	return mode if mode in VALID_DURATION_MODES else DURATION_FINITE


static func record_has_network_scope(record: Dictionary) -> bool:
	return str(record.get("scope", SCOPE_INSTALLATION)) in [
		SCOPE_INSTALLATION_NETWORK, SCOPE_NETWORK]


static func record_is_active(record: Dictionary, now: int = -1) -> bool:
	if record_duration_mode(record) == DURATION_PERMANENT:
		return true
	var current := int(Time.get_unix_time_from_system()) if now < 0 else now
	return int(record.get("expires_at", 0)) > current


static func normalize_address(address: String) -> String:
	var normalized := address.strip_edges().to_lower()
	if normalized.begins_with("::ffff:"):
		normalized = normalized.substr(7)
	return normalized


static func address_is_usable(address: String) -> bool:
	var normalized := normalize_address(address)
	if normalized.is_empty() or not normalized.is_valid_ip_address():
		return false
	if normalized.begins_with("127."):
		return false
	return normalized not in ["::1", "0.0.0.0", "::"]


static func installation_identity_is_usable(identity: String) -> bool:
	var normalized := identity.strip_edges().to_lower()
	return _is_digest(normalized)


func _subject_digests(address: String, installation_identity: String) -> Dictionary:
	var result: Dictionary = {}
	var normalized_address := normalize_address(address)
	if address_is_usable(normalized_address):
		result[SUBJECT_NETWORK] = _network_digest(normalized_address)
	var normalized_identity := installation_identity.strip_edges().to_lower()
	if installation_identity_is_usable(normalized_identity):
		result[SUBJECT_INSTALLATION] = _installation_digest(normalized_identity)
	return result


func _record_matches_subjects(record: Dictionary, candidate: Dictionary) -> bool:
	if candidate.is_empty():
		return false
	var record_subjects_value: Variant = record.get("subjects", {})
	if typeof(record_subjects_value) != TYPE_DICTIONARY:
		return false
	var record_subjects := record_subjects_value as Dictionary
	var scope := str(record.get("scope", SCOPE_INSTALLATION))
	if scope in [SCOPE_INSTALLATION, SCOPE_INSTALLATION_NETWORK]:
		if (candidate.has(SUBJECT_INSTALLATION)
				and record_subjects.get(SUBJECT_INSTALLATION, "")
					== candidate[SUBJECT_INSTALLATION]):
			return true
	if scope in [SCOPE_NETWORK, SCOPE_INSTALLATION_NETWORK]:
		if (candidate.has(SUBJECT_NETWORK)
				and record_subjects.get(SUBJECT_NETWORK, "") == candidate[SUBJECT_NETWORK]):
			return true
	return false


func _record_owned_by_subjects(record: Dictionary, candidate: Dictionary) -> bool:
	if candidate.is_empty():
		return false
	var record_subjects := record.get("subjects", {}) as Dictionary
	if record_subjects.has(SUBJECT_INSTALLATION):
		return (candidate.has(SUBJECT_INSTALLATION)
			and record_subjects.get(SUBJECT_INSTALLATION, "")
				== candidate[SUBJECT_INSTALLATION])
	return (candidate.has(SUBJECT_NETWORK)
		and record_subjects.get(SUBJECT_NETWORK, "") == candidate[SUBJECT_NETWORK])


func _prune_expired(now: int) -> bool:
	var changed := false
	for index in range(_punishments.size() - 1, -1, -1):
		var record := _punishments[index] as Dictionary
		if (record_duration_mode(record) == DURATION_FINITE
				and int(record.get("expires_at", 0)) <= now):
			_punishments.remove_at(index)
			changed = true
	if changed:
		_cleanup_persistence_pending = true
	if _cleanup_persistence_pending and not save() and not _cleanup_error_reported:
		_cleanup_error_reported = true
		push_error("[PunishmentStore] could not persist expired-record cleanup: %s" % last_error)
	return changed


func _normalized_record(
		source: Dictionary, punishment_id: String, kind: String,
		subjects: Dictionary, scope: String, duration_mode: String,
		expires_at: int) -> Dictionary:
	return {
		"id": punishment_id,
		"kind": kind,
		"scope": scope,
		"duration_mode": duration_mode,
		"subjects": subjects,
		"network_label": _label_for_subject(subjects, SUBJECT_NETWORK),
		"installation_label": _label_for_subject(subjects, SUBJECT_INSTALLATION),
		"last_name": str(source.get("last_name", "")).left(64),
		"last_system_name": str(source.get("last_system_name", "")),
		"last_system_stretch": clampi(int(source.get("last_system_stretch", 1)), 0, 1),
		"last_sprite_name": str(source.get("last_sprite_name", "")),
		"last_sprite_index": clampi(int(source.get("last_sprite_index", 0)), 0, 7),
		"last_facing": clampi(int(source.get("last_facing", 2)), 0, 3),
		"created_at": maxi(0, int(source.get("created_at", 0))),
		"expires_at": expires_at,
		"actor": str(source.get("actor", "")),
	}


func _network_digest(normalized_address: String) -> String:
	# Keep the version-2 input unchanged so migrated network-only records remain
	# matchable after the format upgrade.
	return Crypto.new().hmac_digest(
		HashingContext.HASH_SHA256,
		_network_key,
		normalized_address.to_utf8_buffer()).hex_encode()


func _installation_digest(normalized_identity: String) -> String:
	return Crypto.new().hmac_digest(
		HashingContext.HASH_SHA256,
		_network_key,
		("installation\n" + normalized_identity).to_utf8_buffer()).hex_encode()


static func _scope_matches_subjects(scope: String, subjects: Dictionary) -> bool:
	if scope not in VALID_SCOPES:
		return false
	if scope == SCOPE_INSTALLATION:
		return subjects.has(SUBJECT_INSTALLATION) and not subjects.has(SUBJECT_NETWORK)
	if scope == SCOPE_INSTALLATION_NETWORK:
		return subjects.has(SUBJECT_INSTALLATION) and subjects.has(SUBJECT_NETWORK)
	return subjects.has(SUBJECT_NETWORK) and not subjects.has(SUBJECT_INSTALLATION)


static func _duration_error(duration_seconds: int, duration_mode: String) -> String:
	if duration_mode not in VALID_DURATION_MODES:
		return "invalid duration mode"
	if duration_mode == DURATION_FINITE and duration_seconds <= 0:
		return "duration must be positive"
	return ""


static func _record_is_better(candidate: Dictionary, current: Dictionary) -> bool:
	var candidate_permanent := record_duration_mode(candidate) == DURATION_PERMANENT
	var current_permanent := record_duration_mode(current) == DURATION_PERMANENT
	if candidate_permanent != current_permanent:
		return candidate_permanent
	return int(candidate.get("expires_at", 0)) > int(current.get("expires_at", 0))


static func _label_for_subject(subjects: Dictionary, kind: String) -> String:
	return str(subjects.get(kind, "")).left(10).to_upper()


static func _is_digest(value: String) -> bool:
	return (value.length() == SUBJECT_DIGEST_HEX_CHARS
		and value.is_valid_hex_number())


static func _sequence_from_id(punishment_id: String) -> int:
	var separator := punishment_id.rfind("-")
	if separator < 0:
		return 0
	var suffix := punishment_id.substr(separator + 1)
	return int(suffix) if suffix.is_valid_int() else 0


func _write_json_atomic(document: Dictionary) -> bool:
	var absolute_path := ProjectSettings.globalize_path(path)
	var directory := absolute_path.get_base_dir()
	if not directory.is_empty():
		var directory_error := DirAccess.make_dir_recursive_absolute(directory)
		if directory_error != OK:
			last_error = "cannot create punishment directory: %s" % error_string(directory_error)
			return false
	var temporary_path := absolute_path + ".tmp"
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		last_error = "cannot write punishment file: %s" % error_string(FileAccess.get_open_error())
		return false
	file.store_string(JSON.stringify(document, "\t") + "\n")
	file.flush()
	file = null
	var rename_error := DirAccess.rename_absolute(temporary_path, absolute_path)
	if rename_error != OK:
		last_error = "cannot replace punishment file: %s" % error_string(rename_error)
		return false
	return true
