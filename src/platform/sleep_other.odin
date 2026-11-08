#+build !windows
#+build !linux
package platform

import "core:time"

// A wait under the system's tick. Nothing is read meanwhile: with a window, wait_slot.
precise_sleep :: proc(d: time.Duration) { time.sleep(d) }

// The wait of a frame's slot: until `d` passed, the window's input taken as it arrives (time-stamped, kept for the next poll_events).
// A key or a button ends it: the frame answers them now. A pointer that moves does not, nor does the wheel: they come a thousand
// times a second, and the slot is there to hold them back. An offscreen window does not wait: nothing shows its frames.
wait_slot :: proc(w: ^Window, d: time.Duration) { precise_sleep(d) }
