#+build windows
// uia_probe: reads a window through UI Automation, as a screen reader does, and acts on it. For end-to-end tests of
// applications built with the toolkit's accessibility (a hidden window works: UI Automation needs no visible window).
//
//   uia_probe dump      (--pid N | --hwnd H) [--class C]          every element: type "name" states value
//   uia_probe find      (--pid N | --hwnd H) --name S [--type T]  exit 0 when such an element is there
//   uia_probe wait      (--pid N | --hwnd H) --name S [--type T] [--timeout MS]
//   uia_probe invoke | toggle | select | expand | collapse | focus  (--pid N | --hwnd H) --name S [--type T]
//   uia_probe set-value (--pid N | --hwnd H) --name S [--type T] --value V
//   uia_probe focused                                             the element that has the keyboard focus
//
// --type is the control type as dump prints it (button, checkbox, edit, tab, menuitem...). --prefix: the name starts
// with S. --index K: the K-th match (0 first). Exit codes: 0 ok, 1 not found / failed, 2 usage, 3 no window.
//   odin build tools/uia_probe -vet -out:build/uia_probe.exe
package uia_probe

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import win "core:sys/windows"
import "../uia"

Args :: struct {
	cmd, name, type, value, class: string,
	pid:     u32,
	hwnd:    uintptr,
	timeout: int,
	prefix:  bool,
	index:   int,
}

main :: proc() {
	os.exit(run())
}

usage :: proc() -> int {
	fmt.eprintln("usage: uia_probe dump|find|wait|invoke|toggle|select|expand|collapse|focus|set-value|focused (--pid N | --hwnd H) [--name S] [--type T] [--prefix] [--index K] [--value V] [--timeout MS] [--class C]")
	return 2
}

run :: proc() -> int {
	argv := os.args[1:]
	if len(argv) == 0 { return usage() }
	a := Args{cmd = argv[0], timeout = 10000, class = "gui_toolkit_window"}
	for i := 1; i < len(argv); i += 1 {
		k := argv[i]
		if k == "--prefix" { a.prefix = true; continue }
		if i + 1 >= len(argv) { return usage() }
		v := argv[i + 1]
		i += 1
		switch k {
		case "--pid":     n, _ := strconv.parse_uint(v); a.pid = u32(n)
		case "--hwnd":    n, _ := strconv.parse_uint(v); a.hwnd = uintptr(n)
		case "--name":    a.name = v
		case "--type":    a.type = v
		case "--value":   a.value = v
		case "--class":   a.class = v
		case "--timeout": a.timeout, _ = strconv.parse_int(v)
		case "--index":   a.index, _ = strconv.parse_int(v)
		case: return usage()
		}
	}
	c, ok := uia.open()
	if !ok { fmt.eprintln("uia_probe: UI Automation could not start"); return 1 }
	defer uia.close(&c)

	if a.cmd == "focused" {
		e := uia.focused(&c)
		if e == nil { return 1 }
		defer uia.drop(e)
		fmt.println(uia.describe(e, context.temp_allocator))
		return 0
	}
	hwnd := rawptr(a.hwnd)
	if hwnd == nil && a.pid != 0 { hwnd = window_of(a.pid, a.class) }
	if hwnd == nil { fmt.eprintln("uia_probe: no window"); return 3 }
	root := uia.from_window(&c, hwnd)
	if root == nil { fmt.eprintln("uia_probe: no element for the window"); return 3 }
	defer uia.drop(root)

	switch a.cmd {
	case "dump":
		// The first question makes the application send its tree (a placeholder answers until its next frame; the
		// system's title bar is there from the start): read until the count holds for a while.
		start := time.tick_now()
		last, same := -1, 0
		for {
			els := uia.descendants(&c, root)
			n := len(els)
			if n == last { same += 1 } else { same = 0 }
			last = n
			if same >= 4 || time.duration_milliseconds(time.tick_since(start)) > f64(a.timeout) {
				for e in els { fmt.println(uia.describe(e, context.temp_allocator)) }
				uia.drop_all(els)
				return 0
			}
			uia.drop_all(els)
			time.sleep(60 * time.Millisecond)
		}
	case "find", "wait":
		limit := a.cmd == "find" ? 2000 : a.timeout
		start := time.tick_now()
		for {
			if e := find(&c, root, a); e != nil {
				fmt.println(uia.describe(e, context.temp_allocator))
				uia.drop(e)
				return 0
			}
			if time.duration_milliseconds(time.tick_since(start)) > f64(limit) { return 1 }
			time.sleep(30 * time.Millisecond)
		}
	case "invoke", "toggle", "select", "expand", "collapse", "focus", "set-value":
		e: ^uia.Element
		start := time.tick_now()
		for e == nil && time.duration_milliseconds(time.tick_since(start)) < f64(a.timeout) {
			e = find(&c, root, a)
			if e == nil { time.sleep(30 * time.Millisecond) }
		}
		if e == nil { fmt.eprintln("uia_probe: not found"); return 1 }
		defer uia.drop(e)
		done: bool
		switch a.cmd {
		case "invoke":    done = uia.invoke(e)
		case "toggle":    done = uia.toggle(e)
		case "select":    done = uia.select(e)
		case "expand":    done = uia.expand(e)
		case "collapse":  done = uia.collapse(e)
		case "focus":     done = uia.set_focus(e)
		case "set-value": done = uia.set_value(e, a.value)
		}
		return done ? 0 : 1
	}
	return usage()
}

find :: proc(c: ^uia.Client, root: ^uia.Element, a: Args) -> ^uia.Element {
	els := uia.descendants(c, root)
	defer delete(els)
	found: ^uia.Element
	seen := 0
	for e in els {
		if found == nil && matches(e, a) {
			if seen == a.index { found = e; continue }
			seen += 1
		}
		uia.drop(e)
	}
	return found
}

matches :: proc(e: ^uia.Element, a: Args) -> bool {
	if a.type != "" {
		d := uia.describe(e, context.temp_allocator)
		sp := strings.index_byte(d, ' ')
		if sp < 0 || d[:sp] != a.type { return false }
	}
	if a.name == "" { return true }
	n := uia.name(e, context.temp_allocator)
	return a.prefix ? strings.has_prefix(n, a.name) : n == a.name
}

// The top-level window of process `pid` of window class `class` (hidden ones too).
window_of :: proc(pid: u32, class: string) -> rawptr {
	Find :: struct { pid: u32, class: string, out: win.HWND }
	f := Find{pid = pid, class = class}
	cb :: proc "system" (hwnd: win.HWND, lp: win.LPARAM) -> win.BOOL {
		f := (^Find)(rawptr(uintptr(lp)))
		p: u32
		win.GetWindowThreadProcessId(hwnd, &p)
		if p != f.pid { return true }
		buf: [128]u16
		n := win.GetClassNameW(hwnd, &buf[0], len(buf))
		name_ok := true
		if f.class != "" {
			// (ASCII class names: compare byte by byte)
			if int(n) != len(f.class) { name_ok = false } else {
				for i in 0 ..< int(n) { if buf[i] != u16(f.class[i]) { name_ok = false; break } }
			}
		}
		if !name_ok { return true }
		f.out = hwnd
		return false
	}
	win.EnumWindows(cb, win.LPARAM(uintptr(&f)))
	return rawptr(f.out)
}
