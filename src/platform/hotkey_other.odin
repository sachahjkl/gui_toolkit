#+build !windows
package platform

// No hotkeys here (hotkey.odin): on Linux the compositor binds shortcuts to commands.

hotkey_register :: proc(w: ^Window, id: int, hk: Hotkey) -> bool { return false }
hotkey_unregister :: proc(w: ^Window, id: int) {}
