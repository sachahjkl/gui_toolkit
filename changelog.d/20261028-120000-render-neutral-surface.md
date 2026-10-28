type: Changed

**`render.init` takes a neutral surface, not an `HWND`**: `render.init(&r, surface: platform.Surface_Handles, size, transparent, space)` opens the renderer on the native handles the platform package fills (`platform.native_surface_handles(window)`), the HWND on Windows and the Wayland or XCB handles on Linux; `render.init_window(&r, window, size, ...)` is the convenience form. `surface_init` / `surface_create` (second windows) take the same neutral handles. No Direct3D, DXGI or Win32 type appears in the renderer's public signatures.
