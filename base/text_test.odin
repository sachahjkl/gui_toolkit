package base

import "core:testing"

// A-Z and a-z alone change case: the Kelvin sign U+212A and the long s U+017F are no 'k' and no 's'.
@(test)
ascii_case_leaves_other_letters :: proc(t: ^testing.T) {
	testing.expect_value(t, ascii_lower("Sec-WebSocket-Key"), "sec-websocket-key")
	testing.expect_value(t, ascii_lower("\u212Aey \u017Fet"), "\u212Aey \u017Fet")
	testing.expect_value(t, ascii_upper("div \u017F"), "DIV \u017F")
	testing.expect(t, ascii_equal_fold("HOST", "host"))
	testing.expect(t, !ascii_equal_fold("Ho\u017Ft", "Host"))
	testing.expect(t, !ascii_equal_fold("\u212Aey", "key"))
	testing.expect(t, ascii_has_prefix_fold("# Version: 16", "# version"))
	testing.expect(t, !ascii_has_prefix_fold("# Ver\u017Fion", "# vers"))
	testing.expect(t, ascii_contains_fold("Adwaita-DARK", "dark") && ascii_contains_fold("x", ""))
	testing.expect(t, !ascii_contains_fold("Dar\u212A", "dark") && !ascii_contains_fold("da", "dark"))
}
