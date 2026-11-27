#+build !windows
package tk_desktop

// No taskbar here keeps a pin by a program's file: a dock pins an entry by its id (src/md/features/identity-change.md).
taskbar_pinned :: proc(exe: string) -> bool { return false }
