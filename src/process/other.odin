package tk_process

// Other processes (Linux: other_linux.odin; elsewhere every call answers .Unsupported): a signal and a priority sent to
// one process, named by its pid and its start time so that a pid given again to a new process is not touched.
//
//	process_start_time  when a process started (Linux: clock ticks after the boot, field 22 of /proc/<pid>/stat)
//	signal_process      a signal, if the pid still names the process that started then
//	set_priority        a nice value for every thread of that process

import "core:strconv"
import "core:strings"

// The signals a program sends to another process.
Signal :: enum u8 {
	Terminate,   // asks it to end (SIGTERM)
	Kill,        // ends it at once (SIGKILL)
	Stop,        // suspends it (SIGSTOP)
	Continue,    // resumes it (SIGCONT)
	Hangup,      // SIGHUP
	Interrupt,   // SIGINT
}

// What became of an act on another process.
Act_Result :: enum u8 {
	Done,
	Gone,          // the process ended, or its pid names another process now
	Denied,        // the process is another user's, or a higher priority needs privileges
	Failed,        // another error: the errno returned says which
	Unsupported,   // this system has no such call here
}

// The start time of /proc/<pid>/stat's text: the 22nd field. The command name (the 2nd) is between the first '(' and
// the last ')' and may hold spaces and parentheses.
parse_start_time :: proc(stat: string) -> (start: u64, ok: bool) {
	close := strings.last_index_byte(stat, ')')
	if close < 0 { return }
	rest := stat[close + 1:]
	field := 3   // (the state, after the name)
	for word in strings.fields_iterator(&rest) {
		if field == 22 {
			v, parsed := strconv.parse_u64(word, 10)
			return v, parsed
		}
		field += 1
	}
	return
}
