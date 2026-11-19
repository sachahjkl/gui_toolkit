#+build !windows
package shell_thumbnail

// No COM elsewhere: the entries refuse, so a DLL package of the program checks on every system. (Linux's file managers
// run the program itself: desktop's Thumbnails part.)

dll_get_class_object :: proc "system" (rclsid, riid: ^GUID, ppv: ^rawptr) -> HRESULT {
	if ppv != nil { ppv^ = nil }
	return CLASS_E_CLASSNOTAVAILABLE
}

dll_can_unload_now :: proc "system" () -> HRESULT { return S_OK }
