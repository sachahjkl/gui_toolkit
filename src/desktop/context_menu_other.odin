#+build !windows
#+build !linux
package tk_desktop

import "base:runtime"

@(private)
Context_Menu_Native :: struct {}

@(private) context_menu_native_init  :: proc(ns: ^Context_Menu_Native) {}
@(private) context_menu_native_end   :: proc(ns: ^Context_Menu_Native) {}
@(private) context_menu_native_clear :: proc(ns: ^Context_Menu_Native) {}
@(private) context_menu_native_query :: proc(ns: ^Context_Menu_Native, req: Context_Query_Req, allocator: runtime.Allocator) -> []Context_Item { return nil }
@(private) context_menu_native_invoke :: proc(ns: ^Context_Menu_Native, id: u32, hwnd: rawptr) -> bool { return false }
