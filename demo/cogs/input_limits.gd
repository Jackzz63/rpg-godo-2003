extends RefCounted

const NICKNAME_MAX_ASCII_CHARACTERS := 12
const CHAT_MESSAGE_MAX_CHARACTERS := 100
const NORMAL_FLASH_FRAMES := 10_000
const HARD_FLASH_FRAMES := 60_000


static func sanitize_nickname(value: String) -> String:
	var result := ""
	for index in value.length():
		var codepoint := value.unicode_at(index)
		var is_ascii_letter := (codepoint >= 65 and codepoint <= 90) \
				or (codepoint >= 97 and codepoint <= 122)
		var is_ascii_digit := codepoint >= 48 and codepoint <= 57
		if not is_ascii_letter and not is_ascii_digit:
			continue
		result += value.substr(index, 1)
		if result.length() >= NICKNAME_MAX_ASCII_CHARACTERS:
			break
	return result


static func truncate_chat_message(value: String) -> String:
	if value.length() <= CHAT_MESSAGE_MAX_CHARACTERS:
		return value
	return value.substr(0, CHAT_MESSAGE_MAX_CHARACTERS)
