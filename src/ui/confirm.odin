package ui

import "core:fmt"
import lucide "../lucide"

// The question before an act that is not taken back (a file deleted for good, a process killed, a service stopped): a
// title, a note in the weak text (what comes of it), what it acts on a line each, then Cancel and the act's button in
// the danger colours (a safe act's: the success colours). Enter answers what is safe: Cancel, unless `enter_confirms` (a safe act); the button Enter presses
// says "(Enter)". Escape and a press outside cancel, as with any modal. `open` is the caller's: true opens it, the
// answer closes it.
//
//   switch ui.confirm("delete", &app.asking, {title = "Delete 3 items for good?", note = "...", lines = names, act = "Delete"}) {
//   case .Confirmed: delete_them(app)
//   case .Cancelled, .None:
//   }

// The words of a confirmation that are not the caller's own question (translated: a program sets them once).
Confirm_Labels :: struct { cancel, more, enter: string }   // more: "%d" the lines not shown; enter: "%s" the button's word
CONFIRM_LABELS :: Confirm_Labels{cancel = "Cancel", more = "and %d more", enter = "%s (Enter)"}

Confirm_Options :: struct {
	title:          string,
	note:           string,     // what comes of it ("": none)
	lines:          []string,   // what it acts on, a line each, when there is more than one (CONFIRM_LINES_MAX shown)
	act:            string,     // the act's button: "Delete", "Kill"
	enter_confirms: bool,       // Enter acts (a safe act, asked for); else Enter cancels
	width_em:       f32,        // 0: CONFIRM_WIDTH_EM
	labels:         Confirm_Labels,   // zero: CONFIRM_LABELS
}

Confirm_Answer :: enum u8 { None, Confirmed, Cancelled }

CONFIRM_WIDTH_EM :: 29
CONFIRM_LINES_MAX :: 8

confirm :: proc(id: string, open: ^bool, o: Confirm_Options) -> (answer: Confirm_Answer) {
	was := open^
	labels := o.labels == {} ? CONFIRM_LABELS : o.labels
	em := font_size()
	w := em * (o.width_em > 0 ? o.width_em : CONFIRM_WIDTH_EM)
	if modal(id, w, open) {
		pad := em * 1.2
		// (a safe act is a plain question; the others warn before they act)
		dialog_header("confirm_title", text_shown(o.title), o.enter_confirms ? lucide.INFO : lucide.TRIANGLE_ALERT, lucide_icons())
		if style({width = px(w)}) {
			spacer(px(pad))
			next({width = px(w), height = children_sum()})
			if row() {
				spacer(px(pad))
				next({width = px(w - 2 * pad), height = children_sum(), axis = .Y})
				if column() {
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
								label(fmt.tprintf("%s###confirm_more", fmt.tprintf(labels.more, more)))
							}
						}
					}
					spacer(px(em * 1.1))
					next({width = fill(), height = children_sum()})
					if row() {
						spacer(fill())
						cancel_word := o.enter_confirms ? labels.cancel : fmt.tprintf(labels.enter, labels.cancel)
						if button_icon("confirm_cancel", lucide.X, cancel_word, icon_font = lucide_icons(), intent = .Cancel).clicked || (!o.enter_confirms && key_press(.Return)) {
							answer, open^ = .Cancelled, false
						}
						spacer(px(em * 0.6))
						// (an act asked for as safe confirms as any OK does; else it is the one not taken back)
						act_word := o.enter_confirms ? fmt.tprintf(labels.enter, o.act) : o.act
						act_glyph := o.enter_confirms ? lucide.CHECK : lucide.TRASH_2
						act_intent := o.enter_confirms ? Intent.Success : Intent.Danger
						if button_icon("confirm_act", act_glyph, act_word, icon_font = lucide_icons(), intent = act_intent).clicked || (o.enter_confirms && key_press(.Return)) {
							answer, open^ = .Confirmed, false
						}
					}
				}
			}
			spacer(px(pad))
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
// After a secret is used or given up, field_wipe(f) leaves nothing of it in memory.
//
//   switch ui.prompt("unlock", &app.asking, &app.pin, {title = "Unlock", note = "Type the PIN of the key.", secret = true}) {
//   case .Confirmed: unlock(app, ui.field_string(&app.pin)); ui.field_wipe(&app.pin)
//   case .Cancelled: ui.field_wipe(&app.pin)
//   case .None:
//   }

// The words of a prompt that are not the caller's own question (translated: a program sets them once).
Prompt_Labels :: struct { cancel, ok: string }
PROMPT_LABELS :: Prompt_Labels{cancel = "Cancel", ok = "OK"}

Prompt_Options :: struct {
	title:       string,
	note:        string,          // the sentence: what to type ("": none)
	placeholder: string,          // the empty field's hint
	secret:      bool,            // a password: bullets, neither copied nor cut
	reveal:      ^bool,           // with `secret`: the eye that shows it, and whether it is shown (nil: no eye)
	act:         string,          // the OK button's word ("": labels.ok)
	width_em:    f32,             // 0: CONFIRM_WIDTH_EM
	labels:      Prompt_Labels,   // zero: PROMPT_LABELS
}

prompt :: proc(id: string, open: ^bool, f: ^Text_Field, o: Prompt_Options) -> (answer: Confirm_Answer) {
	s := gs()
	was := open^
	labels := o.labels == {} ? PROMPT_LABELS : o.labels
	em := font_size()
	w := em * (o.width_em > 0 ? o.width_em : CONFIRM_WIDTH_EM)
	if modal(id, w, open) {
		pad := em * 1.2
		dialog_header("prompt_title", text_shown(o.title), o.secret ? lucide.KEY_ROUND : lucide.PENCIL, lucide_icons())
		if style({width = px(w)}) {
			spacer(px(pad))
			next({width = px(w), height = children_sum()})
			if row() {
				spacer(px(pad))
				next({width = px(w - 2 * pad), height = children_sum(), axis = .Y})
				if column() {
					if o.note != "" {
						next({width = fill()})
						paragraph(fmt.tprintf("%s###prompt_note", text_shown(o.note)))
						spacer(px(em * 0.6))
					}
					next({width = fill(), height = px(dense(em * 2.2))})
					res := line_edit("###prompt_field", f, o.placeholder, secret = o.secret, reveal = o.secret ? o.reveal : nil)
					// (the keyboard is the field's as the dialog opens: it took it from the page)
					if s.focus_key == 0 { s.focus_key = res.box.key }
					if res.committed { answer, open^ = .Confirmed, false }
					if res.cancelled { answer, open^ = .Cancelled, false }
					spacer(px(em * 1.1))
					next({width = fill(), height = children_sum()})
					if row() {
						spacer(fill())
						if button_icon("prompt_cancel", lucide.X, labels.cancel, icon_font = lucide_icons(), intent = .Cancel).clicked {
							answer, open^ = .Cancelled, false
						}
						spacer(px(em * 0.6))
						act := o.act != "" ? o.act : labels.ok
						if button_icon("prompt_ok", lucide.CHECK, act, icon_font = lucide_icons(), intent = .Primary).clicked {
							answer, open^ = .Confirmed, false
						}
					}
				}
			}
			spacer(px(pad))
		}
	}
	// (closed otherwise: Escape, a press outside)
	if answer == .None && was && !open^ { answer = .Cancelled }
	return
}
