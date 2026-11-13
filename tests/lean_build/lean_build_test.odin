// A build with the toolkit's optional parts left out (run_tests passes the defines; docs/builds.md):
//   odin test tests/lean_build -vet -define:TOOLKIT_DEVTOOLS=false -define:FONT_EMBED_FALLBACK=false
package lean_build_test

import "core:os"
import "core:testing"
import "../../src/devtools"
import "../../src/font"

// Without the endpoint, the environment variable starts nothing, and service and stop take the nil.
@(test)
no_devtools_without_the_define :: proc(t: ^testing.T) {
	testing.expect(t, !devtools.TOOLKIT_DEVTOOLS, "built with -define:TOOLKIT_DEVTOOLS=false")
	_ = os.set_env("TOOLKIT_DEVTOOLS", "9399")
	defer os.unset_env("TOOLKIT_DEVTOOLS")
	srv := devtools.start_from_env(nil, "lean")
	testing.expect(t, srv == nil)
	devtools.service(srv, nil, nil)
	devtools.stop(srv)
}

// Without the fallback fonts, their data is empty and a missing system font is not replaced.
@(test)
no_fallback_fonts_without_the_define :: proc(t: ^testing.T) {
	testing.expect(t, !font.FONT_EMBED_FALLBACK, "built with -define:FONT_EMBED_FALLBACK=false")
	testing.expect_value(t, len(font.FALLBACK_UI_DATA), 0)
	testing.expect_value(t, len(font.FALLBACK_MONO_DATA), 0)
	s := new(font.State)
	defer free(s)
	font.init(s)
	defer font.destroy(s)
	_, ok, _ := font.load_system_or_embedded(s, "", font.FALLBACK_UI_DATA)
	testing.expect(t, !ok)
}
