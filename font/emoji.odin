package font

import "base:runtime"
import "core:strings"
import "core:sync"

// Built-in emoji: an emoji font the application hands to the package (`set_emoji_source`: bytes compiled in, or a path)
// that draws the emoji characters no face of a cascade has, in place of the system's emoji font. It is loaded on the first
// emoji character that needs it, never for ordinary text. With the COLR interpreter (Settings.color_engine = .Builtin) the
// emoji are then the same on every platform and at every scale; with .System Direct2D draws them if it can.
//
// Which characters go to the emoji font: those drawn as emoji by default (Emoji_Presentation: faces, hands, regional
// indicators, skin tone modifiers...), and any emoji character followed by U+FE0F (variation selector 16) even when a
// face of the cascade has a text glyph for it, and keycap digits. A character that is emoji only with U+FE0F, followed by
// nothing or by U+FE0E, keeps its text presentation (from the cascade or the system fallback); the emoji font is its last
// resort before .notdef. Sequences (ZWJ, modifiers, flags, tags, keycaps) stay in one face, as for any other emoji.

@(private)
Emoji_Source :: struct {
	mu:     sync.Mutex,
	path:   string,   // heap, owned
	data:   []byte,   // compiled in: not owned
	face:   Font_Id,  // atomic: the loaded face (0: none yet)
	failed: bool,
}

// The emoji font: a font file read from `path`, or font `data` (compiled into the exe with #load: kept, never freed).
// An empty path and no data take the emoji font away. Call it while nothing draws or shapes text.
set_emoji_source :: proc(s: ^State, path := "", data: []byte = nil) {
	context.allocator = runtime.heap_allocator()
	e := &s.emoji
	sync.mutex_lock(&e.mu)
	old := sync.atomic_load(&e.face)
	sync.atomic_store(&e.face, 0)
	delete(e.path)
	e.path = strings.clone(path)
	e.data = data
	e.failed = false
	sync.mutex_unlock(&e.mu)
	if old != 0 { unload(s, old) }
	words_clear(&s.words)
}

// The emoji face, loaded on first use; 0 when there is none or it does not load.
emoji_face :: proc(s: ^State) -> Font_Id {
	e := &s.emoji
	if f := sync.atomic_load(&e.face); f != 0 { return f }
	if !s.ok { return 0 }
	sync.mutex_lock(&e.mu)
	defer sync.mutex_unlock(&e.mu)
	if f := sync.atomic_load(&e.face); f != 0 { return f }
	if e.failed || (e.path == "" && len(e.data) == 0) { return 0 }
	id: Font_Id
	ok: bool
	if len(e.data) > 0 { id, ok = load_embedded(s, e.data) } else { id, ok = load_from_file(s, e.path) }
	if !ok { e.failed = true; return 0 }
	sync.atomic_store(&e.face, id)
	return id
}

// Whether an emoji source is set (without loading it).
has_emoji_source :: proc(s: ^State) -> bool {
	e := &s.emoji
	sync.mutex_lock(&e.mu)
	defer sync.mutex_unlock(&e.mu)
	return !e.failed && (e.path != "" || len(e.data) > 0)
}

// The emoji face if there is one and it has a glyph for `r`, else 0.
@(private)
emoji_pick :: proc(s: ^State, r: rune) -> Font_Id {
	id := emoji_face(s)
	if id == 0 { return 0 }
	f := face_ptr(s, id)
	if f != nil && face_has(f, r) { return id }
	return 0
}

@(private)
in_emoji_table :: proc(table: [][2]rune, r: rune) -> bool {
	lo, hi := 0, len(table)
	for lo < hi {
		mid := (lo + hi) / 2
		switch {
		case r < table[mid][0]: hi = mid
		case r > table[mid][1]: lo = mid + 1
		case: return true
		}
	}
	return false
}

// Characters that can be emoji at all, as a quick filter (almost no text is: nothing below U+203C but # * digits, (c) and (r)).
@(private)
emoji_may :: #force_inline proc(r: rune) -> bool {
	return r >= 0x203C || r == '#' || r == '*' || (r >= '0' && r <= '9') || r == 0xA9 || r == 0xAE
}

// Whether `r` (followed by `next`, 0 at the end) is an emoji to draw with the emoji font.
@(private)
emoji_wanted :: proc(r, next: rune) -> bool {
	if next == 0xFE0E { return false }                       // text presentation asked for
	if r >= 0x1F1E6 && r <= 0x1F1FF { return true }          // regional indicators: flags
	if next == 0xFE0F || next == 0x20E3 { return in_emoji_table(EMOJI_RANGES[:], r) }
	return r > 0xFF && in_emoji_table(EMOJI_PRESENTATION_RANGES[:], r)
}

// Characters the emoji font is the last resort for: any emoji character.
@(private)
emoji_possible :: proc(r: rune) -> bool {
	return r > 0xFF && (in_emoji_table(EMOJI_RANGES[:], r) || (r >= 0x1F1E6 && r <= 0x1F1FF))
}
