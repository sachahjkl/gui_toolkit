package ui

import "core:fmt"
import "core:mem"
import "core:strings"
import i18n "../i18n"
import lucide "../lucide"

// The question before an act that is not taken back (a file deleted for good, a process killed, a service stopped): a
// view, home Dialog (views.odin). A title, a note in the weak text (what comes of it), what it acts on a line each, then
// Cancel (a neutral button: giving up is never a danger) and the act's button in its intent's colours (`act_intent`;
// nil: Danger, a safe act's Success). Enter answers what is safe: Cancel, unless `enter_confirms` (a safe act); the
// button Enter presses says "(Enter)". Escape, the close cross and a press outside cancel. The dialog is as wide as its
// title and its buttons need, up to its most; past that, the title and the words of a button wrap onto more lines and
// the buttons go on more lines: nothing in it is cut nor past its edge.
//
//   ui.confirm_open("delete", {title = "Delete 3 items for good?", note = "...", lines = names, act = "Delete"})
//   ...
//   if ui.confirm_answer("delete") == .Confirmed { delete_them(app) }   // in a later build
//
// It is a view of the Views of the State in use (ui.views()): the window being built. The options are cloned when it
// opens: its strings and its lines can be temporary.

// The words of a confirmation that are not the caller's own question (zero: confirm_default_labels).
Confirm_Labels :: struct { cancel, more, enter: string }   // more: "%d" the lines not shown ("": the toolkit's, by count); enter: "%s" the button's word
// The toolkit's words of a confirmation, in the language in use.
confirm_default_labels :: proc() -> Confirm_Labels {
	// (no `more`: the toolkit's takes the form of its count, which one format cannot)
	return {cancel = i18n.tr("Cancel"), enter = i18n.tr("%s (Enter)")}
}

Confirm_Options :: struct {
	title:          string,
	note:           string,     // what comes of it ("": none)
	lines:          []string,   // what it acts on, a line each, when there is more than one (CONFIRM_LINES_MAX shown)
	act:            string,     // the act's button: "Delete", "Kill"
	act_intent:     Maybe(Intent),   // the act's colour (nil: Danger; with `enter_confirms`, Success)
	enter_confirms: bool,       // Enter acts (a safe act, asked for); else Enter cancels
	width_em:       f32,        // its least width (0: DIALOG_WIDTH_EM), given by the first opening of its id
	labels:         Confirm_Labels,   // zero: confirm_default_labels()
}

// The answer of a confirmation or a prompt: none yet, the act, or given up (Cancel, Escape, the close cross, a press
// outside, its window gone).
Confirm_Answer :: enum u8 { None, Confirmed, Cancelled }

CONFIRM_LINES_MAX :: 8

// The answer code of a confirmation's act and of a prompt's OK (view_ended).
@(private) CONFIRM_ACT :: 1

// Opens the confirmation `id` (registered the first time). One already open takes these options.
confirm_open :: proc(id: string, o: Confirm_Options, instance := "") {
	vs := views()
	if !view_registered(vs, id) { view_register(vs, id, confirm_view, View_Options{width_em = o.width_em}) }
	c := new(Confirm_View, vs.allocator)
	c.o, c.allocator = confirm_clone(o, vs.allocator), vs.allocator
	r := view_open_raw(vs, id, c, typeid_of(Confirm_View), instance, nil)
	ready_made_own(r, c, confirm_view_free, o.title, o.enter_confirms ? lucide.INFO : lucide.ALERT_TRIANGLE)
}

// The answer, taken once: .None until it is answered.
confirm_answer :: proc(id: string, instance := "") -> Confirm_Answer {
	code, ok := view_ended(views(), id, instance)
	if !ok { return .None }
	return code == CONFIRM_ACT ? .Confirmed : .Cancelled
}

@(private = "file")
Confirm_View :: struct {
	o:         Confirm_Options,
	allocator: mem.Allocator,
}

@(private = "file")
confirm_clone :: proc(o: Confirm_Options, allocator: mem.Allocator) -> Confirm_Options {
	c := o
	c.title, c.note, c.act = strings.clone(o.title, allocator), strings.clone(o.note, allocator), strings.clone(o.act, allocator)
	c.lines = make([]string, len(o.lines), allocator)
	for l, i in o.lines { c.lines[i] = strings.clone(l, allocator) }
	c.labels = {strings.clone(o.labels.cancel, allocator), strings.clone(o.labels.more, allocator), strings.clone(o.labels.enter, allocator)}
	return c
}

@(private = "file")
confirm_view_free :: proc(p: rawptr) {
	c := (^Confirm_View)(p)
	context.allocator = c.allocator
	delete(c.o.title); delete(c.o.note); delete(c.o.act)
	for l in c.o.lines { delete(l) }
	delete(c.o.lines)
	delete(c.o.labels.cancel); delete(c.o.labels.more); delete(c.o.labels.enter)
	free(c)
}

@(private = "file")
confirm_view :: proc(v: ^View, c: ^Confirm_View) {
	o := c.o
	labels := o.labels == {} ? confirm_default_labels() : o.labels
	em := font_size()
	if dialog_body("confirm_body") {
		if o.note != "" {
			if tags("weak") {
				next({width = fill()})
				paragraph(fmt.tprintf("%s###confirm_note", text_shown(o.note)))
			}
		}
		// (each one by its name: what the act takes is seen before it acts)
		if len(o.lines) > 1 {
			spacer(px(em * 0.5))
			for l, i in o.lines {
				if i == CONFIRM_LINES_MAX { break }
				next({width = fill(), height = px(em * 1.5), text_pad = em * 0.6})
				label(fmt.tprintf("%s###confirm_line_%d", text_shown(l), i))
			}
			if more := len(o.lines) - CONFIRM_LINES_MAX; more > 0 {
				if tags("weak") {
					next({width = fill(), height = px(em * 1.5), text_pad = em * 0.6})
					more_words := labels.more != "" ? labels.more : i18n.tr(more, "and %d more", "and %d more")
					label(fmt.tprintf("%s###confirm_more", fmt.tprintf(more_words, more)))
				}
			}
		}
	}
	if dialog_buttons("confirm_buttons") {
		cancel_word := o.enter_confirms ? labels.cancel : fmt.tprintf(labels.enter, labels.cancel)
		if button("confirm_cancel", cancel_word, lucide.X, {icon_font = lucide_icons()}).clicked || (!o.enter_confirms && key_press(.Return)) {
			view_end(v, VIEW_CANCELLED)
		}
		// (an act asked for as safe confirms as any OK does; else it is the one not taken back)
		act_word := o.enter_confirms ? fmt.tprintf(labels.enter, o.act) : o.act
		act_intent := o.act_intent.? or_else (o.enter_confirms ? Intent.Success : Intent.Danger)
		act_glyph := act_intent == .Danger ? lucide.TRASH_2 : lucide.CHECK
		if button("confirm_act", act_word, act_glyph, {icon_font = lucide_icons(), intent = act_intent}).clicked || (o.enter_confirms && key_press(.Return)) {
			view_end(v, CONFIRM_ACT)
		}
	}
}

// A ready-made view's record takes what it owns for this opening (the one of a former opening goes), its title and its
// Lucide icon.
@(private)
ready_made_own :: proc(r: ^View_Record, owned: rawptr, free_proc: proc(p: rawptr), title, icon: string) {
	if r.owned != nil && r.owned != owned && r.owned_free != nil { r.owned_free(r.owned) }
	r.owned, r.owned_free, r.data = owned, free_proc, owned
	delete(r.title, r.allocator)
	r.title = strings.clone(title, r.allocator)
	r.icon, r.icon_set = icon, false
}

// A question that takes an answer typed in: a view, home Dialog. A title, a sentence (what to type), one field, Cancel
// and OK. Enter in the field answers (Confirmed: the text is the field's); Escape, Cancel, the close cross or a press
// outside cancel. The field has the keyboard when it opens. `field` is the caller's and must stay valid until the
// answer: a secret stays in its memory only. `secret`: a password, bullets in place of its characters (with `reveal`,
// the eye that shows it: the caller's bool). After a secret is used or given up, line_edit_wipe(field) leaves nothing of
// it in memory.
//
//   ui.prompt_open("unlock", &app.pin, {title = "Unlock", note = "Type the PIN of the key.", secret = true})
//   switch ui.prompt_answer("unlock") {
//   case .Confirmed: unlock(app, ui.line_edit_string(&app.pin)); ui.line_edit_wipe(&app.pin)
//   case .Cancelled: ui.line_edit_wipe(&app.pin)
//   case .None:
//   }

// The words of a prompt that are not the caller's own question (zero: prompt_default_labels).
Prompt_Labels :: struct { cancel, ok: string }
// The toolkit's words of a prompt, in the language in use.
prompt_default_labels :: proc() -> Prompt_Labels { return {cancel = i18n.tr("Cancel"), ok = i18n.tr("OK")} }

Prompt_Options :: struct {
	title:       string,
	note:        string,          // the sentence: what to type ("": none)
	placeholder: string,          // the empty field's hint
	secret:      bool,            // a password: bullets, neither copied nor cut
	reveal:      ^bool,           // with `secret`: the eye that shows it, and whether it is shown (nil: no eye; the caller's)
	act:         string,          // the OK button's word ("": labels.ok)
	width_em:    f32,             // its least width (0: DIALOG_WIDTH_EM), given by the first opening of its id
	labels:      Prompt_Labels,   // zero: prompt_default_labels()
}

// Opens the prompt `id` (registered the first time) on `field`. One already open takes these options.
prompt_open :: proc(id: string, field: ^Line_Edit, o: Prompt_Options, instance := "") {
	vs := views()
	// (a question to type is summoned by a key, Rename's F2: quick, views.md 3.4)
	if !view_registered(vs, id) { view_register(vs, id, prompt_view, View_Options{width_em = o.width_em, quick = true}) }
	p := new(Prompt_View, vs.allocator)
	p.field, p.allocator = field, vs.allocator
	p.o = o
	p.o.title, p.o.note, p.o.placeholder, p.o.act = strings.clone(o.title, vs.allocator), strings.clone(o.note, vs.allocator), strings.clone(o.placeholder, vs.allocator), strings.clone(o.act, vs.allocator)
	p.o.labels = {strings.clone(o.labels.cancel, vs.allocator), strings.clone(o.labels.ok, vs.allocator)}
	r := view_open_raw(vs, id, p, typeid_of(Prompt_View), instance, nil)
	ready_made_own(r, p, prompt_view_free, o.title, o.secret ? lucide.KEY_ROUND : lucide.PENCIL)
}

// The answer, taken once: .None until it is answered. The text is the field's.
prompt_answer :: proc(id: string, instance := "") -> Confirm_Answer {
	return confirm_answer(id, instance)
}

@(private = "file")
Prompt_View :: struct {
	field:     ^Line_Edit,
	o:         Prompt_Options,
	allocator: mem.Allocator,
}

@(private = "file")
prompt_view_free :: proc(p: rawptr) {
	x := (^Prompt_View)(p)
	context.allocator = x.allocator
	delete(x.o.title); delete(x.o.note); delete(x.o.placeholder); delete(x.o.act)
	delete(x.o.labels.cancel); delete(x.o.labels.ok)
	free(x)
}

@(private = "file")
prompt_view :: proc(v: ^View, p: ^Prompt_View) {
	s := gs()
	o := p.o
	labels := o.labels == {} ? prompt_default_labels() : o.labels
	em := font_size()
	if dialog_body("prompt_body") {
		if o.note != "" {
			next({width = fill()})
			paragraph(fmt.tprintf("%s###prompt_note", text_shown(o.note)))
			spacer(px(em * 0.6))
		}
		next({width = fill(), height = px(dense(em * 2.2))})
		res := line_edit("###prompt_field", p.field, {placeholder = o.placeholder, kind = o.secret ? .Secret : .Plain, reveal = o.secret ? o.reveal : nil})
		// (the keyboard is the field's as the dialog opens: it took it from the page)
		if s.focus_key == 0 { s.focus_key = res.box.key }
		if res.committed { view_end(v, CONFIRM_ACT) }
		if res.cancelled { view_end(v, VIEW_CANCELLED) }
	}
	if dialog_buttons("prompt_buttons") {
		if button("prompt_cancel", labels.cancel, lucide.X, {icon_font = lucide_icons()}).clicked {
			view_end(v, VIEW_CANCELLED)
		}
		act := o.act != "" ? o.act : labels.ok
		if button("prompt_ok", act, lucide.CHECK, {icon_font = lucide_icons(), intent = .Primary}).clicked {
			view_end(v, CONFIRM_ACT)
		}
	}
}
