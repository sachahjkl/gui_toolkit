#+build !linux
package process_start_test

// (no count of the open handles here: Windows' count moves with the system's own handles)
@(private) open_handles :: proc() -> int { return -1 }
