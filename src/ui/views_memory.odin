package ui

// What the toolkit remembers of a view, per id: one line of a gt:store file (docs/views.md, "What is remembered").
//
//   props	v1 as=external open=0 dialog=58.0x40.0 internal=120,80,700,480 window=1180x760
//   sidebar	v1 as=panel open=1 dock=:left:18.0
//
// An absent field is the default of View_Options. A line that does not parse is ignored: its id gets the defaults.

import "core:fmt"
import "core:strconv"
import "core:strings"

View_Memory :: struct {
	as:       Maybe(View_Presentation),   // the last presentation the user chose (nil: none yet)
	open:     bool,                        // it was open when the program quit
	dialog:   Vec2,                        // the dialog's size in ems ({}: none)
	internal: [4]i32,                      // the internal window's rect: x, y, width, height in logical pixels (width 0: none)
	window:   [2]i32,                      // the external window's size in logical pixels ({}: none)
	dock:     Maybe(View_Dock_Memory),     // the panel's place and extent
}

View_Dock_Memory :: struct {
	place:     View_Place,   // its space is in the text it was parsed from: clone it to keep it
	extent_em: f32,
}

@(private = "file", rodata)
VIEW_AS_NAMES := [View_Presentation]string{.Dialog = "dialog", .Panel = "panel", .Internal = "internal", .External = "external"}
@(private = "file", rodata)
VIEW_EDGE_NAMES := [View_Edge]string{.Right = "right", .Left = "left", .Bottom = "bottom", .Top = "top"}

// The version of the line's format: a line of another version is ignored.
@(private = "file") VIEW_MEMORY_VERSION :: "v1"

// The line of `m`. A space name holds no space and no ':' (a program's constant).
views_format :: proc(m: View_Memory, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, VIEW_MEMORY_VERSION)
	if as, ok := m.as.?; ok { fmt.sbprintf(&b, " as=%s", VIEW_AS_NAMES[as]) }
	fmt.sbprintf(&b, " open=%d", m.open ? 1 : 0)
	if m.dialog != {} { fmt.sbprintf(&b, " dialog=%.1fx%.1f", m.dialog.x, m.dialog.y) }
	if m.internal[2] > 0 { fmt.sbprintf(&b, " internal=%d,%d,%d,%d", m.internal[0], m.internal[1], m.internal[2], m.internal[3]) }
	if m.window != {} { fmt.sbprintf(&b, " window=%dx%d", m.window[0], m.window[1]) }
	if d, ok := m.dock.?; ok { fmt.sbprintf(&b, " dock=%s:%s:%.1f", d.place.space, VIEW_EDGE_NAMES[d.place.edge], d.extent_em) }
	return strings.to_string(b)
}

// The memory in a line that views_format wrote. ok false: not such a line (another version, a field that does not
// read): the caller takes the defaults. A field of a name it does not know is skipped.
views_parse :: proc(text: string) -> (m: View_Memory, ok: bool) {
	rest := strings.trim_space(text)
	version, _ := next_word(&rest)
	if version != VIEW_MEMORY_VERSION { return {}, false }
	for {
		word, more := next_word(&rest)
		if !more { break }
		eq := strings.index_byte(word, '=')
		if eq <= 0 { return {}, false }
		name, value := word[:eq], word[eq + 1:]
		switch name {
		case "as":
			found := false
			for n, p in VIEW_AS_NAMES { if n == value { m.as, found = p, true } }
			if !found { return {}, false }
		case "open":
			switch value {
			case "0": m.open = false
			case "1": m.open = true
			case:     return {}, false
			}
		case "dialog":
			parts := strings.split(value, "x", context.temp_allocator)
			if len(parts) != 2 { return {}, false }
			w, wok := strconv.parse_f32(parts[0])
			h, hok := strconv.parse_f32(parts[1])
			if !wok || !hok || w <= 0 || h <= 0 { return {}, false }
			m.dialog = {w, h}
		case "internal":
			parts := strings.split(value, ",", context.temp_allocator)
			if len(parts) != 4 { return {}, false }
			for p, i in parts {
				n, nok := strconv.parse_int(p, 10)
				if !nok { return {}, false }
				m.internal[i] = i32(n)
			}
			if m.internal[2] <= 0 || m.internal[3] <= 0 { return {}, false }
		case "window":
			parts := strings.split(value, "x", context.temp_allocator)
			if len(parts) != 2 { return {}, false }
			for p, i in parts {
				n, nok := strconv.parse_int(p, 10)
				if !nok || n <= 0 { return {}, false }
				m.window[i] = i32(n)
			}
		case "dock":
			parts := strings.split(value, ":", context.temp_allocator)
			if len(parts) != 3 { return {}, false }
			d := View_Dock_Memory{place = {space = parts[0]}}
			found := false
			for n, e in VIEW_EDGE_NAMES { if n == parts[1] { d.place.edge, found = e, true } }
			x, xok := strconv.parse_f32(parts[2])
			if !found || !xok || x < 0 { return {}, false }
			d.extent_em = x
			m.dock = d
		}
	}
	return m, true
}

// The line of a dock space (key `#<space>`): its zones' extents in ems, a zone of none absent.
//
//   #mission	v1 left=18.0 bottom=12.5
views_space_format :: proc(extent: [View_Edge]f32, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, VIEW_MEMORY_VERSION)
	for x, e in extent {
		if x > 0 { fmt.sbprintf(&b, " %s=%.1f", VIEW_EDGE_NAMES[e], x) }
	}
	return strings.to_string(b)
}

// The extents in a line that views_space_format wrote. ok false: not such a line; a field it does not know is skipped.
views_space_parse :: proc(text: string) -> (extent: [View_Edge]f32, ok: bool) {
	rest := strings.trim_space(text)
	version, _ := next_word(&rest)
	if version != VIEW_MEMORY_VERSION { return {}, false }
	for {
		word, more := next_word(&rest)
		if !more { break }
		eq := strings.index_byte(word, '=')
		if eq <= 0 { return {}, false }
		for n, e in VIEW_EDGE_NAMES {
			if n != word[:eq] { continue }
			x, xok := strconv.parse_f32(word[eq + 1:])
			if !xok || x < 0 { return {}, false }
			extent[e] = x
		}
	}
	return extent, true
}

@(private = "file")
next_word :: proc(rest: ^string) -> (word: string, ok: bool) {
	r := strings.trim_left_space(rest^)
	if r == "" { return "", false }
	end := strings.index_byte(r, ' ')
	if end < 0 { end = len(r) }
	word, rest^ = r[:end], r[end:]
	return word, true
}
