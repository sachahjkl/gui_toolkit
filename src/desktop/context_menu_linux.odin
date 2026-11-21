#+build linux
package tk_desktop

// System shell context menu on Linux (src/md/features/context-menu.md): parses declarative file-manager action files
// on the worker thread using xdg_roots() and mime_cache:
//   * KIO / KDE service menus (<data>/kio/servicemenus/*.desktop, <data>/kservices5/ServiceMenus/*.desktop)
//   * Nemo actions (<data>/nemo/actions/*.nemo_action)
//   * Thunar custom actions (<config>/Thunar/uca.xml)
//
// Matching actions expand their placeholders for the target paths and are kept per opaque item id in the native
// session until invoked (platform.launch_detached) or cleared.

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "../ascii"
import "../platform"

@(private)
Context_Menu_Native :: struct {
	commands: map[u32][]string,   // owned (heap): expanded argv per Context_Item.id
}

@(private)
context_menu_native_init :: proc(ns: ^Context_Menu_Native) {}

@(private)
context_menu_native_end :: proc(ns: ^Context_Menu_Native) {
	context_menu_native_clear(ns)
}

@(private)
context_menu_native_clear :: proc(ns: ^Context_Menu_Native) {
	a := runtime.heap_allocator()
	for _, argv in ns.commands {
		for s in argv { delete(s, a) }
		delete(argv, a)
	}
	delete(ns.commands)
	ns.commands = nil
}

@(private)
context_menu_native_query :: proc(ns: ^Context_Menu_Native, req: Context_Query_Req, allocator: runtime.Allocator) -> []Context_Item {
	roots := xdg_roots()
	sync.mutex_guard(&mime_cache.mutex)
	db := mime_cache_get(&mime_cache, roots)
	return linux_context_query(ns, db, roots, req, allocator, resolve_icons = true)
}

@(private)
context_menu_native_invoke :: proc(ns: ^Context_Menu_Native, id: u32, hwnd: rawptr) -> bool {
	_ = hwnd
	argv, ok := ns.commands[id]
	if !ok || len(argv) == 0 { return false }
	return platform.launch_detached(argv)
}

////////////////////////////////
// Pure query & parsers (tested directly with synthetic Xdg_Roots)

@(private)
Target_Info :: struct {
	paths:      []string,
	background: bool,
	all_dirs:   bool,
	any_dir:    bool,
	all_files:  bool,
	mimes:      [][]string,   // per path: its MIME family (mime_family)
}

@(private = "file")
Linux_Icon_Cache :: struct {
	resolve: bool,
	entries: map[string]File_Icon,
}

@(private = "file")
linux_icon_lookup :: proc(cache: ^Linux_Icon_Cache, name: string) -> File_Icon {
	if !cache.resolve || name == "" { return {} }
	if existing, ok := cache.entries[name]; ok { return existing }
	ic, ok := theme_icon_native(name, 16, context.temp_allocator)
	if !ok { ic = {} }
	cache.entries[name] = ic
	return ic
}

@(private)
linux_context_query :: proc(ns: ^Context_Menu_Native, db: ^Mime_Database, roots: Xdg_Roots, req: Context_Query_Req, allocator: runtime.Allocator, resolve_icons := false) -> []Context_Item {
	if len(req.paths) == 0 { return nil }
	info := target_info_build(db, req.paths, req.background)

	raw := make([dynamic]Context_Item, context.temp_allocator)
	submenus := make(map[string][dynamic]Context_Item, context.temp_allocator)
	submenu_icons := make(map[string]File_Icon, context.temp_allocator)
	submenu_order := make([dynamic]string, context.temp_allocator)
	icon_cache := Linux_Icon_Cache{resolve = resolve_icons, entries = make(map[string]File_Icon, context.temp_allocator)}
	next_id := u32(1)
	ns.commands = make(map[u32][]string, 16, runtime.heap_allocator())

	add_action :: proc(ns: ^Context_Menu_Native, raw: ^[dynamic]Context_Item, submenus: ^map[string][dynamic]Context_Item,
		submenu_icons: ^map[string]File_Icon, submenu_order: ^[dynamic]string, icons: ^Linux_Icon_Cache,
		next_id: ^u32, label, submenu, verb, icon_name, sub_icon_name: string, argv: []string) {
		if label == "" || len(argv) == 0 { return }
		id := next_id^
		next_id^ += 1
		a := runtime.heap_allocator()
		copied := make([]string, len(argv), a)
		for s, i in argv { copied[i] = strings.clone(s, a) }
		ns.commands[id] = copied
		it := Context_Item{id = id, label = label, verb = verb, icon = linux_icon_lookup(icons, icon_name)}
		if submenu != "" {
			if submenu not_in submenus {
				submenus[submenu] = make([dynamic]Context_Item, context.temp_allocator)
				append(submenu_order, submenu)
			}
			if sub_icon_name != "" && submenu not_in submenu_icons {
				submenu_icons[submenu] = linux_icon_lookup(icons, sub_icon_name)
			}
			append(&submenus[submenu], it)
		} else {
			append(raw, it)
		}
	}

	// 1. KIO / KDE service menus
	seen_kio := make(map[string]bool, context.temp_allocator)
	for root in roots.data {
		for sub in ([?]string{"/kio/servicemenus", "/kservices5/ServiceMenus"}) {
			dir := strings.concatenate({root, sub}, context.temp_allocator)
			entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
			if err != nil { continue }
			slice.sort_by(entries, proc(a, b: os.File_Info) -> bool { return a.name < b.name })
			for fi in entries {
				if !strings.has_suffix(fi.name, ".desktop") || seen_kio[fi.name] { continue }
				seen_kio[fi.name] = true
				text, rerr := os.read_entire_file(fi.fullpath, context.temp_allocator)
				if rerr != nil { continue }
				kio_parse(string(text), fi.fullpath, info, ns, &raw, &submenus, &submenu_icons, &submenu_order, &icon_cache, &next_id, add_action)
			}
		}
	}

	// 2. Nemo actions
	seen_nemo := make(map[string]bool, context.temp_allocator)
	for root in roots.data {
		dir := strings.concatenate({root, "/nemo/actions"}, context.temp_allocator)
		entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil { continue }
		slice.sort_by(entries, proc(a, b: os.File_Info) -> bool { return a.name < b.name })
		for fi in entries {
			if !strings.has_suffix(fi.name, ".nemo_action") || seen_nemo[fi.name] { continue }
			seen_nemo[fi.name] = true
			text, rerr := os.read_entire_file(fi.fullpath, context.temp_allocator)
			if rerr != nil { continue }
			nemo_parse(string(text), info, ns, &raw, &submenus, &submenu_icons, &submenu_order, &icon_cache, &next_id, add_action)
		}
	}

	// 3. Thunar custom actions (uca.xml — first existing file in XDG config order wins, as Thunar does)
	for root in roots.config {
		path := strings.concatenate({root, "/Thunar/uca.xml"}, context.temp_allocator)
		text, rerr := os.read_entire_file(path, context.temp_allocator)
		if rerr != nil { continue }
		thunar_uca_parse(string(text), info, ns, &raw, &submenus, &submenu_icons, &submenu_order, &icon_cache, &next_id, add_action)
		break
	}

	for name in submenu_order {
		kids := submenus[name]
		if len(kids) > 0 { append(&raw, Context_Item{label = name, icon = submenu_icons[name], children = kids[:]}) }
	}
	return context_items_prune(raw[:], req.exclude_verbs, allocator)
}

@(private = "file")
target_info_build :: proc(db: ^Mime_Database, paths: []string, background: bool) -> Target_Info {
	info := Target_Info{
		paths      = paths,
		background = background,
		all_dirs   = true,
		all_files  = true,
		mimes      = make([][]string, len(paths), context.temp_allocator),
	}
	for p, i in paths {
		is_d := background || os.is_dir(p)
		if is_d {
			info.any_dir = true
			info.all_files = false
			info.mimes[i] = mime_family(db, "inode/directory")
		} else {
			info.all_dirs = false
			info.mimes[i] = mime_family(db, mime_of_name(db, filepath.base(p)))
		}
	}
	return info
}

// Matches a target against a list of MIME patterns (supports exact types, "image/*", "all/all", "all/allfiles").
@(private = "file")
mimes_match_all :: proc(info: Target_Info, patterns: []string) -> bool {
	if len(patterns) == 0 { return true }
	for fam, idx in info.mimes {
		matched := false
		is_dir := info.background || (len(fam) > 0 && fam[0] == "inode/directory")
		for pat in patterns {
			if pat == "" { continue }
			if pat == "all/all" || pat == "*" || pat == "*/*" { matched = true; break }
			if pat == "all/allfiles" && !is_dir { matched = true; break }
			if strings.has_suffix(pat, "/*") {
				prefix := pat[:len(pat) - 1]
				for m in fam { if strings.has_prefix(m, prefix) { matched = true; break } }
				if matched { break }
			} else {
				for m in fam { if m == pat { matched = true; break } }
				if matched { break }
			}
		}
		_ = idx
		if !matched { return false }
	}
	return true
}

////////////////////////////////
// KIO service menus (*.desktop)

@(private = "file")
Linux_Add_Action :: proc(^Context_Menu_Native, ^[dynamic]Context_Item, ^map[string][dynamic]Context_Item, ^map[string]File_Icon, ^[dynamic]string, ^Linux_Icon_Cache, ^u32, string, string, string, string, string, []string)

@(private = "file")
kio_parse :: proc(text, file: string, info: Target_Info, ns: ^Context_Menu_Native,
	raw: ^[dynamic]Context_Item, submenus: ^map[string][dynamic]Context_Item, submenu_icons: ^map[string]File_Icon, submenu_order: ^[dynamic]string, icons: ^Linux_Icon_Cache, next_id: ^u32,
	add: Linux_Add_Action) {

	if info.background { return }
	if v, ok := entry_value(text, "Hidden"); ok && ascii.equal_fold(v, "true") { return }
	if v, ok := entry_value(text, "NoDisplay"); ok && ascii.equal_fold(v, "true") { return }
	actions_raw, has_actions := entry_value(text, "Actions")
	if !has_actions || actions_raw == "" { return }
	if try_exec, ok := entry_value(text, "TryExec"); ok && try_exec != "" && !program_in_path(try_exec) { return }

	mimes_raw, _ := entry_value(text, "MimeType")
	if mimes_raw == "" { mimes_raw, _ = entry_value(text, "X-KDE-ServiceTypes") }
	mimes := make([dynamic]string, context.temp_allocator)
	for m in split_list(mimes_raw, context.temp_allocator) {
		if m != "KonqPopupMenu/Plugin" { append(&mimes, m) }
	}
	if !mimes_match_all(info, mimes[:]) { return }

	submenu, _ := entry_value(text, "X-KDE-Submenu")
	submenu = unescape_value(submenu)
	sub_icon, _ := entry_value(text, "X-KDE-Submenu-Icon")
	if sub_icon == "" { sub_icon, _ = entry_value(text, "Icon") }
	for act in split_list(actions_raw, context.temp_allocator) {
		section := strings.concatenate({"[Desktop Action ", act, "]"}, context.temp_allocator)
		name := unescape_value(section_value(text, section, "Name"))
		exec := section_value(text, section, "Exec")
		icon_name := section_value(text, section, "Icon")
		if name == "" || exec == "" { continue }
		if argv, ok := expand_action_command(exec, info.paths, name, file); ok {
			add(ns, raw, submenus, submenu_icons, submenu_order, icons, next_id, name, submenu, act, icon_name, sub_icon, argv)
		}
	}
}

////////////////////////////////
// Nemo actions (*.nemo_action)

@(private = "file")
nemo_parse :: proc(text: string, info: Target_Info, ns: ^Context_Menu_Native,
	raw: ^[dynamic]Context_Item, submenus: ^map[string][dynamic]Context_Item, submenu_icons: ^map[string]File_Icon, submenu_order: ^[dynamic]string, icons: ^Linux_Icon_Cache, next_id: ^u32,
	add: Linux_Add_Action) {

	sec :: "[Nemo Action]"
	if active := section_value(text, sec, "Active"); active != "" && ascii.equal_fold(active, "false") { return }
	name := unescape_value(section_value(text, sec, "Name"))
	exec := section_value(text, sec, "Exec")
	if name == "" || exec == "" { return }

	sel := section_value(text, sec, "Selection")
	n := len(info.paths)
	switch ascii.lower(sel, context.temp_allocator) {
	case "none":          if !info.background { return }
	case "s", "single":   if info.background || n != 1 { return }
	case "m", "multiple": if info.background || n < 2 { return }
	case "notnone", "":   if info.background { return }
	case "any":           // matches single, multiple, or background
	}

	if exts_raw := section_value(text, sec, "Extensions"); exts_raw != "" {
		exts := split_list(exts_raw, context.temp_allocator)
		if !nemo_extensions_match(info, exts) { return }
	}
	if mimes_raw := section_value(text, sec, "Mimetypes"); mimes_raw != "" {
		if !mimes_match_all(info, split_list(mimes_raw, context.temp_allocator)) { return }
	}

	icon_name := section_value(text, sec, "Icon-Name")
	if argv, ok := expand_action_command(exec, info.paths, name, ""); ok {
		add(ns, raw, submenus, submenu_icons, submenu_order, icons, next_id, name, "", "", icon_name, "", argv)
	}
}

@(private = "file")
nemo_extensions_match :: proc(info: Target_Info, exts: []string) -> bool {
	for p, i in info.paths {
		is_dir := info.background || (len(info.mimes[i]) > 0 && info.mimes[i][0] == "inode/directory")
		ext := strings.trim_prefix(filepath.ext(p), ".")
		ok := false
		for e in exts {
			le := ascii.lower(e, context.temp_allocator)
			switch le {
			case "any":    ok = true
			case "dir":    if is_dir { ok = true }
			case "nodirs": if !is_dir { ok = true }
			case:          if !is_dir && ascii.equal_fold(ext, strings.trim_prefix(le, ".")) { ok = true }
			}
			if ok { break }
		}
		if !ok { return false }
	}
	return true
}

////////////////////////////////
// Thunar custom actions (uca.xml)

@(private = "file")
thunar_uca_parse :: proc(xml: string, info: Target_Info, ns: ^Context_Menu_Native,
	raw: ^[dynamic]Context_Item, submenus: ^map[string][dynamic]Context_Item, submenu_icons: ^map[string]File_Icon, submenu_order: ^[dynamic]string, icons: ^Linux_Icon_Cache, next_id: ^u32,
	add: Linux_Add_Action) {

	rest := xml
	for {
		open := strings.index(rest, "<action>")
		if open < 0 { break }
		rest = rest[open + len("<action>"):]
		close := strings.index(rest, "</action>")
		if close < 0 { break }
		block := rest[:close]
		rest = rest[close + len("</action>"):]

		name := xml_tag_text(block, "name")
		cmd := xml_tag_text(block, "command")
		submenu := xml_tag_text(block, "submenu")
		icon_name := xml_tag_text(block, "icon")
		patterns_raw := xml_tag_text(block, "patterns")
		if name == "" || cmd == "" { continue }

		has_dirs   := strings.contains(block, "<directories/>") || strings.contains(block, "<directories>")
		has_audio  := strings.contains(block, "<audio-files/>") || strings.contains(block, "<audio-files>")
		has_image  := strings.contains(block, "<image-files/>") || strings.contains(block, "<image-files>")
		has_text   := strings.contains(block, "<text-files/>")  || strings.contains(block, "<text-files>")
		has_video  := strings.contains(block, "<video-files/>") || strings.contains(block, "<video-files>")
		has_other  := strings.contains(block, "<other-files/>") || strings.contains(block, "<other-files>")

		if !thunar_types_match(info, has_dirs, has_audio, has_image, has_text, has_video, has_other) { continue }
		if !thunar_patterns_match(info, patterns_raw) { continue }

		if argv, ok := expand_action_command(cmd, info.paths, name, ""); ok {
			add(ns, raw, submenus, submenu_icons, submenu_order, icons, next_id, name, submenu, "", icon_name, "", argv)
		}
	}
}

@(private = "file")
thunar_types_match :: proc(info: Target_Info, dirs, audio, image, text, video, other: bool) -> bool {
	if !dirs && !audio && !image && !text && !video && !other { return true }
	for fam in info.mimes {
		m := len(fam) > 0 ? fam[0] : "application/octet-stream"
		ok := false
		switch {
		case m == "inode/directory":          ok = dirs
		case strings.has_prefix(m, "audio/"): ok = audio
		case strings.has_prefix(m, "image/"): ok = image
		case strings.has_prefix(m, "video/"): ok = video
		case strings.has_prefix(m, "text/"):  ok = text
		case:                                 ok = other
		}
		if !ok { return false }
	}
	return true
}

@(private = "file")
thunar_patterns_match :: proc(info: Target_Info, patterns_raw: string) -> bool {
	if patterns_raw == "" || patterns_raw == "*" { return true }
	pats := split_list(patterns_raw, context.temp_allocator)
	for p in info.paths {
		base := filepath.base(p)
		ok := false
		for pat in pats {
			if pat == "*" { ok = true; break }
			if m, _ := filepath.match(pat, base); m { ok = true; break }
		}
		if !ok { return false }
	}
	return true
}

@(private = "file")
xml_tag_text :: proc(block, tag: string) -> string {
	open := strings.concatenate({"<", tag, ">"}, context.temp_allocator)
	close := strings.concatenate({"</", tag, ">"}, context.temp_allocator)
	i := strings.index(block, open)
	if i < 0 { return "" }
	rest := block[i + len(open):]
	j := strings.index(rest, close)
	if j < 0 { return "" }
	s := strings.trim_space(rest[:j])
	for e in ([][2]string{{"&lt;", "<"}, {"&gt;", ">"}, {"&quot;", "\""}, {"&apos;", "'"}, {"&amp;", "&"}}) {
		s, _ = strings.replace_all(s, e[0], e[1], context.temp_allocator)
	}
	return s
}

////////////////////////////////
// INI section reading & command expansion

@(private = "file")
section_value :: proc(text, header, key: string) -> string {
	in_sec := false
	for raw in strings.split_lines(text, context.temp_allocator) {
		line := strings.trim_space(raw)
		if line == "" || line[0] == '#' { continue }
		if line[0] == '[' {
			in_sec = line == header
			continue
		}
		if !in_sec { continue }
		eq := strings.index_byte(line, '=')
		if eq < 0 { continue }
		if strings.trim_space(line[:eq]) == key { return strings.trim_space(line[eq + 1:]) }
	}
	return ""
}

// Expands desktop/Thunar/Nemo command placeholders (%f/%F/%u/%U/%d/%D/%n/%N/%c/%k/%%) for `paths`.
@(private)
expand_action_command :: proc(cmd: string, paths: []string, name, file: string, allocator := context.temp_allocator) -> ([]string, bool) {
	if len(paths) == 0 { return nil, false }
	args := exec_arguments(cmd, context.temp_allocator)
	if len(args) == 0 { return nil, false }
	out := make([dynamic]string, 0, len(args) + len(paths), allocator)
	first := paths[0]
	used_path := false
	for a in args {
		switch a.text {
		case "%F":
			used_path = true
			for p in paths { append(&out, strings.clone(p, allocator)) }
			continue
		case "%U":
			used_path = true
			for p in paths { append(&out, strings.concatenate({"file://", p}, allocator)) }
			continue
		case "%N":
			used_path = true
			for p in paths { append(&out, strings.clone(filepath.base(p), allocator)) }
			continue
		case "%D":
			used_path = true
			for p in paths { append(&out, strings.clone(filepath.dir(p), allocator)) }
			continue
		}
		sb := strings.builder_make(context.temp_allocator)
		for i := 0; i < len(a.text); i += 1 {
			if a.text[i] != '%' || i + 1 >= len(a.text) {
				strings.write_byte(&sb, a.text[i])
				continue
			}
			i += 1
			switch a.text[i] {
			case '%': strings.write_byte(&sb, '%')
			case 'f', 'F': used_path = true; strings.write_string(&sb, first)
			case 'u', 'U': used_path = true; strings.write_string(&sb, "file://"); strings.write_string(&sb, first)
			case 'd', 'D': used_path = true; strings.write_string(&sb, filepath.dir(first))
			case 'n', 'N': used_path = true; strings.write_string(&sb, filepath.base(first))
			case 'c': strings.write_string(&sb, name)
			case 'k': strings.write_string(&sb, file)
			case:     strings.write_byte(&sb, '%'); strings.write_byte(&sb, a.text[i])
			}
		}
		append(&out, strings.clone(strings.to_string(sb), allocator))
	}
	if !used_path { append(&out, strings.clone(first, allocator)) }
	if len(out) == 0 || out[0] == "" { return nil, false }
	return out[:], true
}

@(private = "file")
program_in_path :: proc(prog: string) -> bool {
	if filepath.is_abs(prog) { return os.exists(prog) }
	path := os.get_env("PATH", context.temp_allocator)
	for dir in strings.split_iterator(&path, ":") {
		if dir == "" { continue }
		if os.exists(strings.concatenate({dir, "/", prog}, context.temp_allocator)) { return true }
	}
	return false
}
