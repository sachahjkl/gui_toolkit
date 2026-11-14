#+build windows
package platform

// Printing on Windows (print.odin): the common Print dialog (PrintDlgW: the printer, its preferences, the copies),
// then one page drawn with GDI on the printer's device context: the picture, alpha over white, stretched where
// print_fit places it in the printable area (HORZRES x VERTRES, at LOGPIXELSX dots an inch). The dialog is modal to
// `owner`; the calling thread waits for the person, then for the spooler to take the page.

import win "core:sys/windows"

foreign import gdi32 "system:Gdi32.lib"

@(private = "file")
DOCINFOW :: struct {
	cbSize:       i32,
	lpszDocName:  win.LPCWSTR,
	lpszOutput:   win.LPCWSTR,
	lpszDatatype: win.LPCWSTR,
	fwType:       win.DWORD,
}

@(default_calling_convention = "system", private = "file")
foreign gdi32 {
	StartDocW :: proc(hdc: win.HDC, lpdi: ^DOCINFOW) -> i32 ---
	EndDoc    :: proc(hdc: win.HDC) -> i32 ---
	AbortDoc  :: proc(hdc: win.HDC) -> i32 ---
	StartPage :: proc(hdc: win.HDC) -> i32 ---
	EndPage   :: proc(hdc: win.HDC) -> i32 ---
	SetStretchBltMode :: proc(hdc: win.HDC, mode: i32) -> i32 ---
	SetBrushOrgEx :: proc(hdc: win.HDC, x, y: i32, lppt: ^win.POINT) -> win.BOOL ---
}

@(private = "file") CAPS_HORZRES    :: 8
@(private = "file") CAPS_VERTRES    :: 10
@(private = "file") CAPS_LOGPIXELSX :: 88

print_image :: proc(owner: ^Window, title: string, rgba: []u8, size: [2]int) -> Print_Status {
	if size.x <= 0 || size.y <= 0 || len(rgba) < size.x * size.y * 4 { return .Failed }
	pd := win.PRINTDLGW{lStructSize = size_of(win.PRINTDLGW), Flags = win.PD_RETURNDC | win.PD_NOSELECTION | win.PD_NOPAGENUMS | win.PD_USEDEVMODECOPIESANDCOLLATE, nCopies = 1}
	if owner != nil { pd.hwndOwner = owner.hwnd }
	if !win.PrintDlgW(&pd) { return win.CommDlgExtendedError() == 0 ? .Cancelled : .Failed }
	defer {
		if pd.hDevMode != nil { win.GlobalFree(rawptr(pd.hDevMode)) }
		if pd.hDevNames != nil { win.GlobalFree(rawptr(pd.hDevNames)) }
		if pd.hDC != nil { win.DeleteDC(pd.hDC) }
	}
	dc := pd.hDC
	if dc == nil { return .Failed }

	// the pixels as GDI takes them: BGRA rows from the top, alpha laid over white
	w, h := size.x, size.y
	bgra := make([]u8, w * h * 4, context.temp_allocator)
	for i in 0 ..< w * h {
		p := rgba[i * 4:][:4]
		a := u32(p[3])
		over :: proc(c, a: u32) -> u8 { return u8((c * a + 255 * (255 - a) + 127) / 255) }
		bgra[i * 4 + 0], bgra[i * 4 + 1], bgra[i * 4 + 2], bgra[i * 4 + 3] = over(u32(p[2]), a), over(u32(p[1]), a), over(u32(p[0]), a), 255
	}
	bmi: win.BITMAPINFO
	bmi.bmiHeader = {biSize = size_of(win.BITMAPINFOHEADER), biWidth = i32(w), biHeight = -i32(h), biPlanes = 1, biBitCount = 32, biCompression = win.BI_RGB}

	page := [2]f64{f64(win.GetDeviceCaps(dc, CAPS_HORZRES)), f64(win.GetDeviceCaps(dc, CAPS_VERTRES))}
	dpi := f64(win.GetDeviceCaps(dc, CAPS_LOGPIXELSX))
	// (the printable area already leaves out what the printer cannot reach: no margin of its own)
	x, y, pw, ph := print_fit(size, page, 0, dpi > 0 ? dpi : PRINT_PICTURE_DPI)
	if pw <= 0 || ph <= 0 { return .Failed }

	doc := DOCINFOW{cbSize = size_of(DOCINFOW), lpszDocName = win.utf8_to_wstring(title != "" ? title : "Picture")}
	if StartDocW(dc, &doc) <= 0 { return .Failed }
	if StartPage(dc) <= 0 { AbortDoc(dc); return .Failed }
	// (HALFTONE: a picture made smaller keeps its detail; it needs the brush origin set after it)
	SetStretchBltMode(dc, win.HALFTONE)
	SetBrushOrgEx(dc, 0, 0, nil)
	drawn := win.StretchDIBits(dc, i32(x), i32(y), i32(pw), i32(ph), 0, 0, i32(w), i32(h), raw_data(bgra), &bmi, win.DIB_RGB_COLORS, win.SRCCOPY)
	if drawn == 0 || EndPage(dc) <= 0 { AbortDoc(dc); return .Failed }
	if EndDoc(dc) <= 0 { return .Failed }
	return .Printed
}
