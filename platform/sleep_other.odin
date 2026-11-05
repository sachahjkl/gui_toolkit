#+build !windows
package platform

import "core:time"

// A wait to the millisecond and under (nanosleep is precise here).
precise_sleep :: proc(d: time.Duration) { time.sleep(d) }
