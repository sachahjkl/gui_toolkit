#+build !linux
package tk_process

// (no count of the open handles here: Windows' count moves with the system's own handles)
@(private) open_handles :: proc() -> int { return -1 }
