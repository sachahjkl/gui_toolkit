#+build windows
package platform

import win "core:sys/windows"

// RegisterHotKey: WM_HOTKEY reaches the window's procedure with the id (window_proc makes it a Hotkey event).
// MOD_NOREPEAT: a held combination is one event.
hotkey_register :: proc(w: ^Window, id: int, hk: Hotkey) -> bool {
	if w == nil || w.hwnd == nil { return false }
	hk := hk
	vk := vk_of(&hk)
	if vk == 0 { return false }
	mods := u32(MOD_NOREPEAT)
	if .Ctrl in hk.mods  { mods |= MOD_CONTROL }
	if .Shift in hk.mods { mods |= MOD_SHIFT }
	if .Alt in hk.mods   { mods |= MOD_ALT }
	if hk.super          { mods |= MOD_WIN }
	return bool(win.RegisterHotKey(w.hwnd, i32(id), mods, vk))
}

hotkey_unregister :: proc(w: ^Window, id: int) {
	if w != nil && w.hwnd != nil { win.UnregisterHotKey(w.hwnd, i32(id)) }
}

// (winuser.h)
@(private = "file") KEYEVENTF_KEYUP :: 0x0002
@(private = "file") MOD_ALT      :: 0x0001
@(private = "file") MOD_CONTROL  :: 0x0002
@(private = "file") MOD_SHIFT    :: 0x0004
@(private = "file") MOD_WIN      :: 0x0008
@(private = "file") MOD_NOREPEAT :: 0x4000

// SendInput: the modifiers down, the key down and up, the modifiers up, in one batch (no other input between them).
send_hotkey :: proc(w: ^Window, hk: Hotkey) -> bool {
	hk := hk
	vk := vk_of(&hk)
	if vk == 0 { return false }
	mods := make([dynamic]u16, context.temp_allocator)
	if .Ctrl in hk.mods  { append(&mods, u16(win.VK_CONTROL)) }
	if .Shift in hk.mods { append(&mods, u16(win.VK_SHIFT)) }
	if .Alt in hk.mods   { append(&mods, u16(win.VK_MENU)) }
	if hk.super          { append(&mods, u16(win.VK_LWIN)) }
	inputs := make([dynamic]win.INPUT, context.temp_allocator)
	key :: proc(vk: u16, up: bool) -> win.INPUT {
		i := win.INPUT{type = .KEYBOARD}
		i.ki.wVk = vk
		if up { i.ki.dwFlags = KEYEVENTF_KEYUP }
		return i
	}
	for m in mods { append(&inputs, key(m, false)) }
	append(&inputs, key(u16(vk), false), key(u16(vk), true))
	#reverse for m in mods { append(&inputs, key(m, true)) }
	return win.SendInput(u32(len(inputs)), raw_data(inputs), size_of(win.INPUT)) == u32(len(inputs))
}

// The virtual key of a hotkey's key: by its name, or the one that types its character on the user's layout
// (VkKeyScanW), whose modifiers join the hotkey's (a character typed with Shift: Shift too). 0: none.
@(private = "file")
vk_of :: proc(hk: ^Hotkey) -> u32 {
	if hk.key != .None || hk.char == 0 { return vk_of_key(hk.key) }
	if hk.char > 0xFFFF { return 0 }
	scan := VkKeyScanW(u16(hk.char))
	if scan == -1 { return 0 }
	shift := u8(u16(scan) >> 8)
	if shift & 1 != 0 { hk.mods += {.Shift} }
	if shift & 2 != 0 { hk.mods += {.Ctrl} }
	if shift & 4 != 0 { hk.mods += {.Alt} }
	return u32(u16(scan) & 0xFF)
}

foreign import user32_vk "system:User32.lib"
@(default_calling_convention = "system", private = "file")
foreign user32_vk { VkKeyScanW :: proc(ch: u16) -> i16 --- }

// The virtual key of a key a hotkey can name (hotkey.odin), 0 for the others.
@(private = "file")
vk_of_key :: proc(k: Key) -> u32 {
	#partial switch k {
	case .A ..= .Z:   return u32('A' + int(k - .A))
	case .N0 ..= .N9: return u32('0' + int(k - .N0))
	case .F1 ..= .F12: return u32(win.VK_F1 + int(k - .F1))
	case .Space:     return win.VK_SPACE
	case .Tab:       return win.VK_TAB
	case .Return:    return win.VK_RETURN
	case .Escape:    return win.VK_ESCAPE
	case .Insert:    return win.VK_INSERT
	case .Delete:    return win.VK_DELETE
	case .Home:      return win.VK_HOME
	case .End:       return win.VK_END
	case .Page_Up:   return win.VK_PRIOR
	case .Page_Down: return win.VK_NEXT
	case .Left:      return win.VK_LEFT
	case .Right:     return win.VK_RIGHT
	case .Up:        return win.VK_UP
	case .Down:      return win.VK_DOWN
	}
	return 0
}
