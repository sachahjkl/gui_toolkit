#+build windows
package platform

import win "core:sys/windows"

// RegisterHotKey: WM_HOTKEY reaches the window's procedure with the id (window_proc makes it a Hotkey event).
// MOD_NOREPEAT: a held combination is one event.
hotkey_register :: proc(w: ^Window, id: int, hk: Hotkey) -> bool {
	if w == nil || w.hwnd == nil { return false }
	vk := vk_of_key(hk.key)
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
@(private = "file") MOD_ALT      :: 0x0001
@(private = "file") MOD_CONTROL  :: 0x0002
@(private = "file") MOD_SHIFT    :: 0x0004
@(private = "file") MOD_WIN      :: 0x0008
@(private = "file") MOD_NOREPEAT :: 0x4000

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
