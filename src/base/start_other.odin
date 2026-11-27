#+build !linux
#+build !windows
package gt_base

// No clock of the process's start here: the start clock begins before main (start_init).
@(private)
process_age_ns :: proc "contextless" () -> i64 { return 0 }
