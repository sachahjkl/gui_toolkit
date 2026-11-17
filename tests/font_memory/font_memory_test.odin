// Fonts held in memory, loaded again and again: a program, or a test package, makes a font state per window and loads
// the fonts compiled into it into each one.
//   odin test tests/font_memory -collection:gt=src -vet
package font_memory_test

import "core:testing"
import "gt:font"

// (more rounds than a test package has sessions: on Windows, DirectWrite's shared factory crashed or hung in
// CreateFontFace once its memory font loader had been unregistered and registered again, a state after another)
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
