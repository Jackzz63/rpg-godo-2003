extends RefCounted

# Stable keyboard-side Input::Keys values used to reproduce YNO/EasyRPG's
# default controller actions without depending on platform-conditional JOY_*
# enum offsets.
const KEY_LEFT := 12
const KEY_UP := 13
const KEY_RIGHT := 14
const KEY_DOWN := 15
const KEY_LEFT_SHIFT := 20
const KEY_LEFT_CTRL := 23
const KEY_N0 := 28
const KEY_N1 := 29
const KEY_N2 := 30
const KEY_N3 := 31
const KEY_N4 := 32
const KEY_N5 := 33
const KEY_N6 := 34
const KEY_N7 := 35
const KEY_N8 := 36
const KEY_N9 := 37
const KEY_F := 43
const KEY_G := 44
const KEY_X := 61
const KEY_Z := 63
const KEY_F1 := 85
const KEY_F2 := 86
const KEY_F9 := 93
const KEY_F10 := 94
const KEY_F12 := 96
const KEY_LEFT_BRACKET := 102
const KEY_RIGHT_BRACKET := 103
const KEY_SEMICOLON := 105
const KEY_APOSTROPHE := 106

const TRIGGER_SOFT_THRESHOLD := 0.2
const TRIGGER_FULL_THRESHOLD := 0.9

const _BUTTON_TO_EASYRPG_KEY := {
	JOY_BUTTON_A: KEY_Z,
	JOY_BUTTON_B: KEY_X,
	JOY_BUTTON_X: KEY_X,
	JOY_BUTTON_Y: KEY_LEFT_SHIFT,
	JOY_BUTTON_BACK: KEY_F12,
	JOY_BUTTON_START: KEY_F1,
	JOY_BUTTON_LEFT_STICK: KEY_N0,
	JOY_BUTTON_RIGHT_STICK: KEY_N5,
	JOY_BUTTON_LEFT_SHOULDER: KEY_F10,
	JOY_BUTTON_RIGHT_SHOULDER: KEY_F2,
	JOY_BUTTON_DPAD_UP: KEY_UP,
	JOY_BUTTON_DPAD_DOWN: KEY_DOWN,
	JOY_BUTTON_DPAD_LEFT: KEY_LEFT,
	JOY_BUTTON_DPAD_RIGHT: KEY_RIGHT,
	# Godot's standard PADDLE1..4 order matches SDL's right 1/right 2/
	# left 1/left 2 order used by YNO Engine.
	JOY_BUTTON_PADDLE1: KEY_RIGHT_BRACKET,
	JOY_BUTTON_PADDLE2: KEY_APOSTROPHE,
	JOY_BUTTON_PADDLE3: KEY_LEFT_BRACKET,
	JOY_BUTTON_PADDLE4: KEY_SEMICOLON,
}


static func to_easyrpg_key(button_index: JoyButton) -> int:
	return int(_BUTTON_TO_EASYRPG_KEY.get(button_index, -1))


# YNO treats the right stick as an eight-way numeric keypad. The integer angle
# boundaries intentionally mirror Input::Source::UpdateGamepad().
static func right_stick_to_easyrpg_key(x: float, y: float, threshold: float) -> int:
	if maxf(absf(x), absf(y)) <= threshold:
		return -1

	var angle := int(rad_to_deg(atan2(y, x)))
	if angle >= -22 and angle <= 22:
		return KEY_N6
	if angle >= 23 and angle <= 67:
		return KEY_N3
	if angle >= 68 and angle <= 112:
		return KEY_N2
	if angle >= 113 and angle <= 157:
		return KEY_N1
	if angle >= 158 or angle <= -158:
		return KEY_N4
	if angle >= -157 and angle <= -113:
		return KEY_N7
	if angle >= -112 and angle <= -68:
		return KEY_N8
	if angle >= -67 and angle <= -23:
		return KEY_N9
	return -1


static func trigger_soft_key(axis: JoyAxis) -> int:
	match axis:
		JOY_AXIS_TRIGGER_LEFT:  return KEY_LEFT_CTRL
		JOY_AXIS_TRIGGER_RIGHT: return KEY_F
		_:                      return -1


static func trigger_full_key(axis: JoyAxis) -> int:
	match axis:
		JOY_AXIS_TRIGGER_LEFT:  return KEY_F9
		JOY_AXIS_TRIGGER_RIGHT: return KEY_G
		_:                      return -1
