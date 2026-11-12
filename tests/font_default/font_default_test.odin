// The text backend a build gets with no -define: DirectWrite on Windows, the native one elsewhere (where there is no
// DirectWrite: a build that forgot the define had no text).
//   odin test tests/font_default -vet
package font_default_test

import "core:testing"
import "../../src/font"

@(test)
each_system_gets_a_text_backend_by_default :: proc(t: ^testing.T) {
	testing.expect_value(t, font.NATIVE_TEXT, bool(ODIN_OS != .Windows))
}
