#+build windows
package platform

// Printing on Windows (print.odin): the common Print dialog (PrintDlgW: the printer, its preferences, the copies),
// then one page drawn with GDI on the printer's device context: the picture, alpha over white, stretched where
// print_fit places it in the printable area (HORZRES x VERTRES, at LOGPIXELSX dots an inch). The dialog is modal to
// `owner`; the calling thread waits for the person, then for the spooler to take the page.
//
// A document (print_document): the common Print dialog of Windows 2000 and later (PrintDlgExW: the page range and
// the copies), then each page in the range rendered by the program at the printer's own resolution, placed by
// print_page_fit, drawn one band at a time (memory bounded at 1200 dots an inch), 1:1 (no stretch).

import "core:math"
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
	ResetDCW  :: proc(hdc: win.HDC, lpdm: ^win.DEVMODEW) -> win.HDC ---
}

@(private = "file") CAPS_HORZRES         :: 8
@(private = "file") CAPS_VERTRES         :: 10
@(private = "file") CAPS_LOGPIXELSX      :: 88
@(private = "file") CAPS_LOGPIXELSY      :: 90
@(private = "file") CAPS_PHYSICALWIDTH   :: 110
@(private = "file") CAPS_PHYSICALHEIGHT  :: 111
@(private = "file") CAPS_PHYSICALOFFSETX :: 112
@(private = "file") CAPS_PHYSICALOFFSETY :: 113

@(private = "file") DM_ORIENTATION     :: 0x1
@(private = "file") DMORIENT_PORTRAIT  :: 1
@(private = "file") DMORIENT_LANDSCAPE :: 2

// The ranges a person can type in the dialog ("1-3, 7, 9-12"): more is refused by the dialog itself.
@(private = "file") PRINT_MAX_RANGES :: 32

print_document :: proc(owner: ^Window, doc: Print_Document) -> Print_Status {
	if doc.page_count <= 0 || doc.page_size == nil || doc.render == nil { return .Failed }
	// (the dialog is a property sheet that needs COM; a thread already in another mode keeps it, the dialog works there)
	com := win.CoInitializeEx(nil, .APARTMENTTHREADED)
	defer if com >= 0 { win.CoUninitialize() }

	ranges: [PRINT_MAX_RANGES]win.PRINTPAGERANGE
	ranges[0] = {1, win.DWORD(doc.page_count)}
	pd := win.PRINTDLGEXW {
		lStructSize    = size_of(win.PRINTDLGEXW),
		Flags          = win.PD_RETURNDC | win.PD_NOSELECTION | win.PD_NOCURRENTPAGE | win.PD_USEDEVMODECOPIESANDCOLLATE,
		nPageRanges    = 1,
		nMaxPageRanges = PRINT_MAX_RANGES,
		lpPageRanges   = &ranges[0],
		nMinPage       = 1,
		nMaxPage       = win.DWORD(doc.page_count),
		nCopies        = 1,
		nStartPage     = win.START_PAGE_GENERAL,
	}
	// (PrintDlgEx refuses no owner)
	if owner != nil { pd.hwndOwner = owner.hwnd } else { pd.hwndOwner = win.GetDesktopWindow() }
	hr := win.PrintDlgExW(&pd)
	defer {
		if pd.hDevMode != nil { win.GlobalFree(rawptr(pd.hDevMode)) }
		if pd.hDevNames != nil { win.GlobalFree(rawptr(pd.hDevNames)) }
		if pd.hDC != nil { win.DeleteDC(pd.hDC) }
	}
	if hr < 0 { return .Failed }
	if pd.dwResultAction != win.PD_RESULT_PRINT { return .Cancelled }
	dc := pd.hDC
	if dc == nil { return .Failed }

	// the pages chosen, in the order typed
	pages := make([dynamic]int, 0, doc.page_count)
	defer delete(pages)
	if pd.Flags & win.PD_PAGENUMS != 0 {
		for r in ranges[:min(int(pd.nPageRanges), PRINT_MAX_RANGES)] {
			from := clamp(int(r.nFromPage), 1, doc.page_count)
			to := clamp(int(r.nToPage), 1, doc.page_count)
			if from > to { from, to = to, from }
			for page in from ..= to { append(&pages, page - 1) }
		}
	} else {
		for page in 0 ..< doc.page_count { append(&pages, page) }
	}
	if len(pages) == 0 { return .Failed }
	// (with PD_USEDEVMODECOPIESANDCOLLATE, nCopies is 1 when the driver makes the copies; else they are ours, and
	// PD_COLLATE says in which order)
	copies := max(1, int(pd.nCopies))
	collate := pd.Flags & win.PD_COLLATE != 0

	// (the person's orientation is the first page's: each page then turns the sheet its own way, if the driver can)
	dm: ^win.DEVMODEW
	if pd.hDevMode != nil { dm = (^win.DEVMODEW)(win.GlobalLock(pd.hDevMode)) }
	defer if dm != nil { win.GlobalUnlock(pd.hDevMode) }

	info := DOCINFOW{cbSize = size_of(DOCINFOW), lpszDocName = win.utf8_to_wstring(doc.title != "" ? doc.title : "Document")}
	if StartDocW(dc, &info) <= 0 { return .Failed }
	band_buf: [dynamic]u8
	defer delete(band_buf)
	for i in 0 ..< len(pages) * copies {
		page := collate ? pages[i % len(pages)] : pages[i / copies]
		size := doc.page_size(doc.user, page)
		if size.x <= 0 || size.y <= 0 { AbortDoc(dc); return .Failed }
		if dm != nil && dm.dmFields & DM_ORIENTATION != 0 {
			want: i16 = size.x > size.y ? DMORIENT_LANDSCAPE : DMORIENT_PORTRAIT
			// (between pages only: never inside StartPage and EndPage)
			if dm.dmOrientation != want {
				dm.dmOrientation = want
				if ResetDCW(dc, dm) == nil { AbortDoc(dc); return .Failed }
			}
		}
		caps :: proc(dc: win.HDC, a, b: i32) -> [2]f64 { return {f64(win.GetDeviceCaps(dc, a)), f64(win.GetDeviceCaps(dc, b))} }
		area := caps(dc, CAPS_HORZRES, CAPS_VERTRES)
		paper := caps(dc, CAPS_PHYSICALWIDTH, CAPS_PHYSICALHEIGHT)
		offset := caps(dc, CAPS_PHYSICALOFFSETX, CAPS_PHYSICALOFFSETY)
		dpi := caps(dc, CAPS_LOGPIXELSX, CAPS_LOGPIXELSY)
		x, y, w, h := print_page_fit(size, paper, offset, area, dpi)
		if w < 1 || h < 1 { AbortDoc(dc); return .Failed }
		px := [2]int{int(math.round(w)), int(math.round(h))}
		at := [2]i32{i32(math.round(x)), i32(math.round(y))}

		if StartPage(dc) <= 0 { AbortDoc(dc); return .Failed }
		band := print_band_rows(px.x)
		for y0 := 0; y0 < px.y; y0 += band {
			y1 := min(px.y, y0 + band)
			rows := y1 - y0
			resize(&band_buf, rows * px.x * 4)
			out := band_buf[:]
			// (a renderer that leaves pixels untouched leaves paper, not the last band)
			for &c in out { c = 255 }
			if !doc.render(doc.user, page, px, {y0, y1}, out) { AbortDoc(dc); return .Failed }
			// as GDI takes them: BGRA, alpha laid over white
			for j in 0 ..< rows * px.x {
				p := out[j * 4:][:4]
				a := u32(p[3])
				over :: proc(c, a: u32) -> u8 { return u8((c * a + 255 * (255 - a) + 127) / 255) }
				p[0], p[1], p[2], p[3] = over(u32(p[2]), a), over(u32(p[1]), a), over(u32(p[0]), a), 255
			}
			bmi: win.BITMAPINFO
			bmi.bmiHeader = {biSize = size_of(win.BITMAPINFOHEADER), biWidth = i32(px.x), biHeight = -i32(rows), biPlanes = 1, biBitCount = 32, biCompression = win.BI_RGB}
			drawn := win.StretchDIBits(dc, at.x, at.y + i32(y0), i32(px.x), i32(rows), 0, 0, i32(px.x), i32(rows), raw_data(out), &bmi, win.DIB_RGB_COLORS, win.SRCCOPY)
			if drawn == 0 { AbortDoc(dc); return .Failed }
		}
		if EndPage(dc) <= 0 { AbortDoc(dc); return .Failed }
	}
	if EndDoc(dc) <= 0 { return .Failed }
	return .Printed
}

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
