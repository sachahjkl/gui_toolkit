#+build linux
package platform

// X keysyms (the values libxkbcommon returns on both backends) to our Key enum. The names follow keysymdef.h; the
// letter and digit ranges map straight, the rest by their symbol. Only the keys our Key enum names are mapped; anything
// else is Key.None (its text, if any, still comes through a Text event).

@(private)
key_from_keysym :: proc(sym: Xkb_Keysym) -> Key {
	s := u32(sym)
	switch s {
	case 0x061 ..= 0x07a: return Key(int(Key.A) + int(s - 0x061))   // a..z
	case 0x041 ..= 0x05a: return Key(int(Key.A) + int(s - 0x041))   // A..Z
	case 0x030 ..= 0x039: return Key(int(Key.N0) + int(s - 0x030))  // 0..9
	case 0xffbe ..= 0xffc9: return Key(int(Key.F1) + int(s - 0xffbe)) // F1..F12
	case 0xff1b: return .Escape
	case 0xff0d, 0xff8d: return .Return       // Return, KP_Enter
	case 0xff09: return .Tab
	case 0x020:  return .Space
	case 0xff08: return .Backspace
	case 0xffff: return .Delete
	case 0xff63: return .Insert
	case 0xff51: return .Left
	case 0xff53: return .Right
	case 0xff52: return .Up
	case 0xff54: return .Down
	case 0xff50: return .Home
	case 0xff57: return .End
	case 0xff55: return .Page_Up
	case 0xff56: return .Page_Down
	case 0x02c:  return .Comma
	case 0x02e:  return .Period
	case 0x02f:  return .Slash
	case 0x02d:  return .Minus
	case 0x03d:  return .Equal
	case 0xffe1, 0xffe2: return .Shift        // Shift_L / Shift_R
	case 0xffe3, 0xffe4: return .Ctrl         // Control_L / Control_R
	case 0xffe9, 0xffea, 0xfe03: return .Alt  // Alt_L / Alt_R / ISO_Level3_Shift
	case 0xff67: return .Menu
	case 0xffab: return .Num_Add              // KP_Add
	case 0xffad: return .Num_Subtract         // KP_Subtract
	case 0xffb0 ..= 0xffb9: return Key(int(Key.N0) + int(s - 0xffb0))  // KP_0..KP_9
	}
	return .None
}
