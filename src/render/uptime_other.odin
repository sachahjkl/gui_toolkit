#+build !windows
package render

// Milliseconds since this process started (render trace, first-present timing). No cheap, portable process-start clock
// here, so the trace line is skipped (a negative value tells the caller to): the Windows path reports it.
@(private)
process_uptime_ms :: proc() -> f64 { return -1 }
