// Where a test crashed (src/md/infrastructure/test-crash-site.md): the report's line from its parts, and on Linux a
// child process that faults names its place on stderr and ends by the signal, never spinning.
package crashsite_test

import "core:strings"
import "core:testing"
import crashsite "gt:testkit/crashsite"

@(test)
a_site_says_signal_module_offset_and_symbol :: proc(t: ^testing.T) {
	buf: [512]u8
	n := crashsite.format(buf[:], {signal = "SIGSEGV", pc = 0x401234, memory = true, fault = 0x10, module = "/tmp/x.bin", base = 0x400000, symbol = "tk_ui.build", sym_addr = 0x401200})
	testing.expect_value(t, string(buf[:n]), "crash site: SIGSEGV touching 0x10 at /tmp/x.bin+0x1234 (tk_ui.build+0x34)\n")
	n = crashsite.format(buf[:], {signal = "SIGILL", pc = 0xabc, trap = true})
	line := string(buf[:n])
	testing.expect(t, strings.has_prefix(line, "crash site: SIGILL at 0xabc: a trap"), line)
	// (a line longer than the buffer is cut, never written past it)
	small: [8]u8
	testing.expect_value(t, crashsite.format(small[:], {signal = "SIGSEGV", pc = 1}), 8)
}
