package ui

import "core:fmt"
import i18n "../i18n"
import lucide "../lucide"

// The question before an act that is not taken back (a file deleted for good, a process killed, a service stopped): a
// title, a note in the weak text (what comes of it), what it acts on a line each, then Cancel (a neutral button: giving
// up is never a danger) and the act's button in its intent's colours (`act_intent`; nil: Danger, a safe act's Success).
// Enter answers what is safe: Cancel, unless `enter_confirms` (a safe act); the button Enter presses says "(Enter)".
// Escape and a press outside cancel, as with any modal. `open` is the caller's: true opens it, the answer closes it.
// The dialog is as wide as its title and its buttons need, up to its most (modal); past that, the title and the words
// of a button wrap onto more lines and the buttons go on more lines: nothing in it is cut nor past its edge.
//
//   switch ui.confirm("delete", &app.asking, {title = "Delete 3 items for good?", note = "...", lines = names, act = "Delete"}) {
//   case .Confirmed: delete_them(app)
//   case .Cancelled, .None:
//   }

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
	width_em:       f32,        // its least width (0: DIALOG_WIDTH_EM); it grows to what is in it
	labels:         Confirm_Labels,   // zero: confirm_default_labels()
}

Confirm_Answer :: enum u8 { None, Confirmed, Cancelled }

CONFIRM_LINES_MAX :: 8

confirm :: proc(id: string, open: ^bool, o: Confirm_Options) -> (answer: Confirm_Answer) {
	was := open^
	labels := o.labels == {} ? confirm_default_labels() : o.labels
	em := font_size()
	if modal(id, open, {width_em = o.width_em}) {
		// (a safe act is a plain question; the others warn before they act)
		if dialog_header("confirm_title", text_shown(o.title), {icon = o.enter_confirms ? lucide.INFO : lucide.ALERT_TRIANGLE, icon_font = lucide_icons(), close = true}) {}
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
				answer, open^ = .Cancelled, false
			}
			// (an act asked for as safe confirms as any OK does; else it is the one not taken back)
			act_word := o.enter_confirms ? fmt.tprintf(labels.enter, o.act) : o.act
			act_intent := o.act_intent.? or_else (o.enter_confirms ? Intent.Success : Intent.Danger)
			act_glyph := act_intent == .Danger ? lucide.TRASH_2 : lucide.CHECK
			if button("confirm_act", act_word, act_glyph, {icon_font = lucide_icons(), intent = act_intent}).clicked || (o.enter_confirms && key_press(.Return)) {
				answer, open^ = .Confirmed, false
			}
		}
	}
	// (closed otherwise: Escape, a press outside)
	if answer == .None && was && !open^ { answer = .Cancelled }
	return
}

// A question that takes an answer typed in: a title, a sentence (what to type), one field, Cancel and OK. Enter in the
// field answers (Confirmed: the text is the field's); Escape, Cancel or a press outside cancel, as with any modal. The
// field has the keyboard when it opens. `f` and `open` are the caller's: true opens it, the answer closes it.
// `secret`: a password, bullets in place of its characters (with `reveal`, the eye that shows it: the caller's bool).
// After a secret is used or given up, line_edit_wipe(f) leaves nothing of it in memory.
//
//   switch ui.prompt("unlock", &app.asking, &app.pin, {title = "Unlock", note = "Type the PIN of the key.", secret = true}) {
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
	reveal:      ^bool,           // with `secret`: the eye that shows it, and whether it is shown (nil: no eye)
	act:         string,          // the OK button's word ("": labels.ok)
	width_em:    f32,             // its least width (0: DIALOG_WIDTH_EM); it grows to what is in it
	labels:      Prompt_Labels,   // zero: prompt_default_labels()
}

prompt :: proc(id: string, open: ^bool, f: ^Line_Edit, o: Prompt_Options) -> (answer: Confirm_Answer) {
	s := gs()
	was := open^
	labels := o.labels == {} ? prompt_default_labels() : o.labels
	em := font_size()
	if modal(id, open, {width_em = o.width_em}) {
		if dialog_header("prompt_title", text_shown(o.title), {icon = o.secret ? lucide.KEY_ROUND : lucide.PENCIL, icon_font = lucide_icons(), close = true}) {}
		if dialog_body("prompt_body") {
			if o.note != "" {
				next({width = fill()})
				paragraph(fmt.tprintf("%s###prompt_note", text_shown(o.note)))
				spacer(px(em * 0.6))
			}
			next({width = fill(), height = px(dense(em * 2.2))})
			res := line_edit("###prompt_field", f, {placeholder = o.placeholder, kind = o.secret ? .Secret : .Plain, reveal = o.secret ? o.reveal : nil})
			// (the keyboard is the field's as the dialog opens: it took it from the page)
			if s.focus_key == 0 { s.focus_key = res.box.key }
			if res.committed { answer, open^ = .Confirmed, false }
			if res.cancelled { answer, open^ = .Cancelled, false }
		}
		if dialog_buttons("prompt_buttons") {
			if button("prompt_cancel", labels.cancel, lucide.X, {icon_font = lucide_icons()}).clicked {
				answer, open^ = .Cancelled, false
			}
			act := o.act != "" ? o.act : labels.ok
			if button("prompt_ok", act, lucide.CHECK, {icon_font = lucide_icons(), intent = .Primary}).clicked {
				answer, open^ = .Confirmed, false
			}
		}
	}
	// (closed otherwise: Escape, a press outside)
	if answer == .None && was && !open^ { answer = .Cancelled }
	return
}
