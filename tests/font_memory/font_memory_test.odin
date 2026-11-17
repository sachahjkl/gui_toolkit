// Fonts held in memory, loaded again and again: a program, or a test package, makes a font state per window and loads
// the fonts compiled into it into each one.
//   odin test tests/font_memory -collection:gt=src -vet
package font_memory_test

import "core:testing"
import "gt:font"

// (more loads than a test package makes: on Windows, DirectWrite's shared factory keeps every memory font file by key
// for the process, and it crashed or hung in CreateFontFace after about 160 keys, when each load took a new key)
@(private = "file") ROUNDS :: 600

@(test)
an_embedded_font_loads_in_state_after_state :: proc(t: ^testing.T) {
	for i in 0 ..< ROUNDS {
		s := new(font.State)
		font.init(s)
		_, ok := font.load_embedded(s, font.FALLBACK_UI_DATA)
		font.destroy(s)
		free(s)
		if !testing.expectf(t, ok, "round %d: the font loads", i) { return }
	}
}

// A program that reloads its fonts, as a change of its font settings does.
@(test)
an_embedded_font_loads_again_after_unload :: proc(t: ^testing.T) {
	s := new(font.State)
	defer free(s)
	font.init(s)
	defer font.destroy(s)
	for i in 0 ..< ROUNDS {
		id, ok := font.load_embedded(s, font.FALLBACK_UI_DATA)
		if !testing.expectf(t, ok, "round %d: the font loads", i) { return }
		font.unload(s, id)
	}
}
