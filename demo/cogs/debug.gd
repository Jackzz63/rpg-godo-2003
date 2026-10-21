extends Node

@export var engine: RPGMakerPlayer

@export var game_resolution: Vector2i = Vector2i(320, 240):
	set(value):
		game_resolution = value
		if engine != null and engine.is_running():
			engine.set_resolution(value.x, value.y)

@export var open_save_menu: bool = false:
	set(value):
		if value:
			open_save_menu = false
			do_open_save_menu()

@export var open_load_menu: bool = false:
	set(value):
		if value:
			open_load_menu = false
			do_open_load_menu()

@export var open_debug_menu: bool = false:
	set(value):
		if value:
			open_debug_menu = false
			do_open_debug_menu()

func do_open_save_menu() -> void:
	var e := get_node_or_null("%RPGMakerPlayer") as RPGMakerPlayer
	if e and e.is_running(): e.open_save_menu()
	else: Log.error("Engine is not running!")

func do_open_load_menu() -> void:
	var e := get_node_or_null("%RPGMakerPlayer") as RPGMakerPlayer
	if e and e.is_running(): e.open_load_menu()
	else: Log.error("Engine is not running!")

func do_open_debug_menu() -> void:
	var e := get_node_or_null("%RPGMakerPlayer") as RPGMakerPlayer
	if e and e.is_running(): e.open_debug_menu()
	else: Log.error("Engine is not running!")

func set_resolution_scale(scale: float) -> void:
	var e := get_node_or_null("%RPGMakerPlayer") as RPGMakerPlayer
	if scale < 0.75 or scale > 2.:
		Log.error("Keep scale in range of [0.75, 2.0]")
	if e and e.is_running():
		var x: int = floor(320. * scale)
		var y: int = floor(240. * scale)
		e.set_resolution(x, y)
		Log.info("Rendering %d x %d pixels" % [x, y])
	else: Log.error("Engine is not running!")

# p4o-a7o: maybe make this action accessible from a toolbar menu later
# i added this so its at least possible to disable/enable the chat
# while playing the game
func chat_command(enabled: bool) -> void:
	var mp_node := get_node_or_null("%RPGMakerPlayer/MpNode") as EasyMultiplayer
	if not mp_node:
		Log.warn("You are not connected to multiplayer!")
		return
	mp_node.set_enable_chat(enabled)
	var chat_ctrl := %ChatControl
	chat_ctrl.call("_set_chat_enabled", enabled)

func chat_ui_command() -> void:
	var chat_ctrl := %ChatControl
	var enabled := not bool(chat_ctrl.chat_enabled)
	chat_ctrl.call("_set_chat_enabled", enabled)
	Log.info("Chat UI enabled: %s" % enabled)


func _add_limbo_commands() -> void:
	if LimboConsole.has_command("fullscreen"):
		LimboConsole.unregister_command("fullscreen")
	LimboConsole.register_command(toggle_fullscreen, "fullscreen", "Toggle the application window fullscreen mode")
	LimboConsole.register_command(do_open_save_menu, "save", "Open save screen")
	LimboConsole.register_command(do_open_load_menu, "load", "Open load screen")
	LimboConsole.register_command(do_open_debug_menu, "debug", "Open debug screen")
	LimboConsole.register_command(set_resolution_scale, "rescale", "Scales resolution to a given multiplier")
	LimboConsole.register_command(chat_command, "chat", "Enables/disables multiplayer chat. Only works on the client.")
	LimboConsole.register_command(chat_ui_command, "chatui", "Toggle the local chat UI without changing network chat")

func _ready() -> void:
	if OS.is_debug_build() or true:
		_add_limbo_commands()


func toggle_fullscreen() -> void:
	%WindowModeController.toggle_fullscreen()
