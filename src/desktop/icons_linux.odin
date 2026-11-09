package tk_desktop

// The icons of the person's icon theme (freedesktop.org Icon Theme specification 0.13):
//   - the theme: the Settings portal's org.gnome.desktop.interface icon-theme (what GTK shows: dconf's), else
//     gtk-icon-theme-name of $XDG_CONFIG_HOME/gtk-4.0/settings.ini, then gtk-3.0's, then KDE's kdeglobals ([Icons]
//     Theme=), else hicolor; read once per process;
//   - its folders: icons/<theme> under $HOME/.icons and each data directory; its index.theme (the first found) gives its
//     subfolders with their size, scale and type, and the themes it inherits; hicolor comes last;
//   - an icon name: the subfolder that matches the size, else the nearest, theme by theme; a PNG or an SVG file;
//   - the names of a file: its type's icon (mime/icons), the type with '/' made '-' (image-png), its family's
//     (mime/generic-icons), then its parents', then <media>-x-generic; a folder: the person's folders their own names
//     (user-home, folder-download...), else folder.
// What was read is kept while the roots and the theme's name are the same (a lock: any thread may ask).

import "base:runtime"
import "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "../platform"
import "../png"

@(private = "file")
Icon_Dir_Type :: enum u8 { Threshold, Fixed, Scalable }

@(private = "file")
Icon_Dir :: struct {
	sub:            string,
	size, scale:    int,
	min, max:       int,
	threshold:      int,
	type:           Icon_Dir_Type,
}

@(private = "file")
Icon_Theme :: struct {
	name:     string,
	bases:    []string,      // icons/<name> folders that exist, most important first
	dirs:     []Icon_Dir,
	inherits: []string,
}

@(private = "file")
Icon_Cache :: struct {
	mutex:  sync.Mutex,
	arena:  virtual.Arena,
	ready:  bool,
	key:    string,
	chain:  []^Icon_Theme,                 // the theme, what it inherits, hicolor
	found:  map[string]string,             // "name@size" -> the file ("" none)
	theme:  string,                        // the theme's name, read once (heap)
	named:  bool,
}

@(private = "file") icon_cache: Icon_Cache

// The icon theme the desktop shows (its name), "" when none is set.
@(private)
icon_theme_name :: proc(config: string, allocator := context.temp_allocator) -> string {
	for f in ([]string{"gtk-4.0/settings.ini", "gtk-3.0/settings.ini"}) {
		data, err := os.read_entire_file(strings.concatenate({config, "/", f}, context.temp_allocator), context.temp_allocator)
		if err != nil { continue }
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			l := strings.trim_space(line)
			if !strings.has_prefix(l, "gtk-icon-theme-name") { continue }
			at := strings.index_byte(l, '=')
			if at < 0 { continue }
			v := strings.trim(strings.trim_space(l[at + 1:]), "\"")
			if v != "" { return strings.clone(v, allocator) }
		}
	}
	if data, err := os.read_entire_file(strings.concatenate({config, "/kdeglobals"}, context.temp_allocator), context.temp_allocator); err == nil {
		text := string(data)
		in_icons := false
		for line in strings.split_lines_iterator(&text) {
			l := strings.trim_space(line)
			if strings.has_prefix(l, "[") { in_icons = l == "[Icons]"; continue }
			if in_icons && strings.has_prefix(l, "Theme=") { return strings.clone(l[len("Theme="):], allocator) }
		}
	}
	return ""
}

// The folders icon themes are under: ~/.icons, then icons/ of each data directory.
@(private = "file")
icon_roots :: proc(roots: Xdg_Roots) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	if home, err := os.user_home_dir(context.temp_allocator); err == nil && home != "" { append(&out, strings.concatenate({home, "/.icons"}, context.temp_allocator)) }
	for d in roots.data { append(&out, strings.concatenate({d, "/icons"}, context.temp_allocator)) }
	return out[:]
}

@(private = "file")
theme_read :: proc(name: string, roots: []string, a: runtime.Allocator) -> ^Icon_Theme {
	t := new(Icon_Theme, a)
	t.name = strings.clone(name, a)
	bases := make([dynamic]string, a)
	index := ""
	for r in roots {
		dir := strings.concatenate({r, "/", name}, a)
		if !os.is_dir(dir) { continue }
		append(&bases, dir)
		if index == "" {
			if data, err := os.read_entire_file(strings.concatenate({dir, "/index.theme"}, context.temp_allocator), a); err == nil { index = string(data) }
		}
	}
	if len(bases) == 0 { return nil }
	t.bases = bases[:]
	// index.theme: [Icon Theme] (Inherits, Directories, ScaledDirectories), then a group per subfolder
	groups := make(map[string]map[string]string, context.temp_allocator)
	group := ""
	text := index
	for line in strings.split_lines_iterator(&text) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' { continue }
		if l[0] == '[' && l[len(l) - 1] == ']' {
			group = l[1:len(l) - 1]
			if group not_in groups { groups[group] = make(map[string]string, context.temp_allocator) }
			continue
		}
		at := strings.index_byte(l, '=')
		if at <= 0 || group == "" { continue }
		(&groups[group])[strings.trim_space(l[:at])] = strings.trim_space(l[at + 1:])
	}
	head := groups["Icon Theme"]
	inherits := make([dynamic]string, a)
	for x in strings.split(head["Inherits"], ",", context.temp_allocator) { if v := strings.trim_space(x); v != "" { append(&inherits, strings.clone(v, a)) } }
	t.inherits = inherits[:]
	dirs := make([dynamic]Icon_Dir, a)
	list := strings.concatenate({head["Directories"], ",", head["ScaledDirectories"]}, context.temp_allocator)
	for x in strings.split(list, ",", context.temp_allocator) {
		sub := strings.trim_space(x)
		g, ok := groups[sub]
		if sub == "" || !ok { continue }
		d := Icon_Dir{sub = strings.clone(sub, a), scale = 1, threshold = 2}
		d.size, _ = strconv.parse_int(g["Size"])
		if v, vok := strconv.parse_int(g["Scale"]); vok { d.scale = v }
		if v, vok := strconv.parse_int(g["Threshold"]); vok { d.threshold = v }
		d.min, d.max = d.size, d.size
		if v, vok := strconv.parse_int(g["MinSize"]); vok { d.min = v }
		if v, vok := strconv.parse_int(g["MaxSize"]); vok { d.max = v }
		switch g["Type"] {
		case "Fixed":    d.type = .Fixed
		case "Scalable": d.type = .Scalable
		case:            d.type = .Threshold
		}
		if d.size > 0 { append(&dirs, d) }
	}
	t.dirs = dirs[:]
	return t
}

// The themes to look in, in order: the person's, what it inherits (depth first), hicolor. The caller holds the lock.
@(private = "file")
icon_cache_get :: proc(roots: Xdg_Roots, name: string) -> ^Icon_Cache {
	c := &icon_cache
	key := strings.concatenate({name, "\n", strings.join(roots.data, ":", context.temp_allocator)}, context.temp_allocator)
	if c.ready && c.key == key { return c }
	if c.ready { virtual.arena_destroy(&c.arena) }
	theme, named := c.theme, c.named
	c^ = {}
	c.theme, c.named = theme, named
	_ = virtual.arena_init_growing(&c.arena)
	a := virtual.arena_allocator(&c.arena)
	c.key = strings.clone(key, a)
	c.found = make(map[string]string, a)
	dirs := icon_roots(roots)
	chain := make([dynamic]^Icon_Theme, a)
	seen := make(map[string]bool, context.temp_allocator)
	visit :: proc(name: string, dirs: []string, chain: ^[dynamic]^Icon_Theme, seen: ^map[string]bool, a: runtime.Allocator, depth: int) {
		if name == "" || name in seen || depth > 8 { return }
		seen[name] = true
		t := theme_read(name, dirs, a)
		if t == nil { return }
		append(chain, t)
		for p in t.inherits { if p != "hicolor" { visit(p, dirs, chain, seen, a, depth + 1) } }
	}
	visit(name, dirs, &chain, &seen, a, 0)
	visit("hicolor", dirs, &chain, &seen, a, 0)
	c.chain = chain[:]
	c.ready = true
	return c
}

@(private = "file")
dir_matches :: proc(d: Icon_Dir, size: int) -> bool {
	if d.scale != 1 { return false }
	switch d.type {
	case .Fixed:     return d.size == size
	case .Scalable:  return d.min <= size && size <= d.max
	case .Threshold: return d.size - d.threshold <= size && size <= d.size + d.threshold
	}
	return false
}

@(private = "file")
dir_distance :: proc(d: Icon_Dir, size: int) -> int {
	switch d.type {
	case .Fixed:     return abs(d.size * d.scale - size)
	case .Scalable:
		if size < d.min * d.scale { return d.min * d.scale - size }
		if size > d.max * d.scale { return size - d.max * d.scale }
	case .Threshold:
		if size < (d.size - d.threshold) * d.scale { return d.min * d.scale - size }
		if size > (d.size + d.threshold) * d.scale { return size - d.max * d.scale }
	}
	return 0
}

// The file of icon `name` at `size` in the chain, "" when no theme has it. The caller holds the lock.
@(private = "file")
icon_file :: proc(c: ^Icon_Cache, name: string, size: int) -> string {
	k := strings.concatenate({name, "@", int_text(size)}, context.temp_allocator)
	if f, ok := c.found[k]; ok { return f }
	a := virtual.arena_allocator(&c.arena)
	found := ""
	exts := [?]string{".png", ".svg"}
	chain: for t in c.chain {
		for d in t.dirs {
			if !dir_matches(d, size) { continue }
			for b in t.bases { for e in exts {
				p := strings.concatenate({b, "/", d.sub, "/", name, e}, context.temp_allocator)
				if os.is_file(p) { found = p; break chain }
			} }
		}
		best := max(int)
		for d in t.dirs {
			dist := dir_distance(d, size)
			if dist >= best { continue }
			for b in t.bases { for e in exts {
				p := strings.concatenate({b, "/", d.sub, "/", name, e}, context.temp_allocator)
				if os.is_file(p) { found, best = p, dist; break }
			} }
		}
		if found != "" { break }
	}
	found = strings.clone(found, a)
	c.found[strings.clone(k, a)] = found
	return found
}

@(private = "file")
int_text :: proc(n: int) -> string {
	buf: [24]u8
	return strings.clone(strconv.write_int(buf[:], i64(n), 10), context.temp_allocator)
}

// The icon names of a folder, the most specific first.
@(private = "file")
folder_names :: proc(path: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	clean := strings.trim_right(path, "/")
	if clean == "" { append(&out, "drive-harddisk-root", "drive-harddisk", "folder"); return out[:] }
	specials := [?]struct { k: platform.Known_Folder, name: string }{
		{.Home, "user-home"}, {.Desktop, "user-desktop"}, {.Documents, "folder-documents"}, {.Downloads, "folder-download"},
		{.Music, "folder-music"}, {.Pictures, "folder-pictures"}, {.Videos, "folder-videos"},
	}
	for sp in specials {
		if p := platform.known_folder_path(sp.k, context.temp_allocator); p != "" && strings.trim_right(p, "/") == clean {
			append(&out, sp.name)
			break
		}
	}
	if strings.has_suffix(clean, "/Trash/files") || strings.has_suffix(clean, "/Trash") { append(&out, "user-trash") }
	append(&out, "folder")
	return out[:]
}

// The icon names of a file of type `mime`, the most specific first.
@(private = "file")
file_names :: proc(db: ^Mime_Database, mime: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	add :: proc(out: ^[dynamic]string, n: string) {
		for x in out { if x == n { return } }
		if n != "" { append(out, n) }
	}
	family := mime_family(db, mime)
	for m in family {
		if n, ok := db.icons[m]; ok { add(&out, n) }
		dashed, _ := strings.replace_all(m, "/", "-", context.temp_allocator)
		add(&out, dashed)
		if n, ok := db.generic[m]; ok { add(&out, n) }
	}
	for m in family {
		if at := strings.index_byte(m, '/'); at > 0 { add(&out, strings.concatenate({m[:at], "-x-generic"}, context.temp_allocator)) }
	}
	add(&out, "text-x-generic")
	add(&out, "unknown")
	return out[:]
}

@(private)
icon_key_native :: proc(path: string, folder: bool, allocator: runtime.Allocator) -> string {
	if folder {
		names := folder_names(path)
		return strings.concatenate({"folder:", names[0]}, allocator)
	}
	sync.mutex_guard(&mime_cache.mutex)
	db := mime_cache_get(&mime_cache, xdg_roots())
	return strings.concatenate({"type:", mime_of_file(db, path)}, allocator)
}

@(private)
icon_of_path_native :: proc(path: string, folder: bool, size, choose: int, allocator: runtime.Allocator) -> (icon: File_Icon, ok: bool) {
	theme: string
	{
		sync.mutex_guard(&icon_cache.mutex)
		if !icon_cache.named {
			// (the portal asked from this worker once: its connection is this thread's)
			name, asked := platform.portal_icon_theme(runtime.heap_allocator())
			if !asked { name = icon_theme_name(xdg_config_home(), runtime.heap_allocator()) }
			icon_cache.theme, icon_cache.named = name, true
		}
		theme = strings.clone(icon_cache.theme, context.temp_allocator)
	}
	return icon_of_path_in(xdg_roots(), theme, path, folder, size, allocator, choose)
}

// The icon of `path` from the XDG folders `roots` and the theme named `theme` (the tests give theirs).
@(private)
icon_of_path_in :: proc(roots: Xdg_Roots, theme: string, path: string, folder: bool, size: int, allocator: runtime.Allocator, choose := 0) -> (icon: File_Icon, ok: bool) {
	names: []string
	if folder {
		names = folder_names(path)
	} else {
		sync.mutex_guard(&mime_cache.mutex)
		db := mime_cache_get(&mime_cache, roots)
		found := file_names(db, mime_of_file(db, path))
		// (copied: the database's memory is not reached after the lock)
		copied := make([]string, len(found), context.temp_allocator)
		for n, i in found { copied[i] = strings.clone(n, context.temp_allocator) }
		names = copied
	}
	file := ""
	{
		sync.mutex_guard(&icon_cache.mutex)
		c := icon_cache_get(roots, theme)
		for n in names {
			if f := icon_file(c, n, choose > 0 ? choose : size); f != "" { file = strings.clone(f, context.temp_allocator); break }
		}
	}
	if file == "" { return }
	return icon_load(file, size, allocator)
}

// A theme's file as pixels: a PNG as it is, an SVG rendered at `size`.
@(private)
icon_load :: proc(file: string, size: int, allocator: runtime.Allocator) -> (icon: File_Icon, ok: bool) {
	data, err := os.read_entire_file(file, context.temp_allocator)
	if err != nil { return }
	if strings.has_suffix(file, ".svg") { return svg_render(data, size, allocator) }
	rgba, w, h, decoded := png.decode(data, allocator)
	if !decoded { return }
	return File_Icon{rgba, {w, h}}, true
}
