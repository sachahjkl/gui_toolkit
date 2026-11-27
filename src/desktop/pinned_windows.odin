package tk_desktop

import "core:os"
import "core:strings"
import win "core:sys/windows"
import "../ascii"

// Whether a pin of the person's taskbar runs `exe`. Windows lets no program pin, unpin or change a pin: a program that
// changes its name says it, and the person pins the new one (src/md/features/identity-change.md).
taskbar_pinned :: proc(exe: string) -> bool {
	if exe == "" { return false }
	roaming := known_folder(win.FOLDERID_RoamingAppData)
	if roaming == "" { return false }
	dir := strings.concatenate({roaming, "\\Microsoft\\Internet Explorer\\Quick Launch\\User Pinned\\TaskBar"}, context.temp_allocator)
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return false }
	com := com_enter()
	defer com_leave(com)
	for fi in entries {
		if fi.type != .Regular || !strings.has_suffix(ascii.lower(fi.name, context.temp_allocator), ".lnk") { continue }
		target, _, read := read_shortcut(strings.concatenate({dir, "\\", fi.name}, context.temp_allocator))
		if read && same_path(target, exe) { return true }
	}
	return false
}
