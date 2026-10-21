class_name ServerConsole
extends Node

var server: EasyServer = null
var _thread := Thread.new()
var _thread_started: bool = false
var _accepting_input: bool = true


func _ready() -> void:
	# Only an interactive terminal needs a reader. Redirected/automated launches
	# keep stdin untouched and therefore exit without a blocked Thread warning.
	if OS.get_stdin_type() == OS.STD_HANDLE_CONSOLE:
		_start_reader()


func _process(_delta: float) -> void:
	if not _thread_started or _thread.is_alive():
		return
	var line := str(_thread.wait_to_finish()).strip_edges()
	_thread_started = false
	if line.is_empty() or server == null or not is_instance_valid(server):
		_start_reader()
		return
	var response := server.execute_console_command(line)
	if not response.is_empty():
		Log.server_console(response)
	var command := line.get_slice(" ", 0).to_lower()
	if command not in ["stop", "restart"] and server.is_running():
		_start_reader()


func _exit_tree() -> void:
	_accepting_input = false


func _start_reader() -> void:
	if not _accepting_input or _thread_started:
		return
	_thread = Thread.new()
	_thread_started = _thread.start(_read_one_line) == OK


func _read_one_line() -> String:
	return OS.read_string_from_stdin(4096)
