package render

import win "core:sys/windows"

// win.FAILED / win.SUCCEEDED are only declared in core:sys/windows on Windows, so the Direct3D code (which is never
// run on another system, but is still type-checked there when a file is shared) uses these two wrappers instead. The
// HRESULT type itself is declared on every target, so the sign test compiles everywhere; on Windows it is exactly what
// win.FAILED / win.SUCCEEDED do (the high bit is the failure bit, i.e. a negative HRESULT).
@(private)
hr_failed :: #force_inline proc "contextless" (hr: win.HRESULT) -> bool { return i32(hr) < 0 }

@(private)
hr_ok :: #force_inline proc "contextless" (hr: win.HRESULT) -> bool { return i32(hr) >= 0 }
