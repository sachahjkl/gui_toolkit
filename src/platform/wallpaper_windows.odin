#+build windows
package platform

import win "core:sys/windows"

@(private = "file") SPI_SETDESKWALLPAPER :: 0x0014
@(private = "file") SPIF_UPDATEINIFILE :: 0x01
@(private = "file") SPIF_SENDCHANGE :: 0x02

// SystemParametersInfo: the picture for every screen, written to the person's profile and told to the windows that
// listen. It answers at once; its broadcast can wait for a hung window, hence the worker.
set_wallpaper :: proc(path: string) -> Wallpaper_Result {
	wpath := win.utf8_to_wstring(path, context.temp_allocator)
	if wpath == nil { return .Failed }
	if win.GetFileAttributesW(wpath) == win.INVALID_FILE_ATTRIBUTES { return .Failed }
	if !win.SystemParametersInfoW(SPI_SETDESKWALLPAPER, 0, rawptr(wpath), SPIF_UPDATEINIFILE | SPIF_SENDCHANGE) { return .Failed }
	return .Set
}
