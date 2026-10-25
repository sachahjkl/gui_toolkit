package platform

// Drag and drop between applications, independent of the system (dragdrop_win32.odin: OLE; dragdrop_stub.odin: the
// systems that have no implementation yet answer "not supported").
//
// Receiving: drop_target_enable(window, true) makes the window a drop target. A drag that comes over it queues
// Drop_Enter, Drop_Over (each time the pointer moves or a modifier changes), then Drop_Leave or Drop, at the pointer's
// position (client pixels), with the source's allowed effects in Event.drop_allowed. What is dragged is read once, when
// it enters: drop_data(window) gives it from Drop_Enter until the poll after the Drop / Drop_Leave. The system asks
// "what would happen here" synchronously while the app answers in its next frame: the app says what it would do with
// drop_set_effect (the answer stays until it changes; none = the drop is refused), and the window gives the system the
// last answer (as browsers do with their renderer).
//
// Sending: drag_start(window, data, allowed) runs a drag of the system with `data` (files, text, HTML, a URL, formats
// of the app's own) until the user drops it or gives up, and returns the effect the target chose. It blocks (the
// system runs its own loop): call it from a press-and-move of the app, between two frames.
//
// Tests and remote control: drop_inject queues the same events with data of the app's choice, through the same path.

Drop_Effect :: enum u8 { Copy, Move, Link }
Drop_Effects :: bit_set[Drop_Effect; u8]

// A format of the app's own (Drag_Data.custom): a MIME type and its bytes. Carried between processes of the same app
// in one private format of the system (drag_custom_encode), invisible to other applications.
Drag_Entry :: struct {
	mime: string,
	data: string,
}

// What a drag carries. Every string is owned (drag_data_destroy). `url` with `url_title`: a link (the address, its
// text); `text`: plain text (UTF-8); `html`: an HTML fragment (the markup itself, not the system's clipboard header);
// `files`: absolute paths; `image`: an image file's bytes (PNG) when the source gives pixels and no file.
Drag_Data :: struct {
	files:     [dynamic]string,
	text:      string,
	html:      string,
	url:       string,
	url_title: string,
	image:     []u8,
	custom:    [dynamic]Drag_Entry,
}

drag_data_destroy :: proc(d: ^Drag_Data) {
	for f in d.files { delete(f) }
	delete(d.files)
	delete(d.text)
	delete(d.html)
	delete(d.url)
	delete(d.url_title)
	delete(d.image)
	for e in d.custom { delete(e.mime); delete(e.data) }
	delete(d.custom)
	d^ = {}
}

drag_data_clone :: proc(d: Drag_Data, allocator := context.allocator) -> Drag_Data {
	context.allocator = allocator
	out: Drag_Data
	for f in d.files { append(&out.files, clone_string(f)) }
	out.text, out.html = clone_string(d.text), clone_string(d.html)
	out.url, out.url_title = clone_string(d.url), clone_string(d.url_title)
	if len(d.image) > 0 { out.image = make([]u8, len(d.image)); copy(out.image, d.image) }
	for e in d.custom { append(&out.custom, Drag_Entry{clone_string(e.mime), clone_string(e.data)}) }
	return out
}

drag_data_empty :: proc(d: Drag_Data) -> bool {
	return len(d.files) == 0 && d.text == "" && d.html == "" && d.url == "" && len(d.image) == 0 && len(d.custom) == 0
}

@(private)
clone_string :: proc(s: string, allocator := context.allocator) -> string {
	if s == "" { return "" }
	b := make([]u8, len(s), allocator)
	copy(b, s)
	return string(b)
}

// A picture for a drag (drag_start): straight (not premultiplied) RGBA pixels, `size` in pixels, `offset` = where the
// pointer is in it (its hot spot; may lie outside the picture, as a web page's setDragImage allows).
Drag_Image :: struct {
	rgba:   []u8,
	size:   [2]int,
	offset: [2]int,
}

// The picture is usable: a size and enough pixels for it.
drag_image_valid :: proc(img: Drag_Image) -> bool {
	return img.size.x > 0 && img.size.y > 0 && len(img.rgba) >= img.size.x * img.size.y * 4
}

// Multiplies the picture's alpha by `opacity` (0..1), in place: the translucent "ghost" of a dragged element.
drag_image_fade :: proc(img: Drag_Image, opacity: f32) {
	if !drag_image_valid(img) { return }
	k := clamp(opacity, 0, 1)
	if k >= 1 { return }
	for i in 0 ..< img.size.x * img.size.y {
		a := &img.rgba[i * 4 + 3]
		a^ = u8(f32(a^) * k + 0.5)
	}
}

// The picture made to fit `max_size` (pixels): scaled down by averaging, its hot spot following; a copy (allocator)
// whether or not it shrank, so the caller always owns the result (delete(result.rgba)). Systems cap their drag images
// (Windows draws at most a few hundred pixels well); an invalid picture gives an empty one.
drag_image_fit :: proc(img: Drag_Image, max_size: [2]int, allocator := context.allocator) -> Drag_Image {
	if !drag_image_valid(img) { return {} }
	w, h := img.size.x, img.size.y
	k := min(f32(1), f32(max(max_size.x, 1)) / f32(w), f32(max(max_size.y, 1)) / f32(h))
	if k >= 1 {
		out := make([]u8, w * h * 4, allocator)
		copy(out, img.rgba[:w * h * 4])
		return Drag_Image{out, img.size, img.offset}
	}
	nw, nh := max(int(f32(w) * k), 1), max(int(f32(h) * k), 1)
	out := make([]u8, nw * nh * 4, allocator)
	for y in 0 ..< nh {
		y0 := y * h / nh
		y1 := max((y + 1) * h / nh, y0 + 1)
		for x in 0 ..< nw {
			x0 := x * w / nw
			x1 := max((x + 1) * w / nw, x0 + 1)
			// premultiplied average, so transparent pixels do not darken the edges
			sum: [4]u32
			for yy in y0 ..< y1 {
				for xx in x0 ..< x1 {
					p := img.rgba[(yy * w + xx) * 4:][:4]
					a := u32(p[3])
					sum += {u32(p[0]) * a, u32(p[1]) * a, u32(p[2]) * a, a}
				}
			}
			n := u32((y1 - y0) * (x1 - x0))
			o := out[(y * nw + x) * 4:][:4]
			if sum[3] > 0 { for c in 0 ..< 3 { o[c] = u8(sum[c] / sum[3]) } }
			o[3] = u8(sum[3] / n)
		}
	}
	return Drag_Image{out, {nw, nh}, {int(f32(img.offset.x) * k), int(f32(img.offset.y) * k)}}
}

// Answers the system synchronously while drag_start blocks (drop_sync_set): the drag the app started came back over
// its own window, the app's frame cannot run until the drag ends, so the window asks the app at once instead of
// queueing Drop_* events. `ev` is the Drop_Enter / Drop_Over / Drop_Leave / Drop that would have been queued
// (drop_data(w) holds the data); the result is the effect a drop would have here (nil: refused; ignored for Drop_Leave).
// The app handles the drop inside the call for a Drop, so it sees it before drag_start returns.
Drop_Sync :: #type proc(user: rawptr, w: ^Window, ev: Event) -> Maybe(Drop_Effect)

// One step of a scripted drag (drag_script): the pointer at `pos` (client pixels, outside the client area = over
// another application) with `mods` held. The last step is where the button is released.
Drag_Step :: struct {
	pos:  [2]f32,
	mods: Modifiers,
}

// What a scripted drag does at each step, from where the pointer was (`was_inside`) and is (`inside`): the drop
// target's callbacks a system would call. Pure, shared by every system.
Drag_Script_Call :: enum u8 { None, Enter, Over, Leave, Drop, Cancel }

drag_script_calls :: proc(was_inside, inside, last: bool) -> (first, second: Drag_Script_Call) {
	switch {
	case inside && !was_inside: first = .Enter
	case inside: first = .Over
	case was_inside: first = .Leave
	}
	if last { second = inside ? .Drop : .Cancel }
	return
}

// The MIME types a drag offers, in the order a web page lists them (HTML "drag data store item list"): the app's own
// formats, then text/plain, text/uri-list, text/html, and "Files" when there are files. Temporary allocator.
drag_data_types :: proc(d: Drag_Data, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	for e in d.custom { append(&out, e.mime) }
	if d.text != "" { append(&out, "text/plain") }
	if d.url != "" { append(&out, "text/uri-list") }
	if d.html != "" { append(&out, "text/html") }
	if len(d.files) > 0 || len(d.image) > 0 { append(&out, "Files") }
	return out[:]
}

// The effect a target would choose from what the source allows and the modifiers held, by the common convention:
// Ctrl copies, Shift moves, Ctrl+Shift or Alt links; with no modifier, `preferred` when allowed, else the first allowed
// of copy, move, link. nil: nothing allowed.
drop_effect_for :: proc(allowed: Drop_Effects, mods: Modifiers, preferred: Drop_Effect = .Copy) -> Maybe(Drop_Effect) {
	want: Maybe(Drop_Effect)
	switch {
	case .Alt in mods, .Ctrl in mods && .Shift in mods: want = .Link
	case .Ctrl in mods: want = .Copy
	case .Shift in mods: want = .Move
	}
	if w, ok := want.?; ok && w in allowed { return w }
	if preferred in allowed { return preferred }
	for e in Drop_Effect { if e in allowed { return e } }
	return nil
}

// The app's own formats in one byte string (and back): for each entry, the MIME type's length (4 bytes, little
// endian), the type, the data's length, the data. Pure, so it can be tested and shared by every system.
drag_custom_encode :: proc(entries: []Drag_Entry, allocator := context.allocator) -> []u8 {
	n := 0
	for e in entries { n += 8 + len(e.mime) + len(e.data) }
	out := make([]u8, n, allocator)
	at := 0
	put :: proc(out: []u8, at: ^int, s: string) {
		l := u32(len(s))
		out[at^], out[at^ + 1], out[at^ + 2], out[at^ + 3] = u8(l), u8(l >> 8), u8(l >> 16), u8(l >> 24)
		at^ += 4
		copy(out[at^:], s)
		at^ += len(s)
	}
	for e in entries { put(out, &at, e.mime); put(out, &at, e.data) }
	return out
}

// The entries of drag_custom_encode's bytes (owned strings); ok = false (nothing returned) when they are malformed.
drag_custom_decode :: proc(b: []u8, allocator := context.allocator) -> (entries: [dynamic]Drag_Entry, ok: bool) {
	entries = make([dynamic]Drag_Entry, allocator)
	at := 0
	get :: proc(b: []u8, at: ^int) -> (string, bool) {
		if len(b) - at^ < 4 { return "", false }
		l := int(u32(b[at^]) | u32(b[at^ + 1]) << 8 | u32(b[at^ + 2]) << 16 | u32(b[at^ + 3]) << 24)
		at^ += 4
		if l < 0 || l > len(b) - at^ { return "", false }
		s := string(b[at^:at^ + l])
		at^ += l
		return s, true
	}
	for at < len(b) {
		m, ok1 := get(b, &at)
		d, ok2 := get(b, &at)
		if !ok1 || !ok2 {
			for e in entries { delete(e.mime, allocator); delete(e.data, allocator) }
			delete(entries)
			return nil, false
		}
		append(&entries, Drag_Entry{clone_string(m, allocator), clone_string(d, allocator)})
	}
	return entries, true
}

// The first URL of a text/uri-list (RFC 2483: one per line, `#` lines are comments), "" when none.
uri_list_first :: proc(list: string) -> string {
	rest := list
	for len(rest) > 0 {
		end := 0
		for end < len(rest) && rest[end] != '\n' { end += 1 }
		line := rest[:end]
		rest = rest[min(end + 1, len(rest)):]
		for len(line) > 0 && (line[len(line) - 1] == '\r' || line[len(line) - 1] == ' ' || line[len(line) - 1] == '\t') { line = line[:len(line) - 1] }
		for len(line) > 0 && (line[0] == ' ' || line[0] == '\t') { line = line[1:] }
		if line == "" || line[0] == '#' { continue }
		return line
	}
	return ""
}

// The clipboard's "HTML Format" (CF_HTML, also what other systems' converters read): a header with byte offsets, then
// the document with the fragment between <!--StartFragment--> and <!--EndFragment-->. Pure.
html_format_wrap :: proc(fragment: string, source_url := "", allocator := context.allocator) -> string {
	PRE :: "<html><body>\r\n<!--StartFragment-->"
	POST :: "<!--EndFragment-->\r\n</body></html>"
	digits :: proc(buf: []u8, v: int) -> string {
		x := v
		for i := len(buf) - 1; i >= 0; i -= 1 { buf[i] = u8('0' + x % 10); x /= 10 }
		return string(buf)
	}
	// fixed-width offsets: the header's length does not depend on them
	header_len := len("Version:0.9\r\nStartHTML:0000000000\r\nEndHTML:0000000000\r\nStartFragment:0000000000\r\nEndFragment:0000000000\r\n")
	if source_url != "" { header_len += len("SourceURL:") + len(source_url) + 2 }
	start_html := header_len
	start_frag := start_html + len(PRE)
	end_frag := start_frag + len(fragment)
	end_html := end_frag + len(POST)
	b1, b2, b3, b4: [10]u8
	parts := [?]string{
		"Version:0.9\r\nStartHTML:", digits(b1[:], start_html), "\r\nEndHTML:", digits(b2[:], end_html),
		"\r\nStartFragment:", digits(b3[:], start_frag), "\r\nEndFragment:", digits(b4[:], end_frag), "\r\n",
	}
	total := 0
	for p in parts { total += len(p) }
	if source_url != "" { total += len("SourceURL:") + len(source_url) + 2 }
	total += len(PRE) + len(fragment) + len(POST)
	out := make([]u8, total, allocator)
	at := 0
	for p in parts { copy(out[at:], p); at += len(p) }
	if source_url != "" {
		for p in ([]string{"SourceURL:", source_url, "\r\n"}) { copy(out[at:], p); at += len(p) }
	}
	for p in ([]string{PRE, fragment, POST}) { copy(out[at:], p); at += len(p) }
	return string(out)
}

// The fragment of an "HTML Format" block (a view into `s`): the StartFragment / EndFragment offsets when they are
// sound, else the text between the comments, else the whole HTML after the header.
html_format_fragment :: proc(s: string) -> string {
	num :: proc(s: string, key: string) -> int {
		i := index_of(s, key)
		if i < 0 { return -1 }
		v, any := 0, false
		for j := i + len(key); j < len(s) && s[j] >= '0' && s[j] <= '9'; j += 1 { v = v * 10 + int(s[j] - '0'); any = true; if v > 1 << 30 { return -1 } }
		return any ? v : -1
	}
	a, b := num(s, "StartFragment:"), num(s, "EndFragment:")
	if a >= 0 && b >= a && b <= len(s) { return s[a:b] }
	if i := index_of(s, "<!--StartFragment-->"); i >= 0 {
		rest := s[i + len("<!--StartFragment-->"):]
		if j := index_of(rest, "<!--EndFragment-->"); j >= 0 { return rest[:j] }
	}
	if h := num(s, "StartHTML:"); h >= 0 && h <= len(s) { return s[h:] }
	return s
}

@(private)
index_of :: proc(s, sub: string) -> int {
	if len(sub) == 0 { return 0 }
	for i := 0; i + len(sub) <= len(s); i += 1 { if s[i:i + len(sub)] == sub { return i } }
	return -1
}
