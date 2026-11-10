package ascii

import "core:testing"

// A-Z and a-z alone change case: the Kelvin sign U+212A and the long s U+017F are no 'k' and no 's'.
@(test)
ascii_case_leaves_other_letters :: proc(t: ^testing.T) {
	testing.expect_value(t, lower("Sec-WebSocket-Key"), "sec-websocket-key")
	testing.expect_value(t, lower("\u212Aey \u017Fet"), "\u212Aey \u017Fet")
	testing.expect_value(t, upper("div \u017F"), "DIV \u017F")
	testing.expect(t, equal_fold("HOST", "host"))
	testing.expect(t, !equal_fold("Ho\u017Ft", "Host"))
	testing.expect(t, !equal_fold("\u212Aey", "key"))
	testing.expect(t, has_prefix_fold("# Version: 16", "# version"))
	testing.expect(t, !has_prefix_fold("# Ver\u017Fion", "# vers"))
	testing.expect(t, contains_fold("Adwaita-DARK", "dark") && contains_fold("x", ""))
	testing.expect(t, !contains_fold("Dar\u212A", "dark") && !contains_fold("da", "dark"))
}

// compare_fold: the case ignored first, then the bytes; a prefix comes first.
@(test)
compare_fold_orders_names :: proc(t: ^testing.T) {
	testing.expect(t, compare_fold("bash", "Chrome") < 0)
	testing.expect(t, compare_fold("Chrome", "chrome") < 0)
	testing.expect(t, compare_fold("chrome", "Chrome") > 0)
	testing.expect(t, compare_fold("fire", "Firefox") < 0)
	testing.expect_value(t, compare_fold("same", "same"), 0)
	testing.expect(t, compare_fold("Key", "key") > 0)
}
