// The log package: lines written off the thread that logs, in their order, rotated past a size; the last lines for a crash report.
//   odin test tests/log -vet
package log_test

import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import tk_log "../../src/log"
import "../../src/testkit"

LINE_TEXT_AT :: len("2026-11-13T17:03:00.123Z INFO  ")

file_lines :: proc(path: string) -> []string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return nil }
	return strings.split_lines(strings.trim_suffix(string(data), "\n"), context.temp_allocator)
}

// The text of a line, after its time and level.
text_of :: proc(line: string) -> string { return len(line) > LINE_TEXT_AT ? line[LINE_TEXT_AT:] : "" }

@(test)
a_log_rotates_past_its_size :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t, "log_rotate")
	MAX :: 400
	logger := tk_log.install({program = "rot", dir = dir, max_bytes = MAX, keep = 2})
	{
		context.logger = logger
		for i in 0 ..< 60 { log.infof("line %03d", i) }
	}
	tk_log.flush(logger)
	path := tk_log.path(logger)
	tk_log.close(logger)

	older := [3]string{fmt.tprintf("%s.1", path), fmt.tprintf("%s.2", path), fmt.tprintf("%s.3", path)}
	testing.expect(t, os.exists(path) && os.exists(older[0]) && os.exists(older[1]), "the file and two older ones")
	testing.expect(t, !os.exists(older[2]), "no more than kept")
	all := make([dynamic]string, context.temp_allocator)
	for name in ([3]string{older[1], older[0], path}) {
		lines := file_lines(name)
		size := 0
		for l in lines { size += len(l) + 1 }
		testing.expectf(t, size <= MAX, "%s holds %d bytes", name, size)
		append(&all, ..lines)
	}
	// the files, oldest first, are the last lines in their order
	if !testing.expect(t, len(all) > 0) { return }
	last := len(all) - 1
	for l, i in all { testing.expect_value(t, text_of(l), fmt.tprintf("line %03d", 60 - 1 - last + i)) }
}

@(private = "file")
Writers :: struct {
	logger: log.Logger,
	start:  sync.Barrier,
}

// Lines logged by several threads at once: each whole, each thread's in its order, none lost; the file and the tail agree.
@(test)
lines_keep_their_order_from_several_threads :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t, "log_order")
	THREADS :: 8
	EACH :: 200
	w := Writers{logger = tk_log.install({program = "order", dir = dir, max_bytes = 1 << 24})}
	sync.barrier_init(&w.start, THREADS)
	threads: [THREADS]^thread.Thread
	for k in 0 ..< THREADS {
		threads[k] = thread.create_and_start_with_poly_data2(&w, k, proc(writers: ^Writers, index: int) {
			context.logger = writers.logger
			sync.barrier_wait(&writers.start)
			for n in 0 ..< EACH { log.infof("t%d %d", index, n) }
		})
	}
	for th in threads { thread.join(th); thread.destroy(th) }
	tk_log.flush(w.logger)
	tail: [tk_log.TAIL_BYTES]u8
	tail_len := tk_log.tail(w.logger.data, tail[:])
	path := tk_log.path(w.logger)
	tk_log.close(w.logger)

	lines := file_lines(path)
	testing.expect_value(t, len(lines), THREADS * EACH)
	next: [THREADS]int
	for l in lines {
		parts := strings.fields(text_of(l), context.temp_allocator)
		if !testing.expectf(t, len(parts) == 2 && strings.has_prefix(parts[0], "t"), "a whole line: %q", l) { return }
		k, ok1 := strconv.parse_int(parts[0][1:])
		n, ok2 := strconv.parse_int(parts[1])
		if !testing.expect(t, ok1 && ok2 && k >= 0 && k < THREADS) { return }
		testing.expectf(t, n == next[k], "thread %d: line %d after %d", k, n, next[k] - 1)
		next[k] = n + 1
	}
	// the ring gives the same last lines as the file, in the same order
	got := strings.split_lines(strings.trim_suffix(string(tail[:tail_len]), "\n"), context.temp_allocator)
	testing.expect_value(t, len(got), tk_log.TAIL_LINES_DEFAULT)
	for g, i in got { testing.expect_value(t, g, lines[len(lines) - len(got) + i]) }
}

// What a crash report takes from a small buffer: whole lines only, the newest.
@(test)
the_tail_is_whole_lines :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t, "log_tail")
	logger := tk_log.install({program = "tail", dir = dir, tail_lines = 3})
	{
		context.logger = logger
		for i in 0 ..< 10 { log.warnf("warning %d", i) }
	}
	full: [1024]u8
	n := tk_log.tail(logger.data, full[:])
	lines := strings.split_lines(strings.trim_suffix(string(full[:n]), "\n"), context.temp_allocator)
	testing.expect_value(t, len(lines), 3)
	if len(lines) == 3 { testing.expect_value(t, text_of(lines[2]), "warning 9") }
	small: [50]u8   // (less than two lines)
	n = tk_log.tail(logger.data, small[:])
	text := string(small[:n])
	testing.expect(t, n == 0 || (strings.has_suffix(text, "\n") && strings.count(text, "\n") == 1 && strings.contains(text, "warning 9")), text)
	tk_log.close(logger)
}

// The lowest level: below it nothing is written; a line logged with a line end inside stays one entry.
@(test)
a_level_below_the_lowest_is_not_written :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t, "log_level")
	logger := tk_log.install({program = "level", dir = dir, level = .Warning})
	{
		context.logger = logger
		log.debug("not this")
		log.info("nor this")
		log.error("this\nand its second line")
	}
	tk_log.flush(logger)
	path := tk_log.path(logger)
	tk_log.close(logger)
	lines := file_lines(path)
	if !testing.expect_value(t, len(lines), 2) { return }
	testing.expect(t, strings.contains(lines[0], " ERROR this"), lines[0])
	testing.expect_value(t, lines[1], "    and its second line")
}

@(test)
the_default_folder_is_the_programs_state :: proc(t: ^testing.T) {
	dir := tk_log.default_dir("gt_log_test", context.temp_allocator)
	testing.expect(t, dir == "" || (strings.has_suffix(dir, "/logs") && strings.contains(dir, "gt_log_test")), dir)
}
