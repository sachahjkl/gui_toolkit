// Is a frame ever stretched during a live resize? Starts a program, widens and narrows its window from outside with
// SetWindowPos (SWP_NOACTIVATE: no mouse, no focus), and reads one row of the screen with BitBlt to find where a column of
// fixed width ends: at rest, and many times after each step. A frame stretched over the new size moves that end. Not a
// test of the suite: it needs a screen with the window on top (made topmost for the run).
//   odin build tests/resize_probe -vet -out:build/resize_probe.exe
//   build\resize_probe.exe build\hello.exe              the row of the text field of examples/hello, whose width is fixed
//   build\resize_probe.exe build\whatsnew.exe --y=640   any row: the column is what comes before the first long run of background
// Exit code 1: a sample's column ended elsewhere than at rest.
package resize_probe

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import win "core:sys/windows"

WIDEN_BY :: 720     // physical pixels, from the window's width at rest
STEP     :: 8
CYCLES   :: 4
SETTLE   :: 800 * time.Millisecond
STEP_PAUSE :: 1 * time.Millisecond
COLOR_DELTA :: 12   // of 255 summed over the channels: what still counts as the background
SLACK    :: 1       // pixels the column's end may differ from the one at rest

Row :: struct {
	screen, mem: win.HDC,
	bits:        [^]u32,
	width:       int,
}

Found :: struct { pid: u32, hwnd: win.HWND }

find_window :: proc "system" (h: win.HWND, l: win.LPARAM) -> win.BOOL {
	f := (^Found)(uintptr(l))
	pid: u32
	win.GetWindowThreadProcessId(h, &pid)
	if pid == f.pid && win.IsWindowVisible(h) { f.hwnd = h; return false }
	return true
}

row_read :: proc(r: ^Row, x, y: int) {
	win.BitBlt(r.mem, 0, 0, i32(r.width), 1, r.screen, i32(x), i32(y), win.SRCCOPY)
}

differs :: proc(a, b: u32) -> bool {
	d := 0
	for s in uint(0) ..< 3 {
		ca, cb := int((a >> (s * 8)) & 0xff), int((b >> (s * 8)) & 0xff)
		d += abs(ca - cb)
	}
	return d > COLOR_DELTA
}

// Where the column ends: the last pixel unlike the background before a run of `gap` background pixels, once something
// else was seen. -1: nothing there.
column_end :: proc(r: ^Row, bg: u32, gap, width: int) -> int {
	last := -1
	for x in 0 ..< min(width, r.width) {
		if differs(r.bits[x], bg) {
			last = x
		} else if last >= 0 && x - last >= gap {
			return last
		}
	}
	return last
}

Reader :: struct {
	row:                    ^Row,
	x, y, gap, width, rest: int,
	bg:                     u32,
	samples, moved:         int,
	furthest:               int,
	done:                   bool,
}

read_while_resizing :: proc(data: rawptr) {
	re := (^Reader)(data)
	for !sync.atomic_load(&re.done) {
		row_read(re.row, re.x, re.y)
		e := column_end(re.row, re.bg, re.gap, re.width)
		re.samples += 1
		if abs(e - re.rest) > SLACK {
			re.moved += 1
			if abs(e - re.rest) > abs(re.furthest - re.rest) { re.furthest = e }
		}
	}
}

main :: proc() {
	if len(os.args) < 2 { fmt.eprintln("resize_probe <exe> [--y=<row of the client area>] [--gap=<pixels>]"); os.exit(2) }
	win.SetProcessDpiAwarenessContext(win.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)
	want_y, gap := -1, 0
	for a in os.args[2:] {
		if strings.has_prefix(a, "--y=") { want_y, _ = strconv.parse_int(a[4:]) }
		if strings.has_prefix(a, "--gap=") { gap, _ = strconv.parse_int(a[6:]) }
	}

	si := win.STARTUPINFOW{cb = size_of(win.STARTUPINFOW), dwFlags = win.STARTF_USESHOWWINDOW, wShowWindow = u16(win.SW_SHOWNOACTIVATE)}
	pi: win.PROCESS_INFORMATION
	if !win.CreateProcessW(nil, win.utf8_to_wstring(os.args[1]), nil, nil, false, 0, nil, nil, &si, &pi) {
		fmt.eprintln("resize_probe: cannot start", os.args[1]); os.exit(2)
	}
	defer {
		// the window closed, whatever happened
		found := Found{pid = pi.dwProcessId}
		win.EnumWindows(find_window, win.LPARAM(uintptr(&found)))
		if found.hwnd != nil { win.PostMessageW(found.hwnd, win.WM_CLOSE, 0, 0) }
		if win.WaitForSingleObject(pi.hProcess, 5000) != win.WAIT_OBJECT_0 { win.TerminateProcess(pi.hProcess, 1) }
	}
	found := Found{pid = pi.dwProcessId}
	for i := 0; i < 200 && found.hwnd == nil; i += 1 {
		time.sleep(50 * time.Millisecond)
		win.EnumWindows(find_window, win.LPARAM(uintptr(&found)))
	}
	if found.hwnd == nil { fmt.eprintln("resize_probe: no window"); return }
	h := found.hwnd

	// where it can be read: on top, left of the screen, as wide as it asked
	rc: win.RECT
	win.GetWindowRect(h, &rc)
	w0, h0 := rc.right - rc.left, rc.bottom - rc.top
	win.SetWindowPos(h, win.HWND_TOPMOST, 40, 40, w0, h0, win.SWP_NOACTIVATE)
	time.sleep(SETTLE)
	origin: win.POINT
	win.ClientToScreen(h, &origin)
	cr: win.RECT
	win.GetClientRect(h, &cr)
	cw0, ch0 := int(cr.right), int(cr.bottom)

	r := Row{screen = win.GetDC(nil), mem = win.CreateCompatibleDC(nil), width = cw0 + WIDEN_BY}
	defer { win.DeleteDC(r.mem); win.ReleaseDC(nil, r.screen) }
	bi := win.BITMAPINFO{bmiHeader = {biSize = size_of(win.BITMAPINFOHEADER), biWidth = i32(r.width), biHeight = 1, biPlanes = 1, biBitCount = 32, biCompression = win.BI_RGB}}
	bitmap := win.CreateDIBSection(r.mem, &bi, win.DIB_RGB_COLORS, (^rawptr)(&r.bits), nil, 0)
	defer win.DeleteObject(win.HGDIOBJ(bitmap))
	win.SelectObject(r.mem, win.HGDIOBJ(bitmap))

	if gap == 0 { gap = cw0 / 3 }
	// the row: asked for, or the one whose column ends furthest right among the top rows
	y, rest, bg := want_y, -1, u32(0)
	for ty := 0; ty < ch0; ty += 1 {
		if want_y >= 0 && ty != want_y { continue }
		row_read(&r, int(origin.x), int(origin.y) + ty)
		b := r.bits[cw0 - 2]
		e := column_end(&r, b, gap, cw0)
		if e > rest && e < cw0 - gap { y, rest, bg = ty, e, b }
	}
	if rest < 0 { fmt.eprintln("resize_probe: no column on that row"); os.exit(2) }
	fmt.printfln("client %d x %d at (%d, %d); row %d: the column ends at x = %d, background %08x", cw0, ch0, origin.x, origin.y, y, rest, bg)

	// the steps, one on the heels of the other as a hand or a window manager makes them; the row read meanwhile, as often as
	// the screen lets it (a BitBlt waits for the composer)
	sy := int(origin.y) + y
	reader := Reader{row = &r, x = int(origin.x), y = sy, bg = bg, gap = gap, width = cw0, rest = rest, furthest = rest}
	t := thread.create_and_start_with_data(&reader, read_while_resizing)
	steps := 0
	longest: time.Duration
	for _ in 0 ..< CYCLES {
		for i in 1 ..= 2 * WIDEN_BY / STEP {
			d := i <= WIDEN_BY / STEP ? i * STEP : (2 * WIDEN_BY / STEP - i) * STEP
			t0 := time.tick_now()
			win.SetWindowPos(h, nil, 0, 0, w0 + i32(d), h0, win.SWP_NOACTIVATE | win.SWP_NOMOVE | win.SWP_NOZORDER)
			longest = max(longest, time.tick_since(t0))
			steps += 1
			time.sleep(STEP_PAUSE)
		}
	}
	sync.atomic_store(&reader.done, true)
	thread.join(t)
	thread.destroy(t)
	time.sleep(SETTLE)
	row_read(&r, int(origin.x), sy)
	after := column_end(&r, bg, gap, cw0)
	fmt.printfln("%d steps, %d samples: %d with the column elsewhere, furthest at x = %d; a step took %.1f ms at most; at rest again x = %d",
		steps, reader.samples, reader.moved, reader.furthest, time.duration_milliseconds(longest), after)
	if reader.moved > 0 || abs(after - rest) > SLACK { win.TerminateProcess(pi.hProcess, 0); os.exit(1) }
}
