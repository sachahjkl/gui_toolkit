package tk_setup

// The install and the folders that an earlier identity of the program made, taken over once at the start: the program
// changed its name (src/md/features/identity-change.md). The folders move by one rename per kind; the install moves
// only from the copy that the update bridge placed in the earlier folder. A lock keeps one start at a time, and a record
// beside the state folder keeps each step's result, so an interrupted start resumes and each result is said once.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import base "../base"
import desktop "../desktop"
import fsx "../fsx"
import i18n "../i18n"
import platform "../platform"
import process "../process"

// An earlier identity of the program: the names and marks that its installs and folders carry.
Earlier :: struct {
	identity:       desktop.Identity,     // as its installs carry it (desktop.identity_of, with what the program set after)
	install_folder: string,               // its Setup_Options.install_folder ("": the default)
	program_folder: string,               // its folder in its vendor's, platform.user_dir's name ("": its folders do not move)
	kinds:          platform.User_Dirs,   // the kinds of its folders that move ({}: platform.USER_DIRS_MOVED)
}

// How long a start waits for an earlier program to end and for a folder to move: after an update, the process that
// placed the program is still ending, and a scanner may hold a file it just wrote.
ADOPT_WAIT :: 10 * time.Second

// How many starts end when a folder cannot move, before the next one copies it and leaves the earlier folder.
ADOPT_TRIES :: 3

// How often the waits look again.
@(private = "file")
ADOPT_POLL :: 100 * time.Millisecond

// What a step of the adoption did.
Adopt_Outcome :: enum u8 {
	None,           // nothing of the earlier identity was there
	Begun,          // (the record only: begun by a start that did not finish)
	Done,
	Copied,         // folders: a folder could not move: it was copied, and the earlier one stays
	Kept_Both,      // folders: a new folder was there already; it stays, and the earlier one stays where it is
	Administered,   // install: an install for everyone; an administrator replaces it
	Managed,        // install: this copy is a Nix package; nothing is installed here
	Pending,        // install: this copy is not the bridge's: the setup offers the install; the earlier one goes after
	Running,        // an earlier program runs: nothing was done; the next start adopts
	Busy,           // another start adopts now: this one ends
	Failed,         // tried again at the next start
}

// What the install step does (adopt_plan).
Adopt_Move :: enum u8 {
	Nothing,
	Move,             // the bridge's copy: the new install with the earlier one's choices, then the earlier one goes
	Remove_Earlier,   // the new install is there (or the earlier one left only pieces): the earlier one goes
	Offer,            // another copy runs: nothing installed; the setup offers it, and the earlier one goes once it is there
	Administered,     // an install for everyone: nothing here
	Managed,          // this copy runs from the Nix store: nothing here
}

Adopt_Plan :: struct {
	move:     Adopt_Move,
	shortcut: bool,            // Move: the earlier install had a desktop shortcut
	parts:    desktop.Parts,   // Move: the parts the earlier install had (the boxes tied to them start on)
	relaunch: bool,            // this copy is the earlier install's program: the adopted one starts in its place
}

// What the start does with an earlier install, from its facts (facts of the earlier identity's options, measured against
// the running program) and whether the program is installed under its own name already. Pure.
adopt_plan :: proc(earlier: Facts, adopted_there: bool) -> Adopt_Plan {
	if !earlier.exe_there && !leftover(earlier) { return {} }
	if earlier.from_nix { return {move = .Managed} }
	if earlier.scope == .System { return {move = .Administered} }
	if adopted_there || !earlier.exe_there { return {move = .Remove_Earlier, relaunch = earlier.running_it} }
	// (a download, a portable copy, a build: the person did not ask to install it)
	if !earlier.running_it { return {move = .Offer} }
	return {move = .Move, shortcut = earlier.desk_lnk, parts = earlier.parts, relaunch = true}
}

// What the start adopted, for the program to say once (adoption_words) and to act on (relaunch, stop). Strings in the
// allocator given to adopt_earlier (adoption_destroy).
Adoption :: struct {
	earlier:        string,          // the earlier name ("": nothing of an earlier identity to say)
	name:           string,          // the program's name
	folders:        Adopt_Outcome,
	folders_detail: string,          // Kept_Both, Copied: the earlier folder that stays; Failed: why
	install:        Adopt_Outcome,
	install_detail: string,          // Failed: why; Managed: the earlier install's folder
	command:        string,          // the earlier console command, gone with the earlier install ("": it had none)
	new_command:    string,          // ... and the new one
	pinned:         bool,            // Windows: a pin of the taskbar runs the earlier program: the person pins the new one again
	// this copy is the earlier install's program: start this one (setup.launch) and end, before any window
	relaunch:       string,
	// the start ends after it says adoption_words: the earlier folders are not moved yet (Running, Busy, Failed), and the
	// program would make new ones
	stop:           bool,
	news:           bool,            // not said yet: the program says adoption_words once
}

adoption_destroy :: proc(a: ^Adoption, allocator := context.allocator) {
	delete(a.earlier, allocator); delete(a.name, allocator); delete(a.folders_detail, allocator)
	delete(a.install_detail, allocator); delete(a.command, allocator); delete(a.new_command, allocator)
	delete(a.relaunch, allocator)
	a^ = {}
}

// Takes over what an earlier identity of the program left (Setup_Options.earlier): its folders, moved to
// Setup_Options.program_folder, and its install, replaced by this program's. Once: a record beside the state folder
// keeps what was done. Call it at the start, before the log, the settings and any window: it moves the folders they
// read, and it waits on the disk. When `relaunch` is set, start it and end. When `stop` is set, say adoption_words and
// end. `exe`: the running program ("": this process's). `wait`: how long it waits for an earlier program and for a
// folder (another start: twice that).
adopt_earlier :: proc(o: Setup_Options, exe := "", wait := ADOPT_WAIT, allocator := context.allocator, loc := #caller_location) -> (a: Adoption) {
	if len(o.earlier) == 0 || base.restricted() { return }   // (an administrator's process moves nothing of a person's)
	base.blocking("setup.adopt_earlier", loc)
	running := exe != "" ? exe : process.executable_path(context.temp_allocator)
	path := record_path(o.program_folder != "" ? o.program_folder : o.identity.slug)
	lock: fsx.File_Lock
	defer fsx.file_unlock(&lock)
	if path != "" {
		_ = os.make_directory_all(filepath.dir(path))
		got: fsx.Lock_Result
		lock, got = fsx.file_lock(strings.concatenate({path, ".lock"}, context.temp_allocator), 2 * wait)
		if got == .Busy {
			// (another start adopts now: this one would read folders half moved)
			return {
				earlier = strings.clone(o.earlier[0].identity.name, allocator), name = strings.clone(o.identity.name, allocator),
				folders = .Busy, install = .Busy, stop = true, news = true,
			}
		}
		// (Failed: a state folder that takes no file takes no record either: each start adopts what it finds)
	}
	for e in o.earlier {
		rec := record_read(path)   // (under the lock: what another start finished is read)
		got := adopt_one(o, e, running, path, &rec, wait)
		if got.earlier == "" { continue }
		return {
			earlier = strings.clone(got.earlier, allocator), name = strings.clone(got.name, allocator),
			folders = got.folders, folders_detail = strings.clone(got.folders_detail, allocator),
			install = got.install, install_detail = strings.clone(got.install_detail, allocator),
			command = strings.clone(got.command, allocator), new_command = strings.clone(got.new_command, allocator),
			pinned = got.pinned, relaunch = strings.clone(got.relaunch, allocator), stop = got.stop, news = got.news,
		}
	}
	return
}

// The outcomes after which a step is not run again.
@(private = "file")
final :: proc(x: Adopt_Outcome) -> bool { return x != .Begun && x != .Failed && x != .Running && x != .Busy && x != .Pending }

// One earlier identity (temp memory).
@(private = "file")
adopt_one :: proc(o: Setup_Options, e: Earlier, running, path: string, rec: ^map[string]string, wait: time.Duration) -> (a: Adoption) {
	slug := e.identity.slug
	if slug == "" { return }
	a.earlier, a.name = e.identity.name, o.identity.name
	eo := earlier_options(o, e)
	f_before, f_had := record_outcome(rec^, slug, "folders")
	i_before, i_had := record_outcome(rec^, slug, "install")
	folders_left := !(f_had && final(f_before))
	install_left := !(i_had && final(i_before))
	relaunch := ""

	if folders_left || install_left {
		deadline := time.time_add(time.now(), wait)
		ef := facts(eo, exe = running)
		// (an earlier program that runs holds its files and still writes its folders: an update's process may be
		// ending. An install that only waits for the setup's offer needs nothing of it)
		removes := install_left && adopt_plan(ef, install_there(o, .User)).move in (bit_set[Adopt_Move]{.Move, .Remove_Earlier})
		if folders_left || removes {
			for earlier_running(ef.exe) {
				if time.diff(time.now(), deadline) <= 0 {
					a.folders, a.install, a.news, a.stop = .Running, .Running, true, true
					return
				}
				time.sleep(ADOPT_POLL)
			}
			ef = facts(eo, exe = running)   // (the earlier process may have changed its install as it ended)
		}
		// an earlier install inside one of its own folders goes first: the folder moves without it
		if install_left && install_within(ef.dir, e) {
			relaunch = install_step(o, eo, running, path, rec, slug)
			folders_step(o, e, path, rec, deadline)
		} else {
			if folders_step(o, e, path, rec, deadline) {
				record_fill_folders(&a, rec^, slug)
				a.news, a.stop = true, true
				return
			}
			if install_left { relaunch = install_step(o, eo, running, path, rec, slug) }   // (its facts read again)
		}
	}

	// (this copy runs from the earlier install's folder: the adopted program starts in its place, which says the news
	// and moves the folders that are left)
	if relaunch != "" {
		_ = record_fill(&a, rec^, slug)   // (for the caller to see; not marked as said)
		a.relaunch = relaunch
		return
	}
	if f, _ := record_outcome(rec^, slug, "folders"); f == .Failed {
		record_fill_folders(&a, rec^, slug)
		a.news, a.stop = true, true
		return
	}
	shown := record_fill(&a, rec^, slug)
	a.news = says_something(a)
	if !a.news { return {} }
	for step in shown { rec[record_key(slug, step)] = "1" }
	if len(shown) > 0 { record_write(path, rec^) }
	return
}

// The folders' step, when it is not done: a rename per kind, tried until `deadline`; after ADOPT_TRIES starts that
// ended on it, a copy. true: a folder is still not moved, and the start ends.
@(private = "file")
folders_step :: proc(o: Setup_Options, e: Earlier, path: string, rec: ^map[string]string, deadline: time.Time) -> (stop: bool) {
	slug := e.identity.slug
	before, had := record_outcome(rec^, slug, "folders")
	if had && final(before) { return false }
	from, to := e.program_folder, o.program_folder
	outcome, detail := Adopt_Outcome.None, ""
	if from != "" && to != "" && from != to {
		tries, _ := strconv.parse_int(rec[record_key(slug, "folders_tries")])
		copy := tries >= ADOPT_TRIES
		rec[record_key(slug, "folders")] = "Begun"
		record_write(path, rec^)
		outcome, detail = folders_move(from, to, e.kinds != {} ? e.kinds : platform.USER_DIRS_MOVED, deadline, copy)
		if had && before == .Begun {
			// (begun by a start that ended before it said so: what it moved is not there any more to move, and what it
			// copied is there beside the earlier folder; no other start made a new folder: they all ended or waited)
			if outcome == .None { outcome = .Done }
			if copy && outcome == .Kept_Both { outcome = .Copied }
		}
		if outcome == .Failed { rec[record_key(slug, "folders_tries")] = fmt.tprint(tries + 1) }
	}
	rec[record_key(slug, "folders")] = fmt.tprint(outcome)
	rec[record_key(slug, "folders_detail")] = detail
	record_write(path, rec^)
	return outcome == .Failed
}

// The install's step, when it is not done, from the facts as they are now. The adopted program to start in this one's
// place ("": none).
@(private = "file")
install_step :: proc(o, eo: Setup_Options, running, path: string, rec: ^map[string]string, slug: string) -> (relaunch: string) {
	before, had := record_outcome(rec^, slug, "install")
	if had && final(before) { return "" }
	ef := facts(eo, exe = running)
	plan := adopt_plan(ef, install_there(o, .User))
	outcome, detail := Adopt_Outcome.None, ""
	switch plan.move {
	case .Nothing:
		if had && before == .Begun { outcome = .Done }
	case .Offer:
		outcome = .Pending
	case .Administered:
		outcome = .Administered
	case .Managed:
		outcome, detail = .Managed, ef.dir
	case .Move, .Remove_Earlier:
		// (written before anything goes: a later start that resumes finds the earlier install gone)
		rec[record_key(slug, "install")] = "Begun"
		if desktop.taskbar_pinned(ef.exe) { rec[record_key(slug, "pinned")] = "1" }
		if .Path in ef.parts {
			rec[record_key(slug, "command")] = command_name(eo.identity)
			rec[record_key(slug, "new_command")] = command_name(o.identity)
		}
		record_write(path, rec^)
		ok, why := adopt_install(o, eo, ef, plan, running)
		outcome, detail = ok ? .Done : .Failed, why
	}
	rec[record_key(slug, "install")] = fmt.tprint(outcome)
	rec[record_key(slug, "install_detail")] = detail
	record_write(path, rec^)
	if outcome == .Done && same_dir(process.parent_dir(running), ef.dir) && install_there(o, .User) {
		integration, _ := options(o, nil, .User)
		return join({integration.install_dir, desktop.exe_name_of(integration.identity)})
	}
	return ""
}

// Whether the earlier install's folder is one of the earlier folders that move, or inside one.
@(private = "file")
install_within :: proc(dir: string, e: Earlier) -> bool {
	if dir == "" || e.program_folder == "" { return false }
	kinds := e.kinds != {} ? e.kinds : platform.USER_DIRS_MOVED
	for kind in platform.User_Dir {
		if kind == .Runtime || kind not_in kinds { continue }
		root := platform.user_dir(kind, "", context.temp_allocator)
		if root == "" { continue }
		folder := strings.concatenate({root, platform.USER_DIR_SEPARATOR, e.program_folder}, context.temp_allocator)
		if desktop.same_path(dir, folder) || desktop.is_inside(dir, folder) { return true }
	}
	return false
}

@(private = "file")
same_dir :: proc(a, b: string) -> bool {
	return a != "" && b != "" && desktop.same_path(strings.trim_right(a, "\\/"), strings.trim_right(b, "\\/"))
}

@(private = "file")
says_something :: proc(a: Adoption) -> bool {
	return a.folders != .None || a.install != .None || a.pinned || a.command != ""
}

// The options of the earlier identity: the program's own parts and choices, its names and marks.
earlier_options :: proc(o: Setup_Options, e: Earlier) -> Setup_Options {
	eo := o
	eo.identity = e.identity
	eo.install_folder = e.install_folder
	eo.program_folder = e.program_folder
	eo.earlier = nil
	return eo
}

// The console command of an identity: its program's file without ".exe".
@(private = "file")
command_name :: proc(id: desktop.Identity) -> string {
	return strings.trim_suffix(desktop.exe_name_of(id), ".exe")
}

// A process of another copy runs the earlier program: its file, its name after an update set it aside (Windows: .old),
// or the file it held before an update replaced it (Linux: "(deleted)"). An earlier program that runs from another
// place (a Nix package, a portable copy) is not seen: identity-change.md says what then.
@(private = "file")
earlier_running :: proc(exe: string) -> bool {
	if exe == "" { return false }
	for p in ([]string{exe, fmt.tprintf("%s.old", exe), fmt.tprintf("%s (deleted)", exe)}) {
		if len(process.processes_of(p, context.temp_allocator)) > 0 { return true }
	}
	return false
}

// The new install with the earlier one's choices (Move), the earlier one gone, the new integration written again.
@(private = "file")
adopt_install :: proc(o, eo: Setup_Options, ef: Facts, plan: Adopt_Plan, running: string) -> (ok: bool, why: string) {
	choices := choices_or_first(o, nil)
	shortcut := plan.shortcut
	if plan.move == .Move {
		choices_from_facts(ef, o, choices)
		if done, w := install_user(o, shortcut, choices, adopted_folder(o, eo, ef.dir), running); !done { return false, w }
	} else if install_there(o, .User) {
		// (the new install is there with its own choices: they stay)
		nf := facts(o, scope = .User, exe = running)
		choices_from_facts(nf, o, choices)
		shortcut = nf.desk_lnk
	}
	gone, leftovers, w := uninstall_scope(eo, choices, .User, running)
	defer {
		for l in leftovers { delete(l) }
		delete(leftovers)
	}
	// (Windows: the earlier program that runs this; its files go once this process ends, their folder with them)
	if len(leftovers) > 0 {
		u, _ := options(eo, nil, .User)
		_ = desktop.cleanup_later(&u, leftovers[:], process.parent_dir(leftovers[len(leftovers) - 1]), desktop.current_process_id())
	}
	if !gone { return false, w }
	// (a name the two identities share is the new one's again, whatever the removal took)
	if !install_there(o, .User) { return true, "" }
	if r := person_half_write(o, shortcut, choices, .User); r.error != .None { return false, failure(r) }
	return true, ""
}

// A folder of the person's choice (the system recorded one that is not the earlier default): the new install goes
// beside it, under the new name. "": the default folder.
@(private = "file")
adopted_folder :: proc(o, eo: Setup_Options, earlier_dir: string) -> string {
	integration, recorded := options(eo, nil, .User)
	if !recorded || earlier_dir == "" { return "" }
	default := desktop.default_install_dir(&integration)
	if default == "" { return "" }
	expected := eo.install_folder != "" ? join({process.parent_dir(default), eo.install_folder}) : default
	if desktop.same_path(earlier_dir, expected) { return "" }
	mine, _ := options(o, nil, .User)
	return join({process.parent_dir(earlier_dir), filepath.base(mine.install_dir)})
}

@(private = "file")
Kind_Move :: struct { old, new: string }

// Each kind's earlier folder renamed to the new one, when the new one is not there; a rename that fails is tried again
// until `deadline`. `copy`: a folder that still cannot move is copied (into a sibling, then renamed into place), and the
// earlier one stays. Failed: a folder is not moved (detail: why); Kept_Both: one stayed because the new one was there
// (detail: the earlier folder); Copied: one was copied (detail: the earlier folder); Done: one moved at least.
folders_move :: proc(from, to: string, kinds: platform.User_Dirs, deadline: time.Time, copy := false) -> (outcome: Adopt_Outcome, detail: string) {
	moved, kept, copied := 0, 0, 0
	kept_detail, copied_detail, why := "", "", ""
	seen := make([dynamic]string, context.temp_allocator)
	todo := make([dynamic]Kind_Move, context.temp_allocator)
	for kind in platform.User_Dir {
		if kind == .Runtime || kind not_in kinds { continue }
		root := platform.user_dir(kind, "", context.temp_allocator)
		if root == "" { continue }
		old := strings.concatenate({root, platform.USER_DIR_SEPARATOR, from}, context.temp_allocator)
		new := strings.concatenate({root, platform.USER_DIR_SEPARATOR, to}, context.temp_allocator)
		// (Windows: the data, state and cache of a program are one folder of %LOCALAPPDATA%, moved once)
		if slice.contains(seen[:], old) { continue }
		append(&seen, old)
		if os.is_dir(old) { append(&todo, Kind_Move{old, new}) }
	}
	for {
		left := make([dynamic]Kind_Move, context.temp_allocator)
		why = ""
		for m in todo {
			if os.exists(m.new) {
				kept += 1
				if kept_detail == "" { kept_detail = m.old }
				continue
			}
			if parent := filepath.dir(m.new); !os.exists(parent) { _ = os.make_directory_all(parent) }
			if err := os.rename(m.old, m.new); err != nil {
				if why == "" { why = fmt.tprintf("%s: %v", m.old, err) }
				append(&left, m)
				continue
			}
			moved += 1
		}
		todo = left
		if len(todo) == 0 || time.diff(time.now(), deadline) <= 0 { break }
		time.sleep(ADOPT_POLL)
	}
	failed := len(todo)
	if copy && failed > 0 {
		why = ""
		for m in todo {
			if w := folder_copy(m.old, m.new); w != "" {
				if why == "" { why = w }
				continue
			}
			copied += 1
			failed -= 1
			if copied_detail == "" { copied_detail = m.old }
		}
	}
	switch {
	case failed > 0: outcome, detail = .Failed, why
	case kept > 0:   outcome, detail = .Kept_Both, kept_detail
	case copied > 0: outcome, detail = .Copied, copied_detail
	case moved > 0:  outcome = .Done
	}
	return
}

// `old` copied whole into a sibling of `new`, then renamed to `new`: an interruption leaves the sibling, never half a
// `new`, and the next try begins it again. `old` stays. why: "" when done.
@(private = "file")
folder_copy :: proc(old, new: string) -> (why: string) {
	temp := strings.concatenate({new, ".adopting"}, context.temp_allocator)
	_ = fsx.remove_tree(temp)   // (this name is the adoption's own: what an interrupted copy left)
	if parent := filepath.dir(new); !os.exists(parent) { _ = os.make_directory_all(parent) }
	if w := tree_copy(old, temp); w != "" {
		_ = fsx.remove_tree(temp)
		return w
	}
	if err := os.rename(temp, new); err != nil {
		_ = fsx.remove_tree(temp)
		return fmt.tprintf("%s: %v", new, err)
	}
	return ""
}

// A copy of the folder `src` at `dst`: its files and folders; a link is copied as a link, never followed.
@(private = "file")
tree_copy :: proc(src, dst: string) -> (why: string) {
	if err := os.make_directory(dst); err != nil { return fmt.tprintf("%s: %v", dst, err) }
	entries, err := os.read_all_directory_by_path(src, context.temp_allocator)
	if err != nil { return fmt.tprintf("%s: %v", src, err) }
	for fi in entries {
		from, to := fsx.path_join(src, fi.name), fsx.path_join(dst, fi.name)
		#partial switch fi.type {
		case .Regular:
			if e := os.copy_file(to, from); e != nil { return fmt.tprintf("%s: %v", from, e) }
		case .Directory:
			if w := tree_copy(from, to); w != "" { return w }
		case .Symlink:
			target, le := os.read_link(from, context.temp_allocator)
			if le != nil { return fmt.tprintf("%s: %v", from, le) }
			if e := os.symlink(target, to); e != nil { return fmt.tprintf("%s: %v", to, e) }
		}
	}
	return ""
}

////////////////////////////////
// The record

// Beside the program's state folder, never in it: in it, the record would make the new folder before the move.
// "": the system has no state folder.
@(private = "file")
record_path :: proc(program_folder: string) -> string {
	root := platform.user_dir(.State, "", context.temp_allocator)
	if root == "" { return "" }
	return strings.concatenate({root, platform.USER_DIR_SEPARATOR, program_folder, ".adoption"}, context.temp_allocator)
}

@(private = "file")
record_key :: proc(slug, step: string) -> string { return strings.concatenate({slug, ".", step}, context.temp_allocator) }

// "<slug>.<step>=<value>" lines (temp memory); none: an empty record.
@(private = "file")
record_read :: proc(path: string) -> map[string]string {
	rec := make(map[string]string, context.temp_allocator)
	if path == "" { return rec }
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return rec }
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		eq := strings.index_byte(line, '=')
		if eq <= 0 { continue }
		rec[line[:eq]] = line[eq + 1:]
	}
	return rec
}

// Written whole beside it, then renamed over it: an interruption leaves the earlier record or the new one.
@(private = "file")
record_write :: proc(path: string, rec: map[string]string) {
	if path == "" { return }
	keys, _ := slice.map_keys(rec, context.temp_allocator)
	slice.sort(keys)
	b := strings.builder_make(context.temp_allocator)
	for k in keys {
		v, _ := strings.replace_all(rec[k], "\n", " ", context.temp_allocator)
		fmt.sbprintf(&b, "%s=%s\n", k, v)
	}
	_ = os.make_directory_all(filepath.dir(path))
	next := strings.concatenate({path, ".new"}, context.temp_allocator)
	if os.write_entire_file(next, transmute([]u8)strings.to_string(b)) != nil { return }
	_ = os.rename(next, path)
}

@(private = "file")
record_outcome :: proc(rec: map[string]string, slug, step: string) -> (outcome: Adopt_Outcome, had: bool) {
	text, found := rec[record_key(slug, step)]
	if !found { return .None, false }
	for x in Adopt_Outcome {
		if fmt.tprint(x) == text { return x, true }
	}
	return .None, false
}

@(private = "file")
record_fill_folders :: proc(a: ^Adoption, rec: map[string]string, slug: string) {
	a.folders, _ = record_outcome(rec, slug, "folders")
	a.folders_detail = rec[record_key(slug, "folders_detail")]
}

// The steps not said yet: a final outcome once, a failed install at each start. `shown`: the record's marks to set
// once they are said.
@(private = "file")
record_fill :: proc(a: ^Adoption, rec: map[string]string, slug: string) -> (shown: [dynamic]string) {
	shown = make([dynamic]string, context.temp_allocator)
	f, _ := record_outcome(rec, slug, "folders")
	if final(f) && f != .None && rec[record_key(slug, "folders.shown")] != "1" {
		record_fill_folders(a, rec, slug)
		append(&shown, "folders.shown")
	}
	i, _ := record_outcome(rec, slug, "install")
	if (final(i) && i != .None && rec[record_key(slug, "install.shown")] != "1") || i == .Failed {
		a.install = i
		a.install_detail = rec[record_key(slug, "install_detail")]
		a.command = rec[record_key(slug, "command")]
		a.new_command = rec[record_key(slug, "new_command")]
		a.pinned = rec[record_key(slug, "pinned")] == "1"
		if i != .Failed { append(&shown, "install.shown") }
	}
	return
}

////////////////////////////////
// The words

// What the adoption did, in sentences of the language in use, for a toast or the Installation page ("" when there is
// nothing to say). `bad`: something stayed behind or failed.
adoption_words :: proc(a: Adoption, allocator := context.temp_allocator) -> (words: string, bad: bool) {
	if a.earlier == "" { return "", false }
	if a.folders == .Running || a.install == .Running {
		return fmt.aprintf(i18n.tr("Close %s, then start %s again: its settings and its install move then."), a.earlier, a.name, allocator = allocator), true
	}
	if a.folders == .Busy {
		return fmt.aprintf(i18n.tr("Another start of %s is taking over %s: start it again in a moment."), a.name, a.earlier, allocator = allocator), true
	}
	out := make([dynamic]string, context.temp_allocator)
	#partial switch a.install {
	case .Done:
		append(&out, fmt.tprintf(i18n.tr("%s replaces the install of %s."), a.name, a.earlier))
	case .Administered:
		append(&out, fmt.tprintf(i18n.tr("%s is installed for every account: an administrator replaces it."), a.earlier))
		bad = true
	case .Managed:
		if a.install_detail != "" {
			append(&out, fmt.tprintf(i18n.tr("%s is still installed in %s: the Nix package replaces it."), a.earlier, a.install_detail))
		}
	case .Failed:
		append(&out, fmt.tprintf(i18n.tr("%s could not replace the install of %s: %s"), a.name, a.earlier, a.install_detail))
		bad = true
	}
	#partial switch a.folders {
	case .Done:
		append(&out, fmt.tprintf(i18n.tr("The settings and data of %s came along."), a.earlier))
	case .Copied:
		append(&out, fmt.tprintf(i18n.tr("The settings and data of %s came along as a copy: the earlier folder stays in %s."), a.earlier, a.folders_detail))
	case .Kept_Both:
		append(&out, fmt.tprintf(i18n.tr("The settings of %s stay in %s: %s had its own already."), a.earlier, a.folders_detail, a.name))
		bad = true
	case .Failed:
		append(&out, fmt.tprintf(i18n.tr("The settings of %s could not move (%s): they stay where they were."), a.earlier, a.folders_detail))
		if a.stop { append(&out, fmt.tprintf(i18n.tr("Start %s again to try once more."), a.name)) }
		bad = true
	}
	if a.command != "" && a.new_command != "" && a.command != a.new_command {
		append(&out, fmt.tprintf(i18n.tr("The command %s is now %s."), a.command, a.new_command))
	}
	if a.pinned {
		append(&out, fmt.tprintf(i18n.tr("Pin %s to the taskbar again: the pin of %s starts nothing now."), a.name, a.earlier))
	}
	return strings.join(out[:], " ", allocator), bad
}
