// platform.interface_addresses: on Linux the loopback interface is there with 127.0.0.1, up and marked loopback; elsewhere
// the list is empty.
//   odin test tests/netif -vet
package netif_test

import "core:testing"
import "../../src/platform"

@(test)
the_loopback_address_is_listed :: proc(t: ^testing.T) {
	list := platform.interface_addresses()
	defer platform.interface_addresses_destroy(list)
	when ODIN_OS != .Linux {
		testing.expect_value(t, len(list), 0)
		return
	}
	found := false
	seen_ip6 := false
	for a in list {
		if a.family == .IP6 { seen_ip6 = true }
		// (IPv4 first)
		if a.family == .IP4 { testing.expect(t, !seen_ip6, "IPv4 before IPv6") }
		if a.family == .IP4 && a.addr[0] == 127 && a.addr[3] == 1 {
			found = true
			testing.expect(t, a.loopback && a.up, a.name)
			testing.expect_value(t, a.netmask[0], u8(255))
		}
	}
	testing.expect(t, found, "127.0.0.1 is listed")
}
