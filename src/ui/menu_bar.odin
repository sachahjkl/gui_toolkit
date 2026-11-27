package ui

// A menu bar: entries (menu_bar_button) whose menus open by a click, by the pointer moving over another entry while one
// is open, and by the keyboard (src/md/features/menus.md, "The menu bar's keys"):
//   - Alt+letter opens the menu whose entry has that access letter, its first item selected; the letter is underlined
//     while Alt is held and while the bar has the keyboard.
//   - F10, or Alt pressed and let go alone, gives the bar the keyboard: its first entry is lit; Left and Right move,
//     Down, Up, Enter and Space open its menu, a letter opens the menu it is the access letter of, Escape, F10, Alt
//     again or a press of the pointer give the keyboard back.
//   - In a menu of the bar, Left and Right go to the menu beside it (Right on an item with a submenu opens it); Escape
//     closes the menu and leaves its entry lit.
//
// The implicit state machine of the bar: Idle (no entry lit, no menu of the bar open) -> Lit (bar.focus: an entry lit,
// keys are the bar's) -> Open (a menu of the bar open) -> Lit by Escape, Idle by a choice or a press outside. The keys
// are read by the first entry built in a build, against the entries of the last build (bar.entries_prev): the bar has
// no begin nor end of its own.

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import "../platform"

// An entry of the last build or this one.
@(private)
Menu_Bar_Entry :: struct {
	box:      Key,    // the entry's box
	menu:     Key,    // its menu (menu_key)
	mnemonic: rune,   // its access letter, lower case (0: none)
}

@(private)
Menu_Bar_State :: struct {
	entries, entries_prev: [dynamic]Menu_Bar_Entry,
	focus:      Key,    // Lit: the entry lit (its box), 0: none
	open:       Key,    // an entry whose menu opens by the keyboard when it is built next (its box)
	keyboard:   bool,   // a menu of the bar was opened by the keyboard: the access letters show while it is open
	read_build: u64,    // the build whose first entry read the bar's keys
	alt_alone:  bool,   // Alt is down and nothing was pressed since (events.odin)
	alt_tapped: bool,   // this build's input let Alt go with nothing pressed while it was down
}

// An entry's words without the "&" that marks its access letter ("&&" is an "&"), the letter in lower case and where it
// is in the words (bytes). No "&": the first letter. at < 0: none.
@(private)
menu_bar_mnemonic :: proc(id: string) -> (shown: string, mnemonic: rune, at: int) {
	words := display_part(id)
	at = -1
	if strings.index_byte(words, '&') < 0 {
		for r, i in words {
			if k := menu_bar_access(r); k != 0 { return words, k, i }
		}
		return words, 0, -1
	}
	b := strings.builder_make(frame_allocator())
	marked := false
	for i := 0; i < len(words); i += 1 {
		c := words[i]
		if c == '&' && i + 1 < len(words) {
			if words[i + 1] == '&' { strings.write_byte(&b, '&'); i += 1; continue }
			if !marked {
				r, _ := utf8.decode_rune_in_string(words[i + 1:])
				mnemonic, at, marked = menu_bar_access(r), strings.builder_len(b), true
			}
			continue
		}
		strings.write_byte(&b, c)
	}
	return strings.to_string(b), mnemonic, at
}

// `r` as an access letter: an ASCII letter in lower case or a digit, what a key of platform.Key types (0: none; a
// letter of another script has no key to match it).
@(private = "file")
menu_bar_access :: proc(r: rune) -> rune {
	switch r {
	case 'a' ..= 'z', '0' ..= '9': return r
	case 'A' ..= 'Z':             return r - 'A' + 'a'
	}
	return 0
}

// The letter a key types, in lower case, for an access letter (0: none).
@(private = "file")
menu_bar_key_rune :: proc(k: platform.Key) -> rune {
	#partial switch k {
	case .A ..= .Z:   return 'a' + rune(int(k) - int(platform.Key.A))
	case .N0 ..= .N9: return '0' + rune(int(k) - int(platform.Key.N0))
	}
	return 0
}

// The entry of the last build whose access letter `k` types (-1: none).
@(private = "file")
menu_bar_find :: proc(s: ^State, k: platform.Key) -> int {
	r := menu_bar_key_rune(k)
	if r == 0 { return -1 }
	for e, i in s.bar.entries_prev { if e.mnemonic == r { return i } }
	return -1
}

@(private = "file")
menu_bar_index :: proc(s: ^State, box: Key) -> int {
	for e, i in s.bar.entries_prev { if e.box == box { return i } }
	return -1
}

// The menu of the bar open now: its entry's index in the last build (-1: none).
@(private)
menu_bar_open_index :: proc(s: ^State) -> int {
	if len(s.menus) == 0 { return -1 }
	for e, i in s.bar.entries_prev { if e.menu == s.menus[0].key { return i } }
	return -1
}

// The bar's keys while no menu is open (with one open, the menu reads them: menu_bar_menu_key), by the first entry of a
// build: Alt+letter, F10 and Alt alone, and the keys of a lit bar.
@(private = "file")
menu_bar_read_keys :: proc(s: ^State) {
	if s.bar.read_build == s.build_index { return }
	s.bar.read_build = s.build_index
	n := len(s.bar.entries_prev)
	if menu_bar_open_index(s) < 0 { s.bar.keyboard = false }
	if s.bar.focus != 0 && menu_bar_index(s, s.bar.focus) < 0 { s.bar.focus = 0 }
	if n == 0 || len(s.menus) > 0 || keys_held_by_dialog(s) { return }
	if s.pressed_any[.Left] || s.pressed_any[.Right] || s.pressed_any[.Middle] { s.bar.focus = 0 }
	toggle := s.bar.alt_tapped
	for e, i in s.events.list {
		if s.events.consumed[i] || e.kind != .Key_Press { continue }
		lit := s.bar.focus != 0
		at := menu_bar_index(s, s.bar.focus)
		taken := true
		switch {
		case e.key == .F10 && e.mods == {}:
			toggle = !toggle
		case e.mods == {.Alt}:
			if k := menu_bar_find(s, e.key); k >= 0 { s.bar.open, s.bar.focus = s.bar.entries_prev[k].box, 0 } else { taken = false }
		case lit && e.mods == {}:
			#partial switch e.key {
			case .Left:   s.bar.focus = s.bar.entries_prev[(at + n - 1) % n].box
			case .Right:  s.bar.focus = s.bar.entries_prev[(at + 1) % n].box
			case .Home:   s.bar.focus = s.bar.entries_prev[0].box
			case .End:    s.bar.focus = s.bar.entries_prev[n - 1].box
			case .Down, .Up, .Return, .Space: s.bar.open, s.bar.focus = s.bar.focus, 0
			case .Escape: s.bar.focus = 0
			case:
				if k := menu_bar_find(s, e.key); k >= 0 { s.bar.open, s.bar.focus = s.bar.entries_prev[k].box, 0 } else { taken = false }
			}
		case:
			taken = false
		}
		if taken { s.events.consumed[i] = true }
	}
	if toggle { s.bar.focus = s.bar.focus == 0 ? s.bar.entries_prev[0].box : 0 }
	if s.bar.focus != 0 { s.anim_busy = true }
}

// A key in the top level of an open menu (menu_level_begin): in a menu of the bar, Left and Right go to the menu beside
// it (`submenu`: the selected item opens one, which Right opens instead), Alt+letter to the menu of that letter. True:
// the key was the bar's, and the menu it opens comes when its entry is built.
@(private)
menu_bar_menu_key :: proc(s: ^State, e: platform.Event, submenu: bool) -> bool {
	at := menu_bar_open_index(s)
	if at < 0 { return false }
	n := len(s.bar.entries_prev)
	to := -1
	switch {
	case e.mods == {} && e.key == .Left:              to = (at + n - 1) % n
	case e.mods == {} && e.key == .Right && !submenu: to = (at + 1) % n
	case e.mods == {.Alt}:                            to = menu_bar_find(s, e.key)
	}
	if to < 0 || to == at { return false }
	s.bar.open = s.bar.entries_prev[to].box
	return true
}

// Escape closed the top level of an open menu: a menu of the bar leaves its entry lit, the keys the bar's.
@(private)
menu_bar_escaped :: proc(s: ^State) {
	if at := menu_bar_open_index(s); at >= 0 { s.bar.focus = s.bar.entries_prev[at].box }
}

// An entry of a menu bar. Returns the id of its menu, to pass to `menu` (valid for the frame). A click toggles the menu;
// while another menu of the bar is open, the pointer over this entry opens this one. `id`'s words may mark the access
// letter with "&" ("&File"; "&&" is an "&"); without one, the first letter is it. The keys: see the head of this file.
menu_bar_button :: proc(id: string) -> string {
	s := gs()
	em := font_size()
	menu_bar_read_keys(s)
	key := key_from_string(parent_box().key, id)
	menu_id := fmt.tprintf("###menu_bar_%x", u64(key))
	open := menu_is_open(menu_id)
	bar_active := menu_bar_open_index(s) >= 0
	shown, mnemonic, at := menu_bar_mnemonic(id)
	// (the entry keeps the caller's name, what follows ### or its words: a test finds it by that)
	words := fmt.tprintf("%s###%s", shown, hash_part(id))
	lit := s.bar.focus == key_from_string(parent_box().key, words)

	push_tags(open || lit ? "selected" : "ghost_button")
	next({width = px(font_text_width(shown) + em * 1.6), height = px(dense(em * 1.9)), text_align = .Center, radius = em * 0.4})
	b := build_box({.Clickable, .Draw_Text, .Draw_Hot_Effects, .Draw_Background}, words)
	pop_tags()
	append(&s.bar.entries, Menu_Bar_Entry{box = b.key, menu = menu_key(menu_id), mnemonic = mnemonic})
	// (the access letter underlined while Alt is held, the bar lit or a menu of it opened by the keyboard)
	if at >= 0 && (.Alt in s.keys_held || s.bar.focus != 0 || s.bar.keyboard) {
		_, w := utf8.decode_rune_in_string(shown[at:])
		d := frame_new(Fuzzy_Draw)
		d.ranges = make([]Fuzzy_Range, 1, frame_allocator())
		d.ranges[0] = {at, at + w}
		d.text, d.underline = b.text, true
		b.custom, b.custom_user = fuzzy_draw, d
	}
	a11y_default(parent_box(), {role = .Menu_Bar, orientation = .X})
	a11y_default(b, {role = .Menu_Item, popup = .Menu, expanded = open})
	sig := signal(b)
	switch {
	case s.bar.open == b.key:
		s.bar.open, s.bar.focus, s.bar.keyboard = 0, 0, true
		menu_open(menu_id, b.rect, b.key, from_keyboard = true)
	case sig.clicked:
		s.bar.focus, s.bar.keyboard = 0, false
		if open { menu_close() } else { menu_open(menu_id, b.rect, b.key) }
	case sig.hovering && bar_active && !open:
		menu_open(menu_id, b.rect, b.key, from_keyboard = s.bar.keyboard)
	}
	return menu_id
}
