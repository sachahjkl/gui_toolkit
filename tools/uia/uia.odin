#+build windows
// Package uia: a small UI Automation client (the COM interface IUIAutomation), to read a window the way a screen reader
// does: its elements with their control types, names, states and values, and to act on them (invoke, toggle, set a
// value, select, expand, focus). For the toolkit's tests (tests/a11y) and the probe (tools/uia_probe), not for
// applications. Call it from a thread of its own (COM multithreaded): the window's thread must keep pumping its
// messages, UI Automation reaches the window through them.
package uia

import "core:strings"
import win "core:sys/windows"

Element :: struct { vtbl: ^[64]rawptr }
@(private) Automation :: struct { vtbl: ^[64]rawptr }
@(private) Array :: struct { vtbl: ^[8]rawptr }
@(private) Unknown :: struct { vtbl: ^[8]rawptr }

Client :: struct {
	a:    ^Automation,
	true_cond: rawptr,
}

// Control types (UIA_*ControlTypeId).
Control :: enum i32 {
	Button = 50000, Calendar, Check_Box, Combo_Box, Edit, Hyperlink, Image, List_Item, List, Menu, Menu_Bar, Menu_Item,
	Progress_Bar, Radio_Button, Scroll_Bar, Slider, Spinner, Status_Bar, Tab, Tab_Item, Text, Tool_Bar, Tool_Tip, Tree,
	Tree_Item, Custom, Group, Thumb, Data_Grid, Data_Item, Document, Split_Button, Window, Pane, Header, Header_Item,
	Table, Title_Bar, Separator,
}

// Patterns (UIA_*PatternId).
Pattern :: enum i32 {
	Invoke = 10000, Selection, Value, Range_Value, Scroll, Expand_Collapse, Grid, Grid_Item, Multiple_View, Window,
	Selection_Item, Dock, Table, Table_Item, Text, Toggle,
}

@(private) CLSID_CUIAutomation := win.GUID{0xff48dba4, 0x60ef, 0x4201, {0xaa, 0x87, 0x54, 0x10, 0x3e, 0xef, 0x59, 0x4e}}
@(private) IID_IUIAutomation   := win.GUID{0x30cbe57d, 0xd9d0, 0x452a, {0xab, 0x13, 0x7a, 0xc5, 0xac, 0x48, 0x25, 0xee}}

foreign import oleaut32 "system:oleaut32.lib"
@(default_calling_convention = "system", private)
foreign oleaut32 {
	SysFreeString :: proc(s: [^]u16) ---
	SysStringLen :: proc(s: [^]u16) -> u32 ---
	SysAllocStringLen :: proc(s: [^]u16, n: u32) -> [^]u16 ---
}

@(private) Fn_Release :: proc "system" (this: rawptr) -> u32

@(private)
release :: proc(p: rawptr) {
	if p == nil { return }
	u := (^Unknown)(p)
	(Fn_Release)(u.vtbl[2])(p)
}

// Starts COM on this thread (multithreaded) and makes the client.
open :: proc() -> (c: Client, ok: bool) {
	hr := win.CoInitializeEx(nil, .MULTITHREADED)
	if hr < 0 && u32(hr) != 0x80010106 { return }   // (RPC_E_CHANGED_MODE: COM is already up on this thread, another way)
	p: rawptr
	if win.CoCreateInstance(&CLSID_CUIAutomation, nil, win.CLSCTX_INPROC_SERVER, &IID_IUIAutomation, &p) < 0 || p == nil { return }
	c.a = (^Automation)(p)
	// CreateTrueCondition (21)
	f := (proc "system" (this: ^Automation, out: ^rawptr) -> win.HRESULT)(c.a.vtbl[21])
	if f(c.a, &c.true_cond) < 0 { release(c.a); c.a = nil; return }
	return c, true
}

close :: proc(c: ^Client) {
	release(c.true_cond)
	release(c.a)
	c^ = {}
	win.CoUninitialize()
}

// The element of a window (an HWND).
from_window :: proc(c: ^Client, hwnd: rawptr) -> ^Element {
	el: rawptr
	f := (proc "system" (this: ^Automation, hwnd: rawptr, out: ^rawptr) -> win.HRESULT)(c.a.vtbl[6])
	if f(c.a, hwnd, &el) < 0 { return nil }
	return (^Element)(el)
}

// The element that has the keyboard focus (in the whole system).
focused :: proc(c: ^Client) -> ^Element {
	el: rawptr
	f := (proc "system" (this: ^Automation, out: ^rawptr) -> win.HRESULT)(c.a.vtbl[8])
	if f(c.a, &el) < 0 { return nil }
	return (^Element)(el)
}

drop :: proc(e: ^Element) { release(e) }
drop_all :: proc(es: []^Element) { for e in es { release(e) }; delete(es) }

// Every element below `e` (not `e` itself), in tree order. Release them with drop_all.
descendants :: proc(c: ^Client, e: ^Element, allocator := context.allocator) -> []^Element {
	arr: rawptr
	f := (proc "system" (this: ^Element, scope: i32, cond: rawptr, out: ^rawptr) -> win.HRESULT)(e.vtbl[6])   // FindAll
	if f(e, 4, c.true_cond, &arr) < 0 || arr == nil { return nil }   // TreeScope_Descendants
	defer release(arr)
	a := (^Array)(arr)
	n: i32
	(proc "system" (this: ^Array, out: ^i32) -> win.HRESULT)(a.vtbl[3])(a, &n)
	out := make([]^Element, n, allocator)
	for i in 0 ..< n {
		el: rawptr
		(proc "system" (this: ^Array, i: i32, out: ^rawptr) -> win.HRESULT)(a.vtbl[4])(a, i, &el)
		out[i] = (^Element)(el)
	}
	return out
}

@(private)
bstr :: proc(b: [^]u16, allocator := context.allocator) -> string {
	if b == nil { return "" }
	n := SysStringLen(b)
	s, _ := win.wstring_to_utf8(win.wstring(b), int(n), allocator)
	SysFreeString(b)
	return s
}

@(private)
get_bstr :: proc(e: ^Element, slot: int, allocator := context.allocator) -> string {
	b: [^]u16
	if (proc "system" (this: ^Element, out: ^[^]u16) -> win.HRESULT)(e.vtbl[slot])(e, &b) < 0 { return "" }
	return bstr(b, allocator)
}

@(private)
get_i32 :: proc(e: ^Element, slot: int) -> i32 {
	v: i32
	(proc "system" (this: ^Element, out: ^i32) -> win.HRESULT)(e.vtbl[slot])(e, &v)
	return v
}

name :: proc(e: ^Element, allocator := context.allocator) -> string { return get_bstr(e, 23, allocator) }          // get_CurrentName
control :: proc(e: ^Element) -> Control { return Control(get_i32(e, 21)) }                                      // get_CurrentControlType
has_focus :: proc(e: ^Element) -> bool { return get_i32(e, 26) != 0 }                                            // get_CurrentHasKeyboardFocus
focusable :: proc(e: ^Element) -> bool { return get_i32(e, 27) != 0 }                                            // get_CurrentIsKeyboardFocusable
enabled :: proc(e: ^Element) -> bool { return get_i32(e, 28) != 0 }                                              // get_CurrentIsEnabled

set_focus :: proc(e: ^Element) -> bool { return (proc "system" (this: ^Element) -> win.HRESULT)(e.vtbl[3])(e) >= 0 }

@(private)
pattern :: proc(e: ^Element, p: Pattern) -> ^Unknown {
	out: rawptr
	if (proc "system" (this: ^Element, id: i32, out: ^rawptr) -> win.HRESULT)(e.vtbl[16])(e, i32(p), &out) < 0 { return nil }   // GetCurrentPattern
	return (^Unknown)(out)
}

has_pattern :: proc(e: ^Element, p: Pattern) -> bool {
	u := pattern(e, p)
	defer release(u)
	return u != nil
}

@(private)
call0 :: proc(e: ^Element, p: Pattern, slot: int) -> bool {
	u := pattern(e, p)
	if u == nil { return false }
	defer release(u)
	return (proc "system" (this: rawptr) -> win.HRESULT)(u.vtbl[slot])(u) >= 0
}

invoke :: proc(e: ^Element) -> bool { return call0(e, .Invoke, 3) }
toggle :: proc(e: ^Element) -> bool { return call0(e, .Toggle, 3) }
select :: proc(e: ^Element) -> bool { return call0(e, .Selection_Item, 3) }
expand :: proc(e: ^Element) -> bool { return call0(e, .Expand_Collapse, 3) }
collapse :: proc(e: ^Element) -> bool { return call0(e, .Expand_Collapse, 4) }

// 0 off, 1 on, 2 indeterminate; -1: no toggle pattern.
toggle_state :: proc(e: ^Element) -> int {
	u := pattern(e, .Toggle)
	if u == nil { return -1 }
	defer release(u)
	v: i32
	(proc "system" (this: rawptr, out: ^i32) -> win.HRESULT)(u.vtbl[4])(u, &v)
	return int(v)
}

// -1: no selection item pattern.
is_selected :: proc(e: ^Element) -> int {
	u := pattern(e, .Selection_Item)
	if u == nil { return -1 }
	defer release(u)
	v: i32
	(proc "system" (this: rawptr, out: ^i32) -> win.HRESULT)(u.vtbl[6])(u, &v)
	return v != 0 ? 1 : 0
}

// 0 collapsed, 1 expanded, 2 partially, 3 leaf; -1: no pattern.
expand_state :: proc(e: ^Element) -> int {
	u := pattern(e, .Expand_Collapse)
	if u == nil { return -1 }
	defer release(u)
	v: i32
	(proc "system" (this: rawptr, out: ^i32) -> win.HRESULT)(u.vtbl[5])(u, &v)
	return int(v)
}

value :: proc(e: ^Element, allocator := context.allocator) -> (string, bool) {
	u := pattern(e, .Value)
	if u == nil { return "", false }
	defer release(u)
	b: [^]u16
	if (proc "system" (this: rawptr, out: ^[^]u16) -> win.HRESULT)(u.vtbl[4])(u, &b) < 0 { return "", false }
	return bstr(b, allocator), true
}

set_value :: proc(e: ^Element, v: string) -> bool {
	u := pattern(e, .Value)
	if u == nil { return false }
	defer release(u)
	w := win.utf8_to_utf16(v, context.temp_allocator)
	b := SysAllocStringLen(raw_data(w), u32(len(w)))
	defer SysFreeString(b)
	return (proc "system" (this: rawptr, v: [^]u16) -> win.HRESULT)(u.vtbl[3])(u, b) >= 0
}

range_value :: proc(e: ^Element) -> (f64, bool) {
	u := pattern(e, .Range_Value)
	if u == nil { return 0, false }
	defer release(u)
	v: f64
	if (proc "system" (this: rawptr, out: ^f64) -> win.HRESULT)(u.vtbl[4])(u, &v) < 0 { return 0, false }
	return v, true
}

set_range_value :: proc(e: ^Element, v: f64) -> bool {
	u := pattern(e, .Range_Value)
	if u == nil { return false }
	defer release(u)
	return (proc "system" (this: rawptr, v: f64) -> win.HRESULT)(u.vtbl[3])(u, v) >= 0
}

// Text (the text pattern, IUIAutomationTextPattern / IUIAutomationTextRange): what a screen reader reads character by
// character and word by word, and the caret.

@(private) Range :: struct { vtbl: ^[32]rawptr }

@(private)
range_text :: proc(r: ^Range, allocator := context.allocator) -> string {
	b: [^]u16
	if (proc "system" (this: rawptr, max: i32, out: ^[^]u16) -> win.HRESULT)(r.vtbl[12])(r, -1, &b) < 0 { return "" }   // GetText
	return bstr(b, allocator)
}

@(private)
document_range :: proc(e: ^Element) -> ^Range {
	u := pattern(e, .Text)
	if u == nil { return nil }
	defer release(u)
	r: rawptr
	if (proc "system" (this: rawptr, out: ^rawptr) -> win.HRESULT)(u.vtbl[7])(u, &r) < 0 { return nil }   // get_DocumentRange
	return (^Range)(r)
}

// All the text of an element's text pattern; ok false: it has none.
document_text :: proc(e: ^Element, allocator := context.allocator) -> (string, bool) {
	r := document_range(e)
	if r == nil { return "", false }
	defer release(r)
	return range_text(r, allocator), true
}

// The text selected in an element's text pattern ("" for a caret); ok false: no text pattern, or no selection.
text_selection :: proc(e: ^Element, allocator := context.allocator) -> (string, bool) {
	u := pattern(e, .Text)
	if u == nil { return "", false }
	defer release(u)
	arr: rawptr
	if (proc "system" (this: rawptr, out: ^rawptr) -> win.HRESULT)(u.vtbl[5])(u, &arr) < 0 || arr == nil { return "", false }   // GetSelection
	defer release(arr)
	a := (^Array)(arr)
	n: i32
	(proc "system" (this: ^Array, out: ^i32) -> win.HRESULT)(a.vtbl[3])(a, &n)
	if n < 1 { return "", false }
	r: rawptr
	(proc "system" (this: ^Array, i: i32, out: ^rawptr) -> win.HRESULT)(a.vtbl[4])(a, 0, &r)
	if r == nil { return "", false }
	defer release(r)
	return range_text((^Range)(r), allocator), true
}

// Selects characters [start, end) of an element's text pattern (start = end: the caret there).
select_text :: proc(e: ^Element, start, end: int) -> bool {
	r := document_range(e)
	if r == nil { return false }
	defer release(r)
	move_by_range := (proc "system" (this: rawptr, src: i32, other: rawptr, target: i32) -> win.HRESULT)(r.vtbl[15])
	move_by_unit := (proc "system" (this: rawptr, endpoint: i32, unit: i32, count: i32, moved: ^i32) -> win.HRESULT)(r.vtbl[14])
	moved: i32
	// (endpoints: 0 start, 1 end; unit 0: character) the range collapsed at the start, then its end and its start moved
	if move_by_range(r, 1, r, 0) < 0 { return false }
	if end > 0 && move_by_unit(r, 1, 0, i32(end), &moved) < 0 { return false }
	if start > 0 && move_by_unit(r, 0, 0, i32(start), &moved) < 0 { return false }
	return (proc "system" (this: rawptr) -> win.HRESULT)(r.vtbl[16])(r) >= 0   // Select
}

// One line per element: control type, name, and what it says of itself (for logs and the probe).
describe :: proc(e: ^Element, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	n := name(e, context.temp_allocator)
	ct := control(e)
	strings.write_string(&sb, ct >= .Button && ct <= .Separator ? enum_name(ct) : "?")
	strings.write_string(&sb, " \"")
	strings.write_string(&sb, n)
	strings.write_string(&sb, "\"")
	if has_focus(e) { strings.write_string(&sb, " focused") }
	if !enabled(e) { strings.write_string(&sb, " disabled") }
	if t := toggle_state(e); t >= 0 { strings.write_string(&sb, t == 1 ? " checked" : t == 2 ? " mixed" : " unchecked") }
	if s := is_selected(e); s == 1 { strings.write_string(&sb, " selected") }
	if x := expand_state(e); x == 0 || x == 1 { strings.write_string(&sb, x == 1 ? " expanded" : " collapsed") }
	if v, ok := value(e, context.temp_allocator); ok && v != "" { strings.write_string(&sb, " value=\""); strings.write_string(&sb, v); strings.write_string(&sb, "\"") }
	if r, ok := range_value(e); ok {
		buf: [32]u8
		strings.write_string(&sb, " range=")
		strings.write_string(&sb, fmt_f64(buf[:], r))
	}
	return strings.to_string(sb)
}

@(private)
enum_name :: proc(c: Control) -> string {
	#partial switch c {
	case .Button: return "button"
	case .Check_Box: return "checkbox"
	case .Combo_Box: return "combobox"
	case .Edit: return "edit"
	case .Hyperlink: return "link"
	case .Image: return "image"
	case .List_Item: return "listitem"
	case .List: return "list"
	case .Menu: return "menu"
	case .Menu_Bar: return "menubar"
	case .Menu_Item: return "menuitem"
	case .Progress_Bar: return "progressbar"
	case .Radio_Button: return "radio"
	case .Scroll_Bar: return "scrollbar"
	case .Slider: return "slider"
	case .Spinner: return "spinner"
	case .Status_Bar: return "statusbar"
	case .Tab: return "tablist"
	case .Tab_Item: return "tab"
	case .Text: return "text"
	case .Tool_Bar: return "toolbar"
	case .Tool_Tip: return "tooltip"
	case .Tree: return "tree"
	case .Tree_Item: return "treeitem"
	case .Group: return "group"
	case .Document: return "document"
	case .Window: return "window"
	case .Pane: return "pane"
	case .Title_Bar: return "titlebar"
	case .Table: return "table"
	case .Header: return "header"
	case .Header_Item: return "headeritem"
	case .Data_Item: return "dataitem"
	case .Separator: return "separator"
	case .Custom: return "custom"
	}
	return "other"
}

@(private)
fmt_f64 :: proc(buf: []u8, v: f64) -> string {
	// (no core:fmt for one number: integer part and two decimals)
	n := int(v * 100 + (v >= 0 ? 0.5 : -0.5))
	neg := n < 0
	if neg { n = -n }
	tmp: [32]u8
	i := len(tmp)
	for k := 0; k < 3 || n > 0; k += 1 {
		if k == 2 { i -= 1; tmp[i] = '.' }
		i -= 1
		tmp[i] = u8('0' + n % 10)
		n /= 10
	}
	if neg { i -= 1; tmp[i] = '-' }
	return string(buf[:copy(buf, tmp[i:])])
}
