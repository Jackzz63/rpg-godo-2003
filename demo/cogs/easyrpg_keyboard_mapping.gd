extends RefCounted

# Stable Input::Keys::InputKey values from ynoengine/src/keys.h. This bridge
# deliberately mirrors YNO/EasyRPG's SDL scancode conversion instead of mapping
# keys directly to game actions.
const _BACKSPACE := 1
const _TAB := 2
const _CLEAR := 3
const _RETURN := 4
const _PAUSE := 5
const _ESCAPE := 6
const _SPACE := 7
const _PAGE_UP := 8
const _PAGE_DOWN := 9
const _END := 10
const _HOME := 11
const _LEFT := 12
const _UP := 13
const _RIGHT := 14
const _DOWN := 15
const _PRINT_SCREEN := 16
const _INSERT := 17
const _DELETE := 18
const _LEFT_SHIFT := 20
const _RIGHT_SHIFT := 21
const _LEFT_CTRL := 23
const _RIGHT_CTRL := 24
const _LEFT_ALT := 26
const _RIGHT_ALT := 27
const _N0 := 28
const _A := 38
const _MENU := 66
const _KP0 := 67
const _KP_MULTIPLY := 77
const _KP_ADD := 78
const _KP_SUBTRACT := 79
const _KP_PERIOD := 80
const _KP_DIVIDE := 81
const _COMMA := 82
const _PERIOD := 83
const _SLASH := 84
const _F1 := 85
const _CAPS_LOCK := 97
const _NUM_LOCK := 98
const _SCROLL_LOCK := 99
const _AC_BACK := 100
const _LEFT_BRACKET := 102
const _RIGHT_BRACKET := 103
const _BACKSLASH := 104
const _SEMICOLON := 105
const _APOSTROPHE := 106


# Game input follows the physical position on a US QWERTY keyboard. Synthetic
# events can omit physical_keycode, so keycode remains a compatibility fallback.
static func event_keycode(event: InputEventKey) -> Key:
	if event.physical_keycode != KEY_NONE:
		return event.physical_keycode
	return event.keycode


static func event_source(event: InputEventKey) -> StringName:
	return StringName(
		"keyboard:%d:%d" % [int(event_keycode(event)), int(event.location)]
	)


static func to_easyrpg_key(
		keycode: Key,
		location: KeyLocation = KEY_LOCATION_UNSPECIFIED) -> int:
	if keycode >= KEY_0 and keycode <= KEY_9:
		return _N0 + int(keycode) - int(KEY_0)
	if keycode >= KEY_A and keycode <= KEY_Z:
		return _A + int(keycode) - int(KEY_A)
	if keycode >= KEY_KP_0 and keycode <= KEY_KP_9:
		return _KP0 + int(keycode) - int(KEY_KP_0)
	if keycode >= KEY_F1 and keycode <= KEY_F12:
		return _F1 + int(keycode) - int(KEY_F1)

	match keycode:
		KEY_BACKSPACE:     return _BACKSPACE
		KEY_TAB:           return _TAB
		KEY_CLEAR:         return _CLEAR
		KEY_ENTER:         return _RETURN
		KEY_KP_ENTER:      return _RETURN
		KEY_PAUSE:         return _PAUSE
		KEY_ESCAPE:        return _ESCAPE
		KEY_SPACE:         return _SPACE
		KEY_PAGEUP:        return _PAGE_UP
		KEY_PAGEDOWN:      return _PAGE_DOWN
		KEY_END:           return _END
		KEY_HOME:          return _HOME
		KEY_LEFT:          return _LEFT
		KEY_UP:            return _UP
		KEY_RIGHT:         return _RIGHT
		KEY_DOWN:          return _DOWN
		KEY_PRINT:         return _PRINT_SCREEN
		KEY_INSERT:        return _INSERT
		KEY_DELETE:        return _DELETE
		KEY_SHIFT:
			if location == KEY_LOCATION_RIGHT:
				return _RIGHT_SHIFT
			return _LEFT_SHIFT
		KEY_CTRL:
			if location == KEY_LOCATION_RIGHT:
				return _RIGHT_CTRL
			return _LEFT_CTRL
		KEY_ALT:
			if location == KEY_LOCATION_RIGHT:
				return _RIGHT_ALT
			return _LEFT_ALT
		KEY_MENU:          return _MENU
		KEY_KP_MULTIPLY:   return _KP_MULTIPLY
		KEY_KP_ADD:        return _KP_ADD
		KEY_KP_SUBTRACT:   return _KP_SUBTRACT
		KEY_KP_PERIOD:     return _KP_PERIOD
		KEY_KP_DIVIDE:     return _KP_DIVIDE
		KEY_COMMA:         return _COMMA
		KEY_PERIOD:        return _PERIOD
		KEY_SLASH:         return _SLASH
		KEY_CAPSLOCK:      return _CAPS_LOCK
		KEY_NUMLOCK:       return _NUM_LOCK
		KEY_SCROLLLOCK:    return _SCROLL_LOCK
		KEY_BACK:          return _AC_BACK
		# SDL's legacy Select scancode has no Godot 4 Key equivalent; Godot's
		# Windows backend intentionally leaves VK_SELECT unmapped as well.
		KEY_BRACKETLEFT:   return _LEFT_BRACKET
		KEY_BRACKETRIGHT:  return _RIGHT_BRACKET
		KEY_BACKSLASH:     return _BACKSLASH
		KEY_SEMICOLON:     return _SEMICOLON
		KEY_APOSTROPHE:    return _APOSTROPHE
		_:                 return -1
