package tk_process

// Other processes (Linux: other_linux.odin; elsewhere every call answers .Unsupported): a signal and a priority sent to
// one process, named by its pid and its start time so that a pid given again to a new process is not touched.
//
//	process_start_time  when a process started (Linux: clock ticks after the boot, field 22 of /proc/<pid>/stat)
//	signal_process      a signal, if the pid still names the process that started then
//	set_priority        a nice value for every thread of that process
//	affinity            the logical processors the process may run on (its main thread's)
//	set_affinity        the logical processors every thread of that process may run on

import "core:math/bits"
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
	Quit,        // SIGQUIT: ends it, with a core dump where the system keeps them
	User1,       // SIGUSR1: what the program makes of it (many read their configuration again)
	User2,       // SIGUSR2
}

// What became of an act on another process.
Act_Result :: enum u8 {
	Done,
	Gone,          // the process ended, or its pid names another process now
	Denied,        // the process is another user's, or a higher priority needs privileges
	Failed,        // another error: the errno returned says which
	Unsupported,   // this system has no such call here
}

// The logical processors a process may run on: bit `n` of the words is processor `n` (0 to CPU_SET_MAX - 1).
CPU_SET_MAX :: 1024

Cpu_Set :: struct { words: [CPU_SET_MAX / 64]u64 }

cpu_set_has :: proc(s: Cpu_Set, cpu: int) -> bool {
	if cpu < 0 || cpu >= CPU_SET_MAX { return false }
	return s.words[cpu / 64] & (u64(1) << uint(cpu % 64)) != 0
}

// Adds processor `cpu` to the set, or takes it away (`on` false).
cpu_set_put :: proc(s: ^Cpu_Set, cpu: int, on := true) {
	if cpu < 0 || cpu >= CPU_SET_MAX { return }
	bit := u64(1) << uint(cpu % 64)
	if on { s.words[cpu / 64] |= bit } else { s.words[cpu / 64] &~= bit }
}

// The processors in the set.
cpu_set_count :: proc(s: Cpu_Set) -> (n: int) {
	for w in s.words { n += int(bits.count_ones(w)) }
	return
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
