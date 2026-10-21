extends Node

# Structured body spans coexist with the legacy signals during negotiation.
signal on_chat_record(record: Dictionary)

# p4o-a7o: yes this is probably sloppy as hell but oh well Lol
signal on_chat_message(display_name: String, text: String)
signal on_chat_message_metadata(
	sender_id: int,
	display_name: String,
	system_name: String,
	mention_target_pid: int,
	text: String
)
# Legacy signal retained for compatibility with pre-raw global-chat consumers.
signal on_global_chat_message(
	sender_id: int,
	display_name: String,
	room_id: int,
	room_japanese: String,
	room_english: String,
	text: String
)

# Location labels and links are intentionally absent. Consumers resolve these
# raw values through their own client-side location runtime.
signal on_global_chat_message_raw(
	sender_id: int,
	display_name: String,
	map_id: int,
	prev_map_id: int,
	x: int,
	y: int,
	text: String
)
signal on_global_chat_message_metadata(
	sender_id: int,
	display_name: String,
	system_name: String,
	map_id: int,
	prev_map_id: int,
	x: int,
	y: int,
	mention_target_pid: int,
	text: String
)
