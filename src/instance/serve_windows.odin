package tk_instance

import win "core:sys/windows"

// An event: serve_stop sets it, the thread's wait (which also wakes for the window's messages) ends.
@(private)
Wake :: struct { event: win.HANDLE }

@(private)
wake_make :: proc(w: ^Wake) -> bool {
	w.event = win.CreateEventW(nil, false, false, nil)
	return w.event != nil
}

@(private)
wake_ring :: proc(w: ^Wake) { win.SetEvent(w.event) }

@(private)
wake_free :: proc(w: ^Wake) { win.CloseHandle(w.event) }

// Until the instance's window has a message or serve_stop rings.
@(private)
serve_wait :: proc(s: ^Server) {
	handles := [1]win.HANDLE{s.wake.event}
	win.MsgWaitForMultipleObjects(1, &handles[0], false, win.INFINITE, win.QS_ALLINPUT)
}
