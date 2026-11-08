#+build linux
// Gives a headless Wayland compositor a pointer: a seat with no device has no pointer capability, and a client never gets
// a wl_pointer. This program makes one zwlr_virtual_pointer_v1 and stays until it is killed; tk desktop_tests starts
// it, and the tests move the seat's cursor with swaymsg. By dlopen, as platform/linux_lib.odin: no development package.
package virtual_pointer

import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:time"

Proxy :: distinct rawptr
Wl_Message :: struct { name, signature: cstring, types: [^]^Wl_Interface }
Wl_Interface :: struct {
	name: cstring,
	version: i32,
	method_count: i32,
	methods: [^]Wl_Message,
	event_count: i32,
	events: [^]Wl_Message,
}

no_types: [8]^Wl_Interface
pointer_iface := Wl_Interface{"zwlr_virtual_pointer_v1", 1, 0, nil, 0, nil}
manager_types := [2]^Wl_Interface{nil, &pointer_iface}   // (seat: any, new id)
manager_methods := [1]Wl_Message{{"create_virtual_pointer", "?on", raw_data(manager_types[:])}}
manager_iface := Wl_Interface{"zwlr_virtual_pointer_manager_v1", 1, 1, raw_data(manager_methods[:]), 0, nil}

marshal_flags: proc "c" (p: Proxy, opcode: u32, interface: ^Wl_Interface, version, flags: u32, #c_vararg args: ..any) -> Proxy
manager: Proxy
registry_bind_op :: 0

Listener :: struct {
	global:        proc "c" (data: rawptr, registry: Proxy, name: u32, iface: cstring, version: u32),
	global_remove: proc "c" (data: rawptr, registry: Proxy, name: u32),
}
listener := Listener{
	proc "c" (data: rawptr, registry: Proxy, name: u32, iface: cstring, version: u32) {
		if string(iface) == "zwlr_virtual_pointer_manager_v1" {
			manager = marshal_flags(registry, registry_bind_op, &manager_iface, 1, 0, name, manager_iface.name, u32(1), nil)
		}
	},
	proc "c" (data: rawptr, registry: Proxy, name: u32) {},
}

main :: proc() {
	lib, ok := dynlib.load_library("libwayland-client.so.0")
	if !ok { fmt.eprintln("no libwayland-client"); os.exit(1) }
	sym :: proc(lib: dynlib.Library, name: string) -> rawptr {
		p, _ := dynlib.symbol_address(lib, name)
		if p == nil { fmt.eprintln("missing", name); os.exit(1) }
		return p
	}
	display_connect := cast(proc "c" (name: cstring) -> Proxy)sym(lib, "wl_display_connect")
	roundtrip := cast(proc "c" (d: Proxy) -> i32)sym(lib, "wl_display_roundtrip")
	add_listener := cast(proc "c" (p: Proxy, l, data: rawptr) -> i32)sym(lib, "wl_proxy_add_listener")
	get_version := cast(proc "c" (p: Proxy) -> u32)sym(lib, "wl_proxy_get_version")
	marshal_flags = auto_cast sym(lib, "wl_proxy_marshal_flags")
	registry_iface := cast(^Wl_Interface)sym(lib, "wl_registry_interface")

	display := display_connect(nil)
	if display == nil { fmt.eprintln("no compositor"); os.exit(1) }
	WL_DISPLAY_GET_REGISTRY :: 1
	registry := marshal_flags(display, WL_DISPLAY_GET_REGISTRY, registry_iface, get_version(display), 0, nil)
	add_listener(registry, &listener, nil)
	roundtrip(display)
	if manager == nil { fmt.eprintln("the compositor has no virtual pointers"); os.exit(1) }
	CREATE_VIRTUAL_POINTER :: 0
	pointer := marshal_flags(manager, CREATE_VIRTUAL_POINTER, &pointer_iface, 1, 0, nil, nil)
	if pointer == nil { fmt.eprintln("no virtual pointer"); os.exit(1) }
	roundtrip(display)
	for { time.sleep(time.Hour) }
}
