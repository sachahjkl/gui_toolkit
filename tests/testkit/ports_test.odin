// Moved here with the port-block logic it covers (was Wren's src/tools/testenv/testenv_test.odin), adapted to the neutral
// Ports value (an application passes its own base port and span).
//   odin test tests/testkit -vet
package testkit_test

import "core:testing"
import tk "../../testkit"

@(test)
url_moves_default_ports :: proc(t: ^testing.T) {
	p := tk.Ports{base_env = "TK_TEST_BASE_PORT", default_base = 8765, span = 5}
	src := `http://127.0.0.1:8765/a ws://localhost:8767/ws https://[::1]:8766/ U+8766 :87650 x:8770 wpt:8769`
	p.cached = 8765
	testing.expect_value(t, tk.url(&p, src), src)   // the default block: unchanged
	p.cached = 21230
	moved := tk.url(&p, src)
	testing.expect_value(t, moved, `http://127.0.0.1:21230/a ws://localhost:21232/ws https://[::1]:21231/ U+8766 :87650 x:8770 wpt:21234`)
	testing.expect(t, raw_data(tk.url(&p, src)) == raw_data(moved), "the same address is interned once")
	testing.expect_value(t, tk.port(&p, 2), 21232)
	testing.expect_value(t, tk.url(&p, ":8765"), ":8765")   // not after a host character
}
