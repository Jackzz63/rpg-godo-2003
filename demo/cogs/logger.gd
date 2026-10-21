class_name Log extends Node

static func debug(message: String) -> void:
	if OS.is_debug_build():
		#LimboConsole.debug(message)  # too much logs causes lagging
		print("[Debug]: %s" % message)

static func info(message: String) -> void:
	LimboConsole.info(message)
	print("[Info]: %s" % message)

static func warn(message: String) -> void:
	LimboConsole.warn(message)
	print("[Warn]: %s" % message)

static func error(message: String) -> void:
	LimboConsole.error(message)
	push_error(message)
	printerr("[Error]: %s" % message)


static func format_server_console_lines(
		message: String,
		level_prefix: String = "",
		clock: Dictionary = {}) -> String:
	var resolved_clock := clock
	if resolved_clock.is_empty():
		resolved_clock = Time.get_time_dict_from_system()
	var timestamp := "[%02d:%02d] " % [
		int(resolved_clock.get("hour", 0)),
		int(resolved_clock.get("minute", 0)),
	]
	var normalized := message.replace("\r\n", "\n").replace("\r", "\n")
	var formatted := PackedStringArray()
	for line in normalized.split("\n", true):
		formatted.append(timestamp + level_prefix + line)
	return "\n".join(formatted)


static func server_debug(message: String) -> void:
	if OS.is_debug_build():
		print(format_server_console_lines(message, "[Debug]: "))


static func server_info(message: String) -> void:
	LimboConsole.info(message)
	print(format_server_console_lines(message, "[Info]: "))


static func server_warn(message: String) -> void:
	LimboConsole.warn(message)
	print(format_server_console_lines(message, "[Warn]: "))


static func server_error(message: String) -> void:
	LimboConsole.error(message)
	var formatted := format_server_console_lines(message, "[Error]: ")
	push_error(formatted)
	printerr(formatted)


static func server_console(message: String) -> void:
	print(format_server_console_lines(message))
