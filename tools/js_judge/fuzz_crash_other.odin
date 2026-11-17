#+build !windows
package jsrt_judge

import js "../../src/js"

// No crash report off Windows: a crash ends the replay with the system's own message.
fuzz_crash_report_install :: proc(rt: ^js.Runtime) {}
