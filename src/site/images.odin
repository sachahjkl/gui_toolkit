package tk_site

// The pictures of a built site, made light. A screenshot published as a PNG is many times larger than the same picture in WebP,
// and a page often shows it narrower than it is. build_images turns the PNGs of a folder of the built site into WebP (cwebp,
// libwebp's encoder) at their own width and at narrower ones, points the pages at them, and removes the PNGs it replaced. An
// <img> gets a srcset of its widths: the browser takes the one its layout needs, which the page says with `sizes` (its own: only
// the page knows how wide it shows a picture). Run on the built site, after its pages are made.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

Images_Options :: struct {
	dir:     string,     // the folder of the pictures, under the site ("img")
	widths:  []int,      // the narrower copies, in pixels; the picture's own width is always made
	quality: int,        // cwebp's -q (0: IMAGES_QUALITY)
	keep:    []string,   // the PNGs left as they are, by file name: what other sites read (a sharing card, a logo, a favicon)
}

// With -preset text: a screenshot's small text stays as sharp as in the PNG, the file some twenty times smaller.
IMAGES_QUALITY :: 90

// A picture made in WebP: its widths, the narrowest first, the last its own.
Picture :: struct { widths: []int }

build_images :: proc(out: string, o: Images_Options) -> bool {
	at := fmt.tprintf("%s/%s", out, o.dir)
	entries, err := os.read_all_directory_by_path(at, context.temp_allocator)
	if err != nil { fmt.eprintfln("site: no folder %s", at); return false }
	quality := fmt.tprintf("%d", o.quality > 0 ? o.quality : IMAGES_QUALITY)
	made := make(map[string]Picture, allocator = context.temp_allocator)
	for e in entries {
		if e.type == .Directory || !strings.has_suffix(e.name, ".png") || slice.contains(o.keep, e.name) { continue }
		name := e.name[:len(e.name) - len(".png")]
		src := fmt.tprintf("%s/%s", at, e.name)
		own, ok := png_width(src)
		if !ok { fmt.eprintfln("site: %s is not a PNG", src); return false }
		widths := make([dynamic]int, context.temp_allocator)
		for w in o.widths { if w < own && !slice.contains(widths[:], w) { append(&widths, w) } }
		slice.sort(widths[:])
		append(&widths, own)
		for w in widths {
			dst := fmt.tprintf("%s/%s", at, webp_name(name, w, own))
			// (-preset first: cwebp reads it before the options it sets)
			command := make([dynamic]string, context.temp_allocator)
			append(&command, "cwebp", "-preset", "text", "-q", quality, "-metadata", "none", "-quiet")
			if w < own { append(&command, "-resize", fmt.tprintf("%d", w), "0") }
			append(&command, src, "-o", dst)
			if !cwebp(command[:]) { return false }
		}
		made[name] = Picture{widths[:]}
	}
	pages, listed := site_pages(out)
	if !listed { fmt.eprintfln("site: the pages of %s not listed", out); return false }
	for page in pages {
		path := fmt.tprintf("%s/%s", out, page)
		data, rerr := os.read_entire_file(path, context.temp_allocator)
		if rerr != nil { fmt.eprintfln("site: %s not read", path); return false }
		html := images_html(string(data), o.dir, made)
		if html != string(data) && !write_text(path, html) { return false }
	}
	for name in made {
		if os.remove(fmt.tprintf("%s/%s.png", at, name)) != nil { fmt.eprintfln("site: %s/%s.png not removed", at, name); return false }
	}
	return true
}

// The pages pointed at the pictures made (pure): an <img> of one of them gets its WebP and a srcset of its widths, every other
// mention of its PNG (a link that opens it whole) its WebP at its own width. An <img> with a srcset of its own is left as it is.
images_html :: proc(html, dir: string, made: map[string]Picture) -> string {
	b := strings.builder_make(context.temp_allocator)
	rest := html
	for {
		i := strings.index(rest, "<img ")
		if i < 0 { break }
		strings.write_string(&b, rest[:i])
		end := strings.index_byte(rest[i:], '>')
		if end < 0 { rest = rest[i:]; break }
		tag := rest[i:i + end + 1]
		rest = rest[i + end + 1:]
		strings.write_string(&b, img_srcset(tag, dir, made))
	}
	strings.write_string(&b, rest)
	out := strings.to_string(b)
	for name, p in made {
		png := fmt.tprintf("%s/%s.png\"", dir, name)
		webp := fmt.tprintf("%s/%s\"", dir, webp_name(name, p.widths[len(p.widths) - 1], p.widths[len(p.widths) - 1]))
		out = replace_paths(out, png, webp)
	}
	return out
}

// `from` replaced by `to` where it begins a path: after a quote or a slash, not inside another folder's name ("bigimg/").
@(private = "file")
replace_paths :: proc(s, from, to: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	rest := s
	for {
		i := strings.index(rest, from)
		if i < 0 { break }
		before := i > 0 ? rest[i - 1] : '"'
		strings.write_string(&b, rest[:i])
		strings.write_string(&b, before == '"' || before == '/' ? to : from)
		rest = rest[i + len(from):]
	}
	strings.write_string(&b, rest)
	return strings.to_string(b)
}

// An <img> tag with a srcset of the picture its src names, when it is one made.
@(private = "file")
img_srcset :: proc(tag, dir: string, made: map[string]Picture) -> string {
	if strings.contains(tag, " srcset=") { return tag }
	at := strings.index(tag, ` src="`)
	if at < 0 { return tag }
	from := at + len(` src="`)
	length := strings.index_byte(tag[from:], '"')
	if length < 0 { return tag }
	src := tag[from:from + length]
	slash := strings.last_index_byte(src, '/')
	if slash < 0 || !strings.has_suffix(src[:slash], dir) || !strings.has_suffix(src, ".png") { return tag }
	if slash > len(dir) && src[slash - len(dir) - 1] != '/' { return tag }   // (a folder whose name only ends like it)
	name := src[slash + 1:len(src) - len(".png")]
	p, ok := made[name]
	if !ok { return tag }
	own := p.widths[len(p.widths) - 1]
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, tag[:from + length + 1])
	strings.write_string(&b, ` srcset="`)
	for w, k in p.widths {
		if k > 0 { strings.write_string(&b, ", ") }
		fmt.sbprintf(&b, "%s/%s %dw", src[:slash], webp_name(name, w, own), w)
	}
	strings.write_byte(&b, '"')
	strings.write_string(&b, tag[from + length + 1:])
	return strings.to_string(b)
}

// "name.webp" at its own width, "name-720.webp" at another.
@(private = "file")
webp_name :: proc(name: string, width, own: int) -> string {
	return width == own ? fmt.tprintf("%s.webp", name) : fmt.tprintf("%s-%d.webp", name, width)
}

// A PNG's width, from its header.
@(private = "file")
png_width :: proc(path: string) -> (width: int, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil || len(data) < 24 || string(data[:8]) != "\x89PNG\r\n\x1a\n" { return }
	return int(data[16]) << 24 | int(data[17]) << 16 | int(data[18]) << 8 | int(data[19]), true
}

@(private = "file")
cwebp :: proc(command: []string) -> bool {
	state, _, stderr, err := os.process_exec({command = command}, context.temp_allocator)
	if err != nil {
		fmt.eprintln("site: cwebp did not start: it is libwebp's encoder, which the pictures need (nix: libwebp; Debian: webp)")
		return false
	}
	if !state.exited || state.exit_code != 0 {
		fmt.eprintfln("site: cwebp failed: %s", strings.trim_space(string(stderr)))
		return false
	}
	return true
}
