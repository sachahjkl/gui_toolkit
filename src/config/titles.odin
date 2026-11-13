package tk_config

// What a settings UI shows of a preference besides its dotted name: a readable title, the first sentence of its
// description (the rest goes behind a "details" fold), the groups its name puts it in and their headings, and the
// search over all of them. Nothing here allocates outside the given allocator, but title_register (the registry's).

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import i18n "../i18n"

// The title of a preference, derived from its name (the definitions stay one name each: no second label to keep in
// step, and every preference gets one). Its groups are the name's other segments (path_of), which a settings page shows
// as headings (group_title): the title is the last segment alone, read as a phrase in sentence case with acronyms spelt
// as such. A trailing unit word goes (about:config shows the unit by the value), and so does the "enabled" of a switch
// (its toggle says it):
//
//   blocker.badge.style            -> Style            (under Blocker, Badge)
//   blocker.cosmetic.debounce_ms   -> Debounce
//   network.http.max_connections   -> Max connections
//   blocker.badge.enabled          -> Enabled          (one word: nothing else to say)
//   appearance.dark_mode_enabled   -> Dark mode
//
// `keep_unit`: the unit word stays ("Max body KB"), for the rare group where two preferences differ by their unit only
// (about:config asks for it then).
//
// A title of the definition's own is English, shown in the language in use (i18n.tr); a title made from the name stays
// as it is (no catalogue has it).
title_of :: proc(d: Def, allocator := context.temp_allocator, keep_unit := false) -> string {
	if d.title != "" { return strings.clone(i18n.tr(d.title), allocator) }   // (the program's words: an acronym, a phrase)
	words := split_words(leaf_of(d.name), context.temp_allocator)
	if !keep_unit && len(words) > 1 && is_unit_word(words[len(words) - 1]) { words = words[:len(words) - 1] }
	if d.kind == .Bool && len(words) > 1 && words[len(words) - 1] == "enabled" { words = words[:len(words) - 1] }
	return phrase(words, allocator)
}

////////////////////////////////
// The hierarchy: a preference's groups are the segments of its name but the last ("appearance.text.gamma": the group
// "appearance", in it the group "appearance.text"). The name is the one source of where a preference goes; the titles
// of the groups come from a table the program and the toolkit fill (title_register).

// A group's title and its place among its siblings.
Group :: struct {
	title: string,   // owned
	order: int,      // lower first; equal orders keep the order their first preference was registered in
}

// The path of each group of `name`, from the top: "appearance.text.gamma" -> {"appearance", "appearance.text"}; a name of
// one segment is in no group. The strings are slices of `name`.
path_of :: proc(name: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	for i in 0 ..< len(name) { if name[i] == '.' && i > 0 { append(&out, name[:i]) } }
	return out[:]
}

// Gives the group at `path` ("appearance", "appearance.text") its title and its order. Again for the same path: the
// last one wins (a program's words over the toolkit's, when it registers after it).
title_register :: proc(p: ^Prefs, path: string, title: string, order := 0) {
	if old, ok := p.groups[path]; ok {
		delete(old.title, p.allocator)
		p.groups[path] = {title = strings.clone(title, p.allocator), order = order}
		return
	}
	p.groups[strings.clone(path, p.allocator)] = {title = strings.clone(title, p.allocator), order = order}
}

// The title of the group at `path`: the registered one, in the language in use (i18n.tr), else made from its last
// segment ("devtools" -> "DevTools", "web_platform" -> "Web platform").
group_title :: proc(p: ^Prefs, path: string, allocator := context.temp_allocator) -> string {
	if g, ok := p.groups[path]; ok { return strings.clone(i18n.tr(g.title), allocator) }
	return phrase(split_words(leaf_of(path), context.temp_allocator), allocator)
}

// The groups directly in `parent` ("": the top ones) that hold a preference a settings page shows (not hidden), sorted
// by their order, then by the registration of their first preference.
groups_of :: proc(p: ^Prefs, parent := "", allocator := context.temp_allocator) -> []string {
	Child :: struct { path: string, order, first: int }
	kids := make([dynamic]Child, context.temp_allocator)
	for e, i in p.entries {
		if e.def.hidden { continue }
		for path in path_of(e.def.name) {
			if parent_of(path) != parent { continue }
			found := false
			for k in kids { if k.path == path { found = true; break } }
			if !found { append(&kids, Child{path = path, order = p.groups[path].order, first = i}) }
		}
	}
	slice.sort_by(kids[:], proc(a, b: Child) -> bool { return a.order != b.order ? a.order < b.order : a.first < b.first })
	out := make([]string, len(kids), allocator)
	for k, i in kids { out[i] = k.path }
	return out
}

// The last segment of a dotted name or path.
@(private)
leaf_of :: proc(name: string) -> string {
	if i := strings.last_index_byte(name, '.'); i >= 0 && i + 1 < len(name) { return name[i + 1:] }
	return name
}

// The path a group is in ("" for a top group).
@(private = "file")
parent_of :: proc(path: string) -> string {
	if i := strings.last_index_byte(path, '.'); i >= 0 { return path[:i] }
	return ""
}

// The first sentence of a description, and what follows it (trimmed; empty when the description is one sentence). A
// sentence ends at a full stop followed by a space and a capital letter, outside parentheses, and not after a common
// abbreviation ("e.g.", "i.e.", "etc.", "vs.", "cf."), so "0.5", "e.g. foo" and "(see below. Then)" do not cut it.
summary_of :: proc(description: string) -> (summary, more: string) {
	s := description
	depth := 0
	for i := 0; i < len(s); i += 1 {
		switch s[i] {
		case '(', '[': depth += 1
		case ')', ']': depth = max(depth - 1, 0)
		case '.', '!', '?':
			if depth > 0 || i + 1 >= len(s) || s[i + 1] != ' ' { continue }
			if s[i] == '.' && after_abbreviation(s[:i]) { continue }
			j := i + 1
			for j < len(s) && s[j] == ' ' { j += 1 }
			if j >= len(s) { return strings.trim_space(s[:i + 1]), "" }
			r, _ := utf8.decode_rune_in_string(s[j:])
			if !unicode.is_upper(r) && r != '(' && r != '"' && r != '\'' && r != '`' { continue }
			return strings.trim_space(s[:i + 1]), strings.trim_space(s[j:])
		}
	}
	return strings.trim_space(s), ""
}

// The description a settings page shows: in the language in use (i18n.tr), the program's name in it (Def.program).
description_of :: proc(d: Def, allocator := context.temp_allocator) -> string {
	return description_text(d, i18n.tr(d.description), allocator)
}

// A description, or its format, with the program's name in it.
@(private = "file")
description_text :: proc(d: Def, text: string, allocator := context.temp_allocator) -> string {
	if d.program == "" { return strings.clone(text, allocator) }
	return fmt.aprintf(text, i18n.tr(d.program), allocator = allocator)
}

// Whether a preference matches a search: every word of `query` (lower case, separated by spaces) appears in its name,
// its title, its description, its tags or the titles of its groups ("text gamma" finds "appearance.text.gamma" under
// "Text and fonts"). An empty query matches everything. An advanced preference matches as any other. The titles and the
// description are searched as shown and in English: one who knows a setting by its English words finds it too.
matches :: proc(p: ^Prefs, d: Def, query: string) -> bool {
	groups := make([dynamic]string, context.temp_allocator)
	for path in path_of(d.name) {
		append(&groups, group_title(p, path))
		if g, ok := p.groups[path]; ok { append(&groups, g.title) }
	}
	return words_match(query, d.name, title_of(d), d.title, description_of(d), description_text(d, d.description),
		strings.join(d.tags, " ", context.temp_allocator), strings.join(groups[:], " ", context.temp_allocator))
}

@(private = "file")
split_words :: proc(s: string, allocator := context.temp_allocator) -> []string {
	words := make([dynamic]string, allocator)
	start := 0
	for i in 0 ..= len(s) {
		if i == len(s) || s[i] == '.' || s[i] == '_' || s[i] == '-' {
			if i > start { append(&words, s[start:i]) }
			start = i + 1
		}
	}
	return words[:]
}

@(private = "file")
phrase :: proc(words: []string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	for w, i in words {
		if i > 0 { strings.write_byte(&sb, ' ') }
		if sp := spelling(w); sp != "" {
			strings.write_string(&sb, sp)
		} else if i == 0 {
			r, n := utf8.decode_rune_in_string(w)
			strings.write_rune(&sb, unicode.to_upper(r))
			strings.write_string(&sb, w[n:])
		} else {
			strings.write_string(&sb, w)
		}
	}
	return strings.to_string(sb)
}

@(private = "file")
is_unit_word :: proc(w: string) -> bool {
	switch w {
	case "ms", "us", "ns", "s", "sec", "secs", "seconds", "minutes", "hours", "days", "kb", "mb", "gb", "kib", "mib", "bytes", "px", "pct", "percent", "hz":
		return true
	}
	return false
}

@(private = "file")
after_abbreviation :: proc(before: string) -> bool {
	for a in ([]string{"e.g", "i.e", "etc", "vs", "cf", "approx"}) {
		if !strings.has_suffix(before, a) { continue }
		k := len(before) - len(a)
		if k == 0 || before[k - 1] == ' ' || before[k - 1] == '(' { return true }
	}
	return false
}

// Words a title spells otherwise than in lower case ("" when it does not).
@(private = "file")
spelling :: proc(w: string) -> string {
	switch w {
	case "kb", "mb", "gb": return strings.to_upper(w, context.temp_allocator)
	case "kib": return "KiB"
	case "mib": return "MiB"
	case "url": return "URL"
	case "urls": return "URLs"
	case "http": return "HTTP"
	case "https": return "HTTPS"
	case "http2", "h2": return "HTTP/2"
	case "http3", "h3": return "HTTP/3"
	case "dns": return "DNS"
	case "doh": return "DoH"
	case "tls": return "TLS"
	case "ssl": return "SSL"
	case "ocsp": return "OCSP"
	case "hsts": return "HSTS"
	case "csp": return "CSP"
	case "cors": return "CORS"
	case "sni": return "SNI"
	case "ech": return "ECH"
	case "quic": return "QUIC"
	case "ip": return "IP"
	case "ipv4": return "IPv4"
	case "ipv6": return "IPv6"
	case "js": return "JS"
	case "javascript": return "JavaScript"
	case "css": return "CSS"
	case "html": return "HTML"
	case "svg": return "SVG"
	case "png": return "PNG"
	case "jpeg", "jpg": return "JPEG"
	case "gif": return "GIF"
	case "pdf": return "PDF"
	case "mime": return "MIME"
	case "json": return "JSON"
	case "xml": return "XML"
	case "id": return "ID"
	case "ids": return "IDs"
	case "ui": return "UI"
	case "ua": return "UA"
	case "api": return "API"
	case "gpu": return "GPU"
	case "cpu": return "CPU"
	case "io": return "I/O"
	case "os": return "OS"
	case "dpi": return "DPI"
	case "fps": return "FPS"
	case "hud": return "HUD"
	case "ttl": return "TTL"
	case "lru": return "LRU"
	case "hdr": return "HDR"
	case "srgb": return "sRGB"
	case "rgb": return "RGB"
	case "msaa": return "MSAA"
	case "sdf": return "SDF"
	case "vsync": return "VSync"
	case "colr": return "COLR"
	case "dwrite": return "DirectWrite"
	case "dxgi": return "DXGI"
	case "d3d", "d3d11", "d3d12": return strings.to_upper(w, context.temp_allocator)
	case "wasm": return "Wasm"
	case "wamr": return "WAMR"
	case "quickjs": return "QuickJS"
	case "webgpu": return "WebGPU"
	case "webgl": return "WebGL"
	case "webauthn": return "WebAuthn"
	case "websocket", "websockets": return w == "websocket" ? "WebSocket" : "WebSockets"
	case "webrtc": return "WebRTC"
	case "devtools": return "DevTools"
	case "idb", "indexeddb": return "IndexedDB"
	case "a11y": return "Accessibility"
	case "utf8": return "UTF-8"
	case "wpt": return "WPT"
	case "uri": return "URI"
	case "dom": return "DOM"
	case "eventsource": return "EventSource"
	case "sse": return "SSE"
	case "xhr": return "XHR"
	case "cjk": return "CJK"
	case "rtl": return "RTL"
	case "ime": return "IME"
	case "uwp": return "UWP"
	case "dwm": return "DWM"
	case "dx": return "DirectX"
	case "png8": return "PNG8"
	case "webp": return "WebP"
	case "avif": return "AVIF"
	case "mp4": return "MP4"
	case "mp3": return "MP3"
	case "aac": return "AAC"
	case "h264": return "H.264"
	case "rss": return "RSS"
	case "ftp": return "FTP"
	case "smtp": return "SMTP"
	case "ws", "wss": return strings.to_upper(w, context.temp_allocator)
	}
	return ""
}
