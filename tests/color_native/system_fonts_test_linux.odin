package color_native_test

// The system's fonts on Linux (fontconfig): a family that is not installed stands for the installed one the configuration
// binds to its name, and a generic family for the font fontconfig picks. A page that asks for "Courier New", monospace gets a
// fixed-width font, not the toolkit's own sans.

import "core:os"
import "core:strings"
import "core:testing"
import "../../src/font"

// What `fc-match <pattern>` says the family is ("" when fc-match is not there).
@(private = "file")
fc_match_family :: proc(pattern: string) -> string {
	state, out, _, err := os.process_exec(os.Process_Desc{command = {"fc-match", "--format=%{family[0]}", pattern}}, context.temp_allocator)
	if err != nil || !state.success { return "" }
	return strings.trim_space(string(out))
}

@(test)
an_alias_and_a_generic_family_resolve :: proc(t: ^testing.T) {
	s := new(font.State)
	defer free(s)
	font.init(s, font.DEFAULT_SETTINGS)
	defer font.destroy(s)
	if !testing.expect(t, s.ok, "the font stack did not start") { return }

	// a generic family: always there, and the face fontconfig picks has the advance of a fixed-width font
	testing.expect(t, font.has_system_family(s, "monospace"))
	mono, ok := font.load_system(s, "monospace", 400, .Normal)
	if testing.expect(t, ok, "monospace loads") {
		space, m := font.text_width(s, mono, 20, " "), font.text_width(s, mono, 20, "m")
		testing.expectf(t, abs(space - m) < 0.01, "monospace: a space is %v wide, an m %v", space, m)
	}

	// an alias: when the configuration binds "Courier New" to an installed font (Liberation Mono, by 30-metric-aliases.conf)
	if bound := fc_match_family("Courier New"); bound != "" && bound != "Courier New" && font.has_system_family(s, bound) {
		testing.expectf(t, font.has_system_family(s, "Courier New"), "Courier New is not taken for %s", bound)
		courier, cok := font.load_system(s, "Courier New", 400, .Normal)
		target, tok := font.load_system(s, bound, 400, .Normal)
		testing.expect(t, cok && tok)
		testing.expectf(t, courier == target, "Courier New: face %v, %s: face %v", courier, bound, target)
	}

	// fontconfig answers every name with its default font: a name nothing binds is still absent
	testing.expect(t, !font.has_system_family(s, "No Such Family 1234"))
	_, nok := font.load_system(s, "No Such Family 1234", 400, .Normal)
	testing.expect(t, !nok)
}
