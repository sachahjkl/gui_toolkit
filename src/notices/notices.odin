// Package notices: a program's log of what its user may have missed (a run ended, a question waits, a command ended),
// kept across restarts, with what was acknowledged in a history (docs/notices.md).
//
// The log is a projection of the program's own truth: the program puts an entry when something happens (a key says what
// the entry is about: one session's run, one question), acknowledges it when the user opened the thing, and removes it when
// the thing is gone. An entry's state is New (not shown yet), Seen (the view of the log was opened) or Acknowledged (the user
// went to the thing): `step` is that machine, pure. An entry not acknowledged is "open": the log keeps at most one open entry
// per key, and a put of a key already open updates it (count + 1) instead of adding one. Acknowledged entries stay as a
// history, the oldest dropped past `cap`; an open entry is never dropped.
//
// The log is the interface thread's: no lock. Its file is a gt:store, written by the store's worker: nothing here waits on
// the disk after `open`.
//
// The package is named `tk_notices` (the directory is `notices`, imported as `gt:notices`), as the toolkit's others.
package tk_notices

import "base:runtime"
import "core:slice"
import "core:strconv"
import "core:strings"
import "../platform"
import store "../store"

// The history kept when the program says none (entries acknowledged; open ones come on top).
CAP :: 200

State :: enum u8 { New, Seen, Acknowledged }

// What happens to an entry: put again, the log's view opened, the user went to the thing.
Event :: enum u8 { Put, Seen, Acknowledge }

Entry :: struct {
	id:      u64,                        // the log's own, increasing: the order of the entries
	key:     string,                     // what the entry is about (a session's run, one question): one open entry per key
	group:   string,                     // what the entries are shown under (a session)
	title:   string,
	text:    string,                     // an excerpt
	kind:    u16,                        // the program's (a run, a question...)
	outcome: u8,                         // the program's (done, failed...)
	at:      i64,                        // ms since 1970, of the last put
	count:   int,                        // puts while it was open
	state:   State,
	system:  platform.Notification_Id,   // its notification of the system (0: none); not saved
	user:    u64,                        // the program's
}

// What `put` takes. The strings are copied.
Desc :: struct {
	key, group, title, text: string,
	kind:    u16,
	outcome: u8,
	at:      i64,
	user:    u64,
}

// The entries of one group, newest first. `open`: those not acknowledged.
Group :: struct {
	group:   string,
	entries: []^Entry,
	newest:  i64,
	open:    int,
}

// A system notification that must go: its entry was acknowledged or removed. The program calls platform.notify_close.
Close_System :: #type proc(user: rawptr, id: platform.Notification_Id)

Log :: struct {
	entries:     [dynamic]^Entry,          // by id, the oldest first (each its own allocation: a ^Entry stays until it is removed)
	live:        map[string]^Entry,        // the open entry of a key (map keys are the entries' own keys)
	cap:         int,
	next_id:     u64,
	ver:         u64,                      // bumped at every change: what a view compares to know it must redraw
	counts:      [State]int,
	groups_made: int,                      // how many times groups() rebuilt its list (tests)
	close_system: Close_System,            // the program's (nil: no system notifications)
	close_user:  rawptr,
	kept:        [2]Kept_Groups,           // groups(), without and with the acknowledged
	file:        store.Store,
	allocator:   runtime.Allocator,
}

@(private)
Kept_Groups :: struct {
	ver:     u64,
	made:    bool,
	groups:  []Group,
	entries: []^Entry,   // the groups' entries, one slice cut into each group's
}

// Reads the log's file at `path` (a gt:store beside the program's preferences; "": in memory only) and starts its worker.
// `loaded` is false when there was no file. Call it at the program's start, before the window: it reads on this thread.
open :: proc(log: ^Log, path: string, cap := CAP, allocator := context.allocator) -> (loaded: bool) {
	log^ = {}
	log.allocator = allocator
	log.cap = max(cap, 0)
	log.next_id = 1
	log.entries = make([dynamic]^Entry, allocator)
	log.live = make(map[string]^Entry, allocator)
	loaded = store.open(&log.file, path, allocator = allocator)
	for line in store.list(&log.file) {
		e, ok := decode(log, line.key, line.value)
		if !ok {
			store.remove(&log.file, line.key)
			continue
		}
		append(&log.entries, e)
	}
	slice.sort_by(log.entries[:], proc(a, b: ^Entry) -> bool { return a.id < b.id })
	for e in log.entries {
		log.next_id = max(log.next_id, e.id + 1)
		if e.state != .Acknowledged {
			// (two open entries of one key: a file written by hand; the newer stays open)
			if old, ok := log.live[e.key]; ok { set_state(log, old, .Acknowledged); save(log, old) }
			log.live[e.key] = e
		}
		log.counts[e.state] += 1
	}
	trim(log)
	log.ver = 1
	return
}

// Writes what changed, ends the file's worker, frees every entry. The log is zero after.
close :: proc(log: ^Log) {
	store.close(&log.file)
	for e in log.entries { free_entry(log, e) }
	delete(log.entries)
	delete(log.live)
	for &k in log.kept { drop_kept(log, &k) }
	log^ = {}
}

// Writes what changed now and waits for the disk (the end of the program, a test). Never in a frame.
flush :: proc(log: ^Log) { store.flush(&log.file) }

// The state after `event`: a put makes it New, the view opened makes a New one Seen, the user's visit acknowledges it.
step :: proc(state: State, event: Event) -> State {
	switch event {
	case .Put:         return .New
	case .Seen:        return state == .New ? .Seen : state
	case .Acknowledge: return .Acknowledged
	}
	return state
}

// Something happened. When an entry of `d.key` is open, it takes `d`'s fields, counts one more and is New again
// (`fresh` false): its system notification, if any, is the one to replace. Else a new entry (`fresh` true), and the
// history past `cap` loses its oldest. The entry is valid until the next change of the log.
put :: proc(log: ^Log, d: Desc) -> (e: ^Entry, fresh: bool) {
	if e = log.live[d.key]; e != nil {
		set_text(log, &e.group, d.group)
		set_text(log, &e.title, d.title)
		set_text(log, &e.text, d.text)
		e.kind, e.outcome, e.at, e.user = d.kind, d.outcome, d.at, d.user
		e.count += 1
		set_state(log, e, step(e.state, .Put))
	} else {
		fresh = true
		e = new(Entry, log.allocator)
		e^ = {
			id = log.next_id, kind = d.kind, outcome = d.outcome, at = d.at, user = d.user, count = 1, state = step(.New, .Put),
			key = strings.clone(d.key, log.allocator), group = strings.clone(d.group, log.allocator),
			title = strings.clone(d.title, log.allocator), text = strings.clone(d.text, log.allocator),
		}
		log.next_id += 1
		append(&log.entries, e)
		log.live[e.key] = e
		log.counts[e.state] += 1
	}
	save(log, e)
	log.ver += 1
	if fresh { trim(log) }
	return
}

// The user went to the thing of `key`: its open entry goes to the history. Returns it (nil: none was open).
acknowledge :: proc(log: ^Log, key: string) -> ^Entry {
	e := log.live[key]
	if e == nil { return nil }
	acknowledge_entry(log, e)
	log.ver += 1
	return e
}

// Every open entry of `group` goes to the history. Returns how many.
acknowledge_group :: proc(log: ^Log, group: string) -> (n: int) {
	for e in log.entries {
		if e.state != .Acknowledged && e.group == group { acknowledge_entry(log, e); n += 1 }
	}
	if n > 0 { log.ver += 1 }
	return
}

// Every open entry goes to the history. Returns how many.
acknowledge_all :: proc(log: ^Log) -> (n: int) {
	for e in log.entries {
		if e.state != .Acknowledged { acknowledge_entry(log, e); n += 1 }
	}
	if n > 0 { log.ver += 1 }
	return
}

// The view of the log was opened: what was New is Seen. Returns how many changed.
seen_all :: proc(log: ^Log) -> (n: int) {
	for e in log.entries {
		if e.state != .New { continue }
		set_state(log, e, step(e.state, .Seen))
		save(log, e)
		n += 1
	}
	if n > 0 { log.ver += 1 }
	return
}

// The thing of `key` is gone (a session deleted): every entry of it goes, its history too. Returns how many.
remove :: proc(log: ^Log, key: string) -> int {
	return remove_where(log, key, proc(e: ^Entry, key: string) -> bool { return e.key == key })
}

// Every entry of `group` goes (the session deleted). Returns how many.
remove_group :: proc(log: ^Log, group: string) -> int {
	return remove_where(log, group, proc(e: ^Entry, group: string) -> bool { return e.group == group })
}

// The open entry of `key`; when none is open, the newest of its history; nil: none. Valid until the next change.
find :: proc(log: ^Log, key: string) -> ^Entry {
	if e := log.live[key]; e != nil { return e }
	#reverse for e in log.entries {
		if e.key == key { return e }
	}
	return nil
}

// The notification the system showed for the open entry of `key` (notify_async's answer). When the entry is not open
// any more (acknowledged meanwhile), the notification goes at once (close_system).
set_system :: proc(log: ^Log, key: string, id: platform.Notification_Id) {
	if id == 0 { return }
	e := log.live[key]
	if e == nil {
		if log.close_system != nil { log.close_system(log.close_user, id) }
		return
	}
	if e.system != 0 && e.system != id && log.close_system != nil { log.close_system(log.close_user, e.system) }
	e.system = id
	log.ver += 1
}

// The system says its notification `id` is gone (Notification_Closed): no entry keeps it.
system_closed :: proc(log: ^Log, id: platform.Notification_Id) {
	if id == 0 { return }
	for e in log.entries {
		if e.system == id { e.system = 0; log.ver += 1 }
	}
}

// The entries by group, groups newest first and entries newest first in each; `with_acknowledged` false: the open ones
// only (a group with none is left out). The list is kept and made again only after a change: a view calls it every frame.
// It is valid until the next change of the log.
groups :: proc(log: ^Log, with_acknowledged: bool) -> []Group {
	k := &log.kept[int(with_acknowledged)]
	if k.made && k.ver == log.ver { return k.groups }
	drop_kept(log, k)
	k.made, k.ver = true, log.ver
	log.groups_made += 1

	n := 0
	for e in log.entries { if with_acknowledged || e.state != .Acknowledged { n += 1 } }
	k.entries = make([]^Entry, n, log.allocator)
	i := 0
	for e in log.entries {
		if with_acknowledged || e.state != .Acknowledged { k.entries[i] = e; i += 1 }
	}
	slice.sort_by(k.entries, proc(a, b: ^Entry) -> bool {
		if a.group != b.group { return a.group < b.group }
		return newer(a, b)
	})
	count := 0
	for e, j in k.entries { if j == 0 || e.group != k.entries[j - 1].group { count += 1 } }
	k.groups = make([]Group, count, log.allocator)
	g := -1
	for e, j in k.entries {
		if j == 0 || e.group != k.entries[j - 1].group {
			g += 1
			k.groups[g] = {group = e.group, newest = e.at}
			k.groups[g].entries = k.entries[j:j]
		}
		gr := &k.groups[g]
		gr.entries = k.entries[j - len(gr.entries):j + 1]
		gr.newest = max(gr.newest, e.at)
		if e.state != .Acknowledged { gr.open += 1 }
	}
	slice.sort_by(k.groups, proc(a, b: Group) -> bool {
		if a.newest != b.newest { return a.newest > b.newest }
		return a.group < b.group
	})
	return k.groups
}

////////////////////////////////
// Inside

@(private)
newer :: proc(a, b: ^Entry) -> bool {
	if a.at != b.at { return a.at > b.at }
	return a.id > b.id
}

// Every change of a state goes through here: `counts` is always a recount.
@(private)
set_state :: proc(log: ^Log, e: ^Entry, state: State) {
	if e.state == state { return }
	log.counts[e.state] -= 1
	log.counts[state] += 1
	e.state = state
}

@(private)
acknowledge_entry :: proc(log: ^Log, e: ^Entry) {
	set_state(log, e, step(e.state, .Acknowledge))
	if log.live[e.key] == e { delete_key(&log.live, e.key) }
	close_system(log, e)
	save(log, e)
}

@(private)
close_system :: proc(log: ^Log, e: ^Entry) {
	if e.system != 0 && log.close_system != nil { log.close_system(log.close_user, e.system) }
	e.system = 0
}

@(private)
remove_where :: proc(log: ^Log, what: string, match: proc(e: ^Entry, what: string) -> bool) -> (n: int) {
	kept := 0
	for e in log.entries {
		if !match(e, what) {
			log.entries[kept] = e
			kept += 1
			continue
		}
		drop(log, e)
		n += 1
	}
	resize(&log.entries, kept)
	if n > 0 { log.ver += 1 }
	return
}

// Forgets `e` everywhere but in `entries` (the caller takes it out).
@(private)
drop :: proc(log: ^Log, e: ^Entry) {
	if log.live[e.key] == e { delete_key(&log.live, e.key) }
	close_system(log, e)
	log.counts[e.state] -= 1
	store.remove(&log.file, id_key(e.id))
	free_entry(log, e)
}

// The history past `cap` loses its oldest; an open entry never goes.
@(private)
trim :: proc(log: ^Log) {
	over := len(log.entries) - log.cap
	if over <= 0 { return }
	kept := 0
	for e in log.entries {
		if over > 0 && e.state == .Acknowledged {
			drop(log, e)
			over -= 1
			continue
		}
		log.entries[kept] = e
		kept += 1
	}
	if kept != len(log.entries) { log.ver += 1 }
	resize(&log.entries, kept)
}

@(private)
free_entry :: proc(log: ^Log, e: ^Entry) {
	delete(e.key, log.allocator)
	delete(e.group, log.allocator)
	delete(e.title, log.allocator)
	delete(e.text, log.allocator)
	free(e, log.allocator)
}

@(private)
set_text :: proc(log: ^Log, field: ^string, value: string) {
	if field^ == value { return }
	delete(field^, log.allocator)
	field^ = strings.clone(value, log.allocator)
}

@(private)
drop_kept :: proc(log: ^Log, k: ^Kept_Groups) {
	delete(k.groups, log.allocator)
	delete(k.entries, log.allocator)
	k^ = {}
}

////////////////////////////////
// The file: one line per entry, `<id>\t<state>\t<count>\t<at>\t<kind>\t<outcome>\t<user>\t<key>\t<group>\t<title>\t<text>`,
// the strings escaped (\\, \t, \n, \r): a gt:store line holds no line break, and a tab parts the fields.

@(private)
FIELDS :: 10

@(private)
id_key :: proc(id: u64) -> string {
	buf := make([]byte, 24, context.temp_allocator)
	return strconv.write_uint(buf, id, 10)
}

@(private)
save :: proc(log: ^Log, e: ^Entry) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_int(&b, int(e.state)); strings.write_byte(&b, '\t')
	strings.write_int(&b, e.count); strings.write_byte(&b, '\t')
	strings.write_i64(&b, e.at); strings.write_byte(&b, '\t')
	strings.write_uint(&b, uint(e.kind)); strings.write_byte(&b, '\t')
	strings.write_uint(&b, uint(e.outcome)); strings.write_byte(&b, '\t')
	strings.write_u64(&b, e.user)
	for s in ([4]string{e.key, e.group, e.title, e.text}) {
		strings.write_byte(&b, '\t')
		escape(&b, s)
	}
	store.set(&log.file, id_key(e.id), strings.to_string(b))
}

@(private)
escape :: proc(b: ^strings.Builder, s: string) {
	for i in 0 ..< len(s) {
		switch s[i] {
		case '\\': strings.write_string(b, `\\`)
		case '\t': strings.write_string(b, `\t`)
		case '\n': strings.write_string(b, `\n`)
		case '\r': strings.write_string(b, `\r`)
		case:      strings.write_byte(b, s[i])
		}
	}
}

@(private)
unescape :: proc(s: string, allocator: runtime.Allocator) -> string {
	b := strings.builder_make(0, len(s), allocator)
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if c == '\\' && i + 1 < len(s) {
			i += 1
			switch s[i] {
			case 't': c = '\t'
			case 'n': c = '\n'
			case 'r': c = '\r'
			case:     c = s[i]
			}
		}
		strings.write_byte(&b, c)
	}
	return strings.to_string(b)
}

// An entry of the file; ok false: a line this log did not write (it is dropped).
@(private)
decode :: proc(log: ^Log, key, value: string) -> (e: ^Entry, ok: bool) {
	id := strconv.parse_u64_of_base(key, 10) or_return
	parts := strings.split(value, "\t", context.temp_allocator)
	if len(parts) != FIELDS || id == 0 { return }
	state := strconv.parse_int(parts[0], 10) or_return
	count := strconv.parse_int(parts[1], 10) or_return
	at := strconv.parse_i64_of_base(parts[2], 10) or_return
	kind := strconv.parse_uint(parts[3], 10) or_return
	outcome := strconv.parse_uint(parts[4], 10) or_return
	user := strconv.parse_u64_of_base(parts[5], 10) or_return
	if state < 0 || state > int(max(State)) || count < 1 || kind > uint(max(u16)) || outcome > uint(max(u8)) || parts[6] == "" { return }
	e = new(Entry, log.allocator)
	e^ = {
		id = id, state = State(state), count = count, at = at, kind = u16(kind), outcome = u8(outcome), user = user,
		key = unescape(parts[6], log.allocator), group = unescape(parts[7], log.allocator),
		title = unescape(parts[8], log.allocator), text = unescape(parts[9], log.allocator),
	}
	return e, true
}
