type: Changed

**`platform` API made system-neutral**: `platform.wake_handle` now returns an opaque `rawptr` (paired with the new `platform.wake_signal`) instead of a Win32 `HANDLE`, and the new `platform.native_surface_handles` hands a renderer the window's native handles through a neutral `Surface_Handles` (Windows HWND, Wayland `wl_display` + `wl_surface`, or X11 connection + window) so `render` can make a surface on any system without a Win32 type in the signature.
