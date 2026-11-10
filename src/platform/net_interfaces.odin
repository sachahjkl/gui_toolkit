package platform

// The machine's network interfaces and their addresses (Linux: getifaddrs; elsewhere none yet). The address is in network
// order: core:net's IP4_Address is `addr[:4]`, its IP6_Address `transmute([8]u16be)addr`.

Address_Family :: enum u8 { IP4, IP6 }

Interface_Address :: struct {
	name:     string,     // the interface (eth0, wlp3s0, lo)
	family:   Address_Family,
	addr:     [16]u8,     // IPv4: the first 4 bytes
	netmask:  [16]u8,
	up:       bool,       // IFF_UP
	loopback: bool,       // IFF_LOOPBACK
}

interface_addresses_destroy :: proc(list: []Interface_Address, allocator := context.allocator) {
	for a in list { delete(a.name, allocator) }
	delete(list, allocator)
}
