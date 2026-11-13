package ui

// "Just start typing to search": a printable character typed while no text field has the keyboard gives the keyboard to
// one field (a filter, a search box), which takes the character in the same build. A list that has the keyboard does not
// keep it for its type-ahead: the field gets it.
//
//   if !modal_open { ui.type_to_field(view.search_key) }   // in the build, before the field and the list are built
//   res := ui.line_edit("###search", &view.search, {placeholder = "Filter"})
//   (line_edit returns its box: view.search_key = res.box.key, kept for the next build)
//
// The field's key is its box's (`Box.key`): keep it from the build that made it. A modal dialog or a menu that takes
// typed text is the app's to rule out: it calls this only when they are closed.

// Gives `field` the keyboard when a printable character was typed this build and the keyboard is on no text field.
// True when it did. Call it before the field is built.
type_to_field :: proc(field: Key) -> bool {
	s := gs()
	if field == 0 || s.focus_key == field { return false }
	printable := false
	for r in s.typed { if r >= ' ' && r != 0x7f { printable = true; break } }
	if !printable { return false }
	// (a key with Alt or Ctrl is a shortcut: Alt+P still gives the text "p", which is not typing. Only this frame's
	// presses count: an input method's text comes with none, whatever was held before)
	if .Alt in s.typed_mods || .Ctrl in s.typed_mods { return false }
	if b := s.boxes[s.focus_key]; s.focus_key != 0 && b != nil && is_text_field(b) { return false }
	s.focus_key = field
	return true
}

// Takes `r` out of the text typed this build when it is its first character, so no field built after it gets it: a key
// that is the program's while a field holds a given text (Space in an empty filter opens a preview, and the field never
// shows a space). Only the first: what follows it in the same build was typed after it ("b r" typed at once keeps its
// space). True when it took it. Call it before the field is built.
typed_take :: proc(r: rune) -> bool {
	s := gs()
	if len(s.typed) == 0 || s.typed[0] != r { return false }
	ordered_remove(&s.typed, 0)
	return true
}

// A box that edits text (line_edit, text_edit): it takes keys and text itself and is not a list (lists take keys too,
// for their type-ahead, and scroll their rows).
@(private)
is_text_field :: proc(b: ^Box) -> bool { return .Text_Input in b.flags && .View_Scroll_Y not_in b.flags }
