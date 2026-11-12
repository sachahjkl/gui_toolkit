// The notices package: a log of what the user missed, one open entry per key, a history of what was acknowledged, its
// groups kept between changes, its file through gt:store.
//   odin test tests/notices -vet
package notices_test

import "core:fmt"
import "core:os"
import "core:testing"
import "../../src/fsx"
import notices "../../src/notices"

recount :: proc(log: ^notices.Log) -> (c: [notices.State]int) {
	for e in log.entries { c[e.state] += 1 }
	return
}

// A key put twice while open is one entry counted twice; acknowledged, a put of it is a new entry, the old one in the history.
@(test)
a_key_open_is_one_entry :: proc(t: ^testing.T) {
	log: notices.Log
	notices.open(&log, "")
	defer notices.close(&log)
	e, fresh := notices.put(&log, {key = "run:a", group = "a", title = "Done", at = 1})
	testing.expect(t, fresh, "the first put is a new entry")
	notices.seen_all(&log)
	testing.expect_value(t, e.state, notices.State.Seen)
	e, fresh = notices.put(&log, {key = "run:a", group = "a", title = "Done again", at = 2})
	testing.expect(t, !fresh, "the second updates it")
	testing.expect_value(t, len(log.entries), 1)
	testing.expect_value(t, e.count, 2)
	testing.expect_value(t, e.state, notices.State.New)
	testing.expect_value(t, e.title, "Done again")

	testing.expect(t, notices.acknowledge(&log, "run:a") != nil)
	e, fresh = notices.put(&log, {key = "run:a", group = "a", title = "Third", at = 3})
	testing.expect(t, fresh, "acknowledged, the key opens a new entry")
	testing.expect_value(t, len(log.entries), 2)
	testing.expect_value(t, log.entries[0].state, notices.State.Acknowledged)
	testing.expect_value(t, e.count, 1)
	testing.expect(t, notices.find(&log, "run:a") == e, "find gives the open entry")
	testing.expect_value(t, log.counts, recount(&log))
}

// The machine of the states, alone.
@(test)
the_states_step :: proc(t: ^testing.T) {
	testing.expect_value(t, notices.step(.Seen, .Put), notices.State.New)
	testing.expect_value(t, notices.step(.New, .Seen), notices.State.Seen)
	testing.expect_value(t, notices.step(.Acknowledged, .Seen), notices.State.Acknowledged)
	testing.expect_value(t, notices.step(.New, .Acknowledge), notices.State.Acknowledged)
}

// Whatever the order of the calls, the counts are a recount, one key has at most one open entry, the history stays in its cap.
@(test)
the_counts_are_a_recount :: proc(t: ^testing.T) {
	log: notices.Log
	notices.open(&log, "", cap = 40)
	defer notices.close(&log)
	seed: u64 = 0x9E3779B97F4A7C15
	next :: proc(x: ^u64) -> u64 {   // (xorshift64: the same sequence on every system)
		x^ ~= x^ << 13
		x^ ~= x^ >> 7
		x^ ~= x^ << 17
		return x^
	}
	for i in 0 ..< 5000 {
		k := fmt.tprintf("k%d", next(&seed) % 30)
		g := fmt.tprintf("g%d", next(&seed) % 5)
		switch next(&seed) % 10 {
		case 0 ..= 4: notices.put(&log, {key = k, group = g, at = i64(i)})
		case 5:       notices.seen_all(&log)
		case 6, 7:    notices.acknowledge(&log, k)
		case 8:       notices.remove(&log, k)
		case 9:       if i % 3 == 0 { notices.acknowledge_group(&log, g) } else { notices.remove_group(&log, g) }
		}
		if log.counts != recount(&log) {
			testing.expectf(t, false, "step %d: counts %v, a recount %v", i, log.counts, recount(&log))
			return
		}
	}
	open := map[string]int{}
	defer delete(open)
	for e in log.entries { if e.state != .Acknowledged { open[e.key] += 1 } }
	for _, n in open { testing.expect_value(t, n, 1) }
	testing.expect(t, log.counts[.Acknowledged] <= 40 || len(log.entries) <= 40, "the history stays in its cap")
}

// Past the cap the oldest acknowledged goes; an open entry never does.
@(test)
past_the_cap_the_oldest_history_goes :: proc(t: ^testing.T) {
	log: notices.Log
	notices.open(&log, "", cap = 200)
	defer notices.close(&log)
	for i in 0 ..< 100 {
		notices.put(&log, {key = fmt.tprintf("old%d", i), at = i64(i)})
		notices.acknowledge(&log, fmt.tprintf("old%d", i))
	}
	for i in 0 ..< 50 { notices.put(&log, {key = fmt.tprintf("seen%d", i), at = i64(100 + i)}) }
	notices.seen_all(&log)
	for i in 0 ..< 50 { notices.put(&log, {key = fmt.tprintf("new%d", i), at = i64(150 + i)}) }
	testing.expect_value(t, len(log.entries), 200)
	notices.put(&log, {key = "one more", at = 300})
	testing.expect_value(t, len(log.entries), 200)
	testing.expect(t, notices.find(&log, "old0") == nil, "the oldest acknowledged went")
	testing.expect(t, notices.find(&log, "old1") != nil, "only it")
	testing.expect_value(t, log.counts[.Seen], 50)
	testing.expect_value(t, log.counts[.New], 51)
	testing.expect_value(t, log.counts[.Acknowledged], 99)

	// a log of open entries only goes past its cap: nothing open is dropped
	small: notices.Log
	notices.open(&small, "", cap = 2)
	defer notices.close(&small)
	for i in 0 ..< 3 { notices.put(&small, {key = fmt.tprintf("w%d", i)}) }
	testing.expect_value(t, len(small.entries), 3)
}

// The groups are made once per change: two calls with nothing between give the same slice; a put makes them again.
@(test)
the_groups_are_kept_between_changes :: proc(t: ^testing.T) {
	log: notices.Log
	notices.open(&log, "")
	defer notices.close(&log)
	notices.put(&log, {key = "a1", group = "a", at = 10})
	notices.put(&log, {key = "b1", group = "b", at = 20})
	notices.put(&log, {key = "a2", group = "a", at = 30})
	notices.acknowledge(&log, "b1")

	g := notices.groups(&log, false)
	made := log.groups_made
	again := notices.groups(&log, false)
	testing.expect(t, raw_data(g) == raw_data(again) && len(g) == len(again), "the same slice")
	testing.expect_value(t, log.groups_made, made)
	testing.expect_value(t, len(g), 1)
	testing.expect_value(t, g[0].group, "a")
	testing.expect_value(t, g[0].open, 2)
	testing.expect_value(t, g[0].entries[0].key, "a2")
	testing.expect_value(t, g[0].newest, 30)

	all := notices.groups(&log, true)
	testing.expect_value(t, len(all), 2)
	testing.expect_value(t, all[0].group, "a")
	testing.expect_value(t, all[1].group, "b")
	testing.expect_value(t, all[1].open, 0)

	notices.put(&log, {key = "b2", group = "b", at = 40})
	made = log.groups_made
	g = notices.groups(&log, false)
	testing.expect_value(t, log.groups_made, made + 1)
	testing.expect_value(t, len(g), 2)
	testing.expect_value(t, g[0].group, "b")
}

// Closed and opened again, the log has its entries: their state, count, text (tabs and line breaks too) and time.
@(test)
the_log_survives_a_restart :: proc(t: ^testing.T) {
	root := fmt.tprintf("%s/gui_toolkit_notices_%d", fsx.temp_dir(context.temp_allocator), os.get_pid())
	fsx.remove_tree(root)
	defer fsx.remove_tree(root)
	path := fmt.tprintf("%s/notices.txt", root)
	TEXT :: "line one\nline\ttwo \\ three"
	{
		log: notices.Log
		testing.expect(t, !notices.open(&log, path), "no file yet")
		notices.put(&log, {key = "q:1", group = "ses 1", title = "Question", text = TEXT, kind = 2, outcome = 1, at = 1_700_000_000_123, user = 7})
		notices.put(&log, {key = "q:1", group = "ses 1", title = "Question", text = TEXT, kind = 2, outcome = 1, at = 1_700_000_000_456, user = 7})
		notices.put(&log, {key = "run:1", group = "ses 1", title = "Done", at = 5})
		notices.seen_all(&log)
		notices.put(&log, {key = "run:2", group = "ses 2", title = "Done", at = 6})
		notices.acknowledge(&log, "run:1")
		notices.flush(&log)
		notices.close(&log)
	}
	log: notices.Log
	testing.expect(t, notices.open(&log, path), "the file is there")
	defer notices.close(&log)
	testing.expect_value(t, len(log.entries), 3)
	q := notices.find(&log, "q:1")
	testing.expect(t, q != nil)
	if q == nil { return }
	testing.expect_value(t, q.state, notices.State.Seen)
	testing.expect_value(t, q.count, 2)
	testing.expect_value(t, q.text, TEXT)
	testing.expect_value(t, q.at, 1_700_000_000_456)
	testing.expect_value(t, q.group, "ses 1")
	testing.expect_value(t, q.kind, 2)
	testing.expect_value(t, q.outcome, 1)
	testing.expect_value(t, q.user, 7)
	testing.expect_value(t, notices.find(&log, "run:1").state, notices.State.Acknowledged)
	testing.expect_value(t, notices.find(&log, "run:2").state, notices.State.New)
	testing.expect_value(t, log.counts, recount(&log))
	_, fresh := notices.put(&log, {key = "q:1", at = 9})
	testing.expect(t, !fresh, "an open entry read back is still the key's open one")
	e, _ := notices.put(&log, {key = "new", at = 10})
	testing.expect(t, e.id > q.id, "ids go on after those read")
}
