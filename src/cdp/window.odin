package tk_cdp

// What a tool does to a toolkit window: the Toolkit.* methods of src/devtools and the protocol's input and pictures.

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "../ascii"

Box :: struct {
	name, text: string,
	x, y, w, h: f64,
}

// The boxes whose text holds `text` (Toolkit.find), in the temporary allocator.
find :: proc(c: ^Client, text: string) -> []Box {
	return boxes(c, fmt.tprintf(`{{"text":%s}}`, quote(text)))
}

find_name :: proc(c: ^Client, name: string) -> []Box {
	return boxes(c, fmt.tprintf(`{{"name":%s}}`, quote(name)))
}

@(private)
boxes :: proc(c: ^Client, query: string) -> []Box {
	r, ok := call(c, "Toolkit.find", query)
	if !ok { return nil }
	o, _ := r.(json.Object)
	nodes, _ := o["nodes"].(json.Array)
	out := make([]Box, len(nodes), context.temp_allocator)
	for n, i in nodes {
		b, _ := n.(json.Object)
		out[i] = {str(b["name"]), str(b["text"]), number(b["x"]), number(b["y"]), number(b["w"]), number(b["h"])}
	}
	return out
}

has :: proc(c: ^Client, text: string) -> bool { return len(find(c, text)) > 0 }

// Until the text is there (or gone): the window waits, nothing here sleeps.
wait_for :: proc(c: ^Client, text: string, limit: time.Duration, gone := false) -> bool {
	_, ok := call(c, "Toolkit.waitFor", fmt.tprintf(`{{"text":%s,"gone":%v,"timeout":%d}}`, quote(text), gone, int(time.duration_milliseconds(limit))))
	return ok
}

wait_name :: proc(c: ^Client, name: string, limit: time.Duration, gone := false) -> bool {
	_, ok := call(c, "Toolkit.waitFor", fmt.tprintf(`{{"name":%s,"gone":%v,"timeout":%d}}`, quote(name), gone, int(time.duration_milliseconds(limit))))
	return ok
}

// Until three builds in a row had nothing moving. !idle: still moving at the limit (the call itself went through).
wait_idle :: proc(c: ^Client, limit: time.Duration) -> (idle, ok: bool) {
	r, called := call(c, "Toolkit.waitIdle", fmt.tprintf(`{{"timeout":%d}}`, int(time.duration_milliseconds(limit))))
	if !called { return false, false }
	o, _ := r.(json.Object)
	still, _ := o["idle"].(json.Boolean)
	return bool(still), true
}

click_name :: proc(c: ^Client, name: string) -> bool {
	_, ok := call(c, "Toolkit.click", fmt.tprintf(`{{"name":%s,"index":0,"count":1,"button":"left"}}`, quote(name)))
	return ok
}

click_text :: proc(c: ^Client, text: string) -> bool {
	_, ok := call(c, "Toolkit.click", fmt.tprintf(`{{"text":%s,"index":0,"count":1,"button":"left"}}`, quote(text)))
	return ok
}

type_text :: proc(c: ^Client, text: string) -> bool {
	_, ok := call(c, "Input.insertText", fmt.tprintf(`{{"text":%s}}`, quote(text)))
	return ok
}

// The modifiers of Input.dispatchKeyEvent.
KEY_ALT   :: 1
KEY_CTRL  :: 2
KEY_META  :: 4
KEY_SHIFT :: 8

// Names a script may give a key by, and the key they are.
@(private) KEY_NAMES :: [?][2]string{
	{"enter", "Enter"}, {"tab", "Tab"}, {"escape", "Escape"}, {"esc", "Escape"}, {"backspace", "Backspace"}, {"delete", "Delete"},
	{"up", "ArrowUp"}, {"down", "ArrowDown"}, {"left", "ArrowLeft"}, {"right", "ArrowRight"}, {"home", "Home"}, {"end", "End"},
	{"pageup", "PageUp"}, {"pagedown", "PageDown"}, {"space", " "},
}

// "ctrl+shift+t": the key, its modifiers, the text it types (none with Ctrl).
key_parts :: proc(name: string) -> (key: string, mods: int, text: string) {
	parts := strings.split(name, "+", context.temp_allocator)
	for p in parts[:len(parts) - 1] {
		switch ascii.lower(p) {
		case "alt":             mods |= KEY_ALT
		case "ctrl", "control": mods |= KEY_CTRL
		case "meta":            mods |= KEY_META
		case "shift":           mods |= KEY_SHIFT
		}
	}
	key = parts[len(parts) - 1]
	lower := ascii.lower(key)
	names := KEY_NAMES
	for n in names {
		if n[0] == lower { key = n[1]; break }
	}
	if len(key) == 1 && mods & KEY_CTRL == 0 { text = key }
	return
}

// A key by its name ("Enter", "ctrl+f", "shift+Tab"): down and up.
key :: proc(c: ^Client, name: string) -> bool {
	k, mods, text := key_parts(name)
	_, down := call(c, "Input.dispatchKeyEvent", fmt.tprintf(`{{"type":"keyDown","key":%s,"text":%s,"modifiers":%d}}`, quote(k), quote(text), mods))
	_, up := call(c, "Input.dispatchKeyEvent", fmt.tprintf(`{{"type":"keyUp","key":%s,"modifiers":%d}}`, quote(k), mods))
	return down && up
}

Clip :: struct {
	x, y, w, h: f64,
}

// The window's pixels as a PNG (a part of them: `clip`, in CSS pixels). The bytes are the caller's.
screenshot :: proc(c: ^Client, clip: Maybe(Clip) = nil, allocator := context.allocator) -> (png: []byte, ok: bool) {
	params := `{"format":"png"}`
	if r, has := clip.?; has {
		params = fmt.tprintf(`{{"format":"png","clip":{{"x":%v,"y":%v,"width":%v,"height":%v,"scale":1}}}}`, r.x, r.y, r.w, r.h)
	}
	result, called := call(c, "Page.captureScreenshot", params)
	if !called { return nil, false }
	o, _ := result.(json.Object)
	data, err := base64.decode(str(o["data"]), allocator = allocator)
	return data, err == nil
}

// The window's pixels in a PNG file.
shot :: proc(c: ^Client, path: string, clip: Maybe(Clip) = nil) -> bool {
	png, ok := screenshot(c, clip, context.temp_allocator)
	return ok && os.write_entire_file(path, png) == nil
}

// The size of the window, in CSS pixels (Toolkit.state).
window_size :: proc(c: ^Client) -> (w, h: f64, ok: bool) {
	r, called := call(c, "Toolkit.state")
	o, _ := r.(json.Object)
	return number(o["width"]), number(o["height"]), called
}
