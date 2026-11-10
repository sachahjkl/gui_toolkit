package platform

import "core:strings"

// Every IPv4 and IPv6 address of every interface, IPv4 first, in the C library's order otherwise. nil when the system
// says nothing. Free with interface_addresses_destroy.
interface_addresses :: proc(allocator := context.allocator) -> []Interface_Address {
	head: ^Ifaddrs
	if getifaddrs(&head) != 0 { return nil }
	defer freeifaddrs(head)
	out := make([dynamic]Interface_Address, allocator)
	for family in ([]u16{AF_INET, AF_INET6}) {
		for a := head; a != nil; a = a.next {
			if a.addr == nil || a.addr.family != family { continue }
			ia := Interface_Address{
				name     = strings.clone(string(a.name), allocator),
				family   = family == AF_INET ? .IP4 : .IP6,
				up       = a.flags & IFF_UP != 0,
				loopback = a.flags & IFF_LOOPBACK != 0,
			}
			if family == AF_INET {
				copy(ia.addr[:4], (^Sockaddr_In)(a.addr).addr[:])
				if a.netmask != nil { copy(ia.netmask[:4], (^Sockaddr_In)(a.netmask).addr[:]) }
			} else {
				ia.addr = (^Sockaddr_In6)(a.addr).addr
				if a.netmask != nil { ia.netmask = (^Sockaddr_In6)(a.netmask).addr }
			}
			append(&out, ia)
		}
	}
	return out[:]
}

@(private = "file") AF_INET :: 2
@(private = "file") AF_INET6 :: 10
@(private = "file") IFF_UP :: 0x1
@(private = "file") IFF_LOOPBACK :: 0x8

@(private = "file")
Sockaddr :: struct { family: u16 }
@(private = "file")
Sockaddr_In :: struct { family: u16, port: u16be, addr: [4]u8 }
@(private = "file")
Sockaddr_In6 :: struct { family: u16, port: u16be, flowinfo: u32, addr: [16]u8, scope_id: u32 }
@(private = "file")
Ifaddrs :: struct {
	next:    ^Ifaddrs,
	name:    cstring,
	flags:   u32,
	addr:    ^Sockaddr,
	netmask: ^Sockaddr,
	ifu:     ^Sockaddr,
	data:    rawptr,
}

// (core:net has no list of the interfaces on Linux)
foreign import libc_ifaddrs "system:c"

@(default_calling_convention = "c", private = "file")
foreign libc_ifaddrs {
	getifaddrs  :: proc(ifap: ^^Ifaddrs) -> i32 ---
	freeifaddrs :: proc(ifa: ^Ifaddrs) ---
}
