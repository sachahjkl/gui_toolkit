// Package crash_bar: the bar a program shows at the start after its last run ended abnormally (gt:crash wrote a report:
// a crash, a session killed, an exit of its own). One line across the window, under the program's title bar or toolbar:
// what happened, then Open the report, Copy, Report on GitHub (a new issue of the program's repository, the report in
// it), and a cross that dismisses it. It takes a row of the window while it is there and nothing else: no focus, no
// dialog. Nothing is sent anywhere unless the person sends the issue.
//
//   crash.begin_session()
//   if path, ok := crash.last_report(); ok { crash_bar.init(&app.crash_bar, path) }   // at the start, before the loop
//   crash_bar.bar(&app.crash_bar, {name = "Papier", repository = "sachahjkl/papier", version = VERSION})   // each frame
//   crash_bar.destroy(&app.crash_bar)
package tk_crash_bar

import "core:fmt"
import "core:os"
import "core:strings"
import i18n "../i18n"
import lucide "../lucide"
import "../ui"

// What ended the last run, from the report's name (gt:crash: crash-, unclean-, exit-).
Kind :: enum u8 {
	Crash,     // a fault the handler caught (a signal, an exception)
	Unclean,   // the session ended without a report: killed, the machine stopped
	Exit,      // the program ended itself while its session was open
}

Options :: struct {
	name:       string,   // the program's name, in the sentence and the issue's title
	version:    string,   // in the issue's title ("": none)
	repository: string,   // "owner/name" on GitHub: Report on GitHub opens a new issue there ("": no such button)
}

Bar :: struct {
	report:    string,   // owned: the report's path ("": nothing to say, no bar)
	kind:      Kind,
	text:      string,   // owned: the report read (a task reads it at the bar's first build)
	reason:    string,   // a slice of `text`: its `reason:` line ("": none)
	reading:   bool,
	read:      bool,     // the task came back (`text` may still be empty: the file is gone)
	waiting:   Action,   // what waits for the text
	copied_ms: f64,      // when Copy put it on the clipboard (its check shows a moment)
	repository: string,  // owned: the last build's Options.repository, for the task's answer
	title:     string,   // owned: the issue's title, likewise
}

// What a button of the bar asks for once the report is read.
Action :: enum u8 { None, Copy, Report }

// The report of the last run (crash.last_report): the bar shows until dismissed. `path` is copied.
init :: proc(b: ^Bar, path: string) {
	destroy(b)
	if path == "" { return }
	b.report = strings.clone(path)
	b.kind = kind_of(path)
}

destroy :: proc(b: ^Bar) {
	delete(b.report)
	delete(b.text)
	delete(b.repository)
	delete(b.title)
	b^ = {}
}

// The kind of a report, from its file's name.
kind_of :: proc(path: string) -> Kind {
	// (either separator: a report's path is written by the system it ran on, and read where the tests run)
	name := path[strings.last_index_any(path, "/\\") + 1:]
	switch {
	case strings.has_prefix(name, "unclean-"): return .Unclean
	case strings.has_prefix(name, "exit-"):    return .Exit
	}
	return .Crash
}

// What happened, in a sentence (temp memory). The sentence never starts with the program's name: a name written in lower
// case ("cliche") would start it in lower case.
words :: proc(b: ^Bar, name: string) -> string {
	switch b.kind {
	case .Unclean: return fmt.tprintf(i18n.tr("Last time, %s did not close normally: the system or another program ended it."), name)
	case .Exit:    return fmt.tprintf(i18n.tr("Last time, %s ended unexpectedly."), name)
	case .Crash:
		if b.reason != "" { return fmt.tprintf(i18n.tr("Last time, %s stopped unexpectedly (%s)."), name, b.reason) }
		return fmt.tprintf(i18n.tr("Last time, %s stopped unexpectedly."), name)
	}
	return ""
}

// The bar, while there is a report; nothing otherwise. True while it is shown.
bar :: proc(b: ^Bar, o: Options) -> bool {
	if b.report == "" { return false }
	if !b.read && !b.reading { read_start(b) }
	if b.repository != o.repository { delete(b.repository); b.repository = strings.clone(o.repository) }
	title := o.version != "" ? fmt.tprintf(i18n.tr("%s %s stopped unexpectedly"), o.name, o.version) : fmt.tprintf(i18n.tr("%s stopped unexpectedly"), o.name)
	if b.title != title { delete(b.title); b.title = strings.clone(title) }
	em := ui.font_size()
	now := ui.now_ms()
	do_open, do_copy, do_report, close := false, false, false, false
	// (as tall as its sentence: it wraps onto more lines, read whole, rather than be cut)
	bar_h := ui.children_sum()
	bar_h.least = ui.dense(em * 2.6)
	ui.next({width = ui.fill(), height = bar_h, axis = .X, cross = .Center})
	if ui.row(.Center, {.Draw_Background, .Draw_Side_Bottom}, "###crash_bar") {
		ui.spacer(ui.px(em * 0.8))
		if ui.tags("warn") {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column(id = "###crash_bar_words") {
				ui.spacer(ui.px(em * 0.4))
				ui.next({width = ui.fill(), text_pad = 0})
				ui.paragraph(fmt.tprintf("%s###crash_bar_text", words(b, o.name)))
				ui.spacer(ui.px(em * 0.4))
			}
		}
		ui.spacer(ui.px(em * 0.6))
		do_open = ui.button("crash_bar_open", i18n.tr("Open the report"), lucide.FILE_TEXT, {icon_font = ui.lucide_icons(), intent = .Info}).clicked
		ui.spacer(ui.px(em * 0.4))
		copied := b.copied_ms > 0 && now - b.copied_ms < 1500
		do_copy = ui.button("crash_bar_copy", copied ? i18n.tr("Copied") : i18n.tr("Copy"), copied ? lucide.CHECK : lucide.COPY, {icon_font = ui.lucide_icons(), intent = .Neutral}).clicked
		if copied { ui.wake_within(ui.current_state(), 1600) }
		if o.repository != "" {
			ui.spacer(ui.px(em * 0.4))
			do_report = ui.button("crash_bar_report", i18n.tr("Report on GitHub"), lucide.BUG, {icon_font = ui.lucide_icons(), intent = .Warning, tip = i18n.tr("Opens a new issue with the report in it; the whole report is also put on the clipboard")}).clicked
		}
		ui.spacer(ui.px(em * 0.4))
		close = ui.button("crash_bar_dismiss", "", lucide.X, {icon_font = ui.lucide_icons(), tip = i18n.tr("Dismiss")}).clicked
		ui.spacer(ui.px(em * 0.6))
	}
	switch {
	case close:     destroy(b); return false
	case do_open:   ui.open(b.report)
	case do_copy:   act(b, .Copy)
	case do_report: act(b, .Report)
	}
	return true
}

// Does `a` now when the report is read, else when it is.
@(private = "file")
act :: proc(b: ^Bar, a: Action) {
	if !b.read { b.waiting = a; return }
	switch a {
	case .None:
	case .Copy:
		ui.window_clipboard_set(b.text != "" ? b.text : b.report)
		b.copied_ms = ui.now_ms()
	case .Report:
		ui.window_clipboard_set(b.text != "" ? b.text : b.report)
		ui.open(issue_url(b.repository, b.title, b.text), .Url)
	}
	b.waiting = .None
}

@(private = "file")
Read_Job :: struct { b: ^Bar, path, text: string }

// The report is read on a task: a file, not on the interface's thread. Keep the Bar where it is as long as the State.
@(private = "file")
read_start :: proc(b: ^Bar) {
	s := ui.current_state()
	if s == nil { return }
	b.reading = true
	j := new(Read_Job)
	j^ = {b = b, path = strings.clone(b.report)}
	ui.task(s, proc(data: rawptr) {
		j := (^Read_Job)(data)
		if bytes, err := os.read_entire_file(j.path, context.allocator); err == nil { j.text = string(bytes) }
	}, proc(data: rawptr, _: u64) {
		j := (^Read_Job)(data)
		b := j.b
		defer { delete(j.path); free(j) }
		if b.report != j.path { delete(j.text); return }   // (dismissed, or another report since)
		b.reading, b.read = false, true
		delete(b.text)
		b.text, j.text = j.text, ""
		b.reason = reason_of(b.text)
		if b.waiting != .None { act(b, b.waiting) }
	}, j, proc(data: rawptr) {
		j := (^Read_Job)(data)
		delete(j.path)
		delete(j.text)
		free(j)
	})
}

// The `reason:` line of a report's header (a slice of `text`; "": none).
reason_of :: proc(text: string) -> string {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if strings.has_prefix(line, "[") { break }   // (the header ends at the first section)
		if strings.has_prefix(line, "reason: ") { return strings.trim_space(line[len("reason: "):]) }
	}
	return ""
}

// What a new issue's address may hold: GitHub refuses longer ones. The report is cut to fit; the whole of it is on the
// clipboard.
ISSUE_URL_MAX :: 7000

// A new issue of `repository` on GitHub with `title`, and the report in its body, cut to fit ISSUE_URL_MAX (temp memory).
issue_url :: proc(repository, title, report: string) -> string {
	head := fmt.tprintf("https://github.com/%s/issues/new?title=%s&body=", repository, url_escape(title))
	intro := "What I was doing:\n\n\n\nThe crash report (the whole of it is on the clipboard: paste it here if it is cut):\n\n```\n"
	tail := "\n```\n"
	room := ISSUE_URL_MAX - len(head) - len(url_escape(intro)) - len(url_escape(tail))
	// (the lines from the start that fit, whole: the header and the crashed thread come first)
	end, size := 0, 0
	for end < len(report) {
		next := strings.index_byte(report[end:], '\n')
		stop := next < 0 ? len(report) : end + next + 1
		n := escaped_len(report[end:stop])
		if size + n > room { break }
		size += n
		end = stop
	}
	cut := report[:end]
	return strings.concatenate({head, url_escape(intro), url_escape(cut), url_escape(tail)}, context.temp_allocator)
}

@(private = "file")
escaped_len :: proc(s: string) -> (n: int) {
	for i in 0 ..< len(s) {
		switch s[i] {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '.', '_', '~': n += 1
		case: n += 3
		}
	}
	return
}

// Percent-encodes everything but RFC 3986's unreserved characters (temp memory).
url_escape :: proc(s: string) -> string {
	b := strings.builder_make(0, len(s), context.temp_allocator)
	HEX := "0123456789ABCDEF"   // (a variable: a constant string cannot be indexed by a run-time value)
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '.', '_', '~': strings.write_byte(&b, c)
		case:
			strings.write_byte(&b, '%')
			strings.write_byte(&b, HEX[c >> 4])
			strings.write_byte(&b, HEX[c & 15])
		}
	}
	return strings.to_string(b)
}
