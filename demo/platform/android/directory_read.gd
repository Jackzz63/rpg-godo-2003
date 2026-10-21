extends RefCounted
## Data-only directory job. The Android runtime owns it until the pool task is
## joined; a temporary picker may disappear while the OS is still reading.
signal completed(value: Dictionary)

var path: String
var initial_root: String
var task_id := -1
var result: Dictionary = {}
var measure := false
var _cancelled := false
var _mutex := Mutex.new()


func _init(target: String, fallback := "") -> void:
	path = target
	initial_root = fallback


func cancel() -> void:
	_mutex.lock()
	_cancelled = true
	_mutex.unlock()


func is_cancelled() -> bool:
	_mutex.lock()
	var value := _cancelled
	_mutex.unlock()
	return value


func run() -> void:
	var started := Time.get_ticks_usec() if measure else 0
	result = _read()
	if measure:
		result.scan_usec = Time.get_ticks_usec() - started


func _read() -> Dictionary:
	if is_cancelled(): return {"ok": false, "cancelled": true}
	var target := path
	# Only initial opening has this fallback. An unreadable existing directory
	# or a failed navigation must still report an error to the original caller.
	if not initial_root.is_empty() and (not target.begins_with("/") or not DirAccess.dir_exists_absolute(target)):
		target = initial_root
	if is_cancelled(): return {"ok": false, "cancelled": true}
	var directory := DirAccess.open(target) if not target.is_empty() else null
	if directory == null or directory.list_dir_begin() != OK:
		return {"ok": false}
	var names := PackedStringArray()
	var count := 0
	var entry := directory.get_next()
	while not entry.is_empty():
		if is_cancelled():
			directory.list_dir_end()
			return {"ok": false, "cancelled": true}
		if directory.current_is_dir() and entry != "." and entry != "..":
			names.append(entry)
		count += 1
		entry = directory.get_next()
	directory.list_dir_end()
	names.sort()
	return {"ok": true, "names": names, "path": target.simplify_path(), "entries": count}
