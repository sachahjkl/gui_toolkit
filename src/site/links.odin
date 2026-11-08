package tk_site

// The links of a built site, read from its files (no browser): every href and src of every page, resolved from the page's own
// folder, must name a file that is there, and a #fragment an id that page defines. A link that starts with "/" leaves a site
// that lives under a path of its own; a link may not climb out of the site. check.odin does the same in a browser, with more.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "../ascii"

Link_Rules :: struct {
	not_files: []string,   // the starts of addresses that are not files of the site (a scheme the project's program opens)
	folders:   bool,       // a page is linked by its folder ("pricing/"), never by its .html (but from a moved page)
}

// What is wrong with the links of the site in `root` (sorted, each once), and how many pages it has.
check_links :: proc(root: string, rules: Link_Rules) -> (dead: []string, pages: int) {
	all: [dynamic]Site_Page
	collect_site_pages(root, "", &all)
	ids := make(map[string]map[string]bool)
	for p in all {
		set: map[string]bool
		each_attr(p.text, proc(a: Tag_Attr, data: rawptr) { if a.name == "id" { (^map[string]bool)(data)[a.value] = true } }, &set)
		ids[p.rel] = set
	}
	found: [dynamic]string
	for &p in all {
		c := Link_Check{root = root, rules = rules, ids = &ids, page = &p, dead = &found}
		each_attr(p.text, visit_link, &c)
	}
	slice.sort(found[:])
	return slice.unique(found[:]), len(all)
}

@(private)
Site_Page :: struct {
	rel:      string,   // "docs/cdp/index.html", from the root
	text:     string,
	redirect: bool,     // a page left at an old address (a refresh)
}

@(private)
collect_site_pages :: proc(dir, prefix: string, out: ^[dynamic]Site_Page) {
	entries, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil { return }
	for e in entries {
		rel := prefix == "" ? e.name : strings.concatenate({prefix, "/", e.name})
		if e.type == .Directory { collect_site_pages(e.fullpath, rel, out); continue }
		if !strings.has_suffix(e.name, ".html") { continue }
		data, rerr := os.read_entire_file(e.fullpath, context.allocator)
		if rerr != nil { continue }
		text := string(data)
		append(out, Site_Page{rel, text, strings.contains(text, `http-equiv="refresh"`)})
	}
}

@(private)
Tag_Attr :: struct { name, value: string }

// The attributes of every tag of a page, in order. Comments, scripts and styles are skipped, so an address in a code sample's
// text (&lt;script src="..."&gt;) or one a script builds is not taken for a link.
@(private)
each_attr :: proc(text: string, visit: proc(a: Tag_Attr, data: rawptr), data: rawptr) {
	i := 0
	for i < len(text) {
		if text[i] != '<' { i += 1; continue }
		if strings.has_prefix(text[i:], "<!--") {
			end := strings.index(text[i:], "-->")
			if end < 0 { return }
			i += end + 3
			continue
		}
		j := i + 1
		if j >= len(text) || !is_letter(text[j]) { i += 1; continue }
		for j < len(text) && is_name_byte(text[j]) { j += 1 }
		tag := ascii.lower(text[i + 1:j])
		for j < len(text) && text[j] != '>' {
			if !is_name_byte(text[j]) { j += 1; continue }
			n0 := j
			for j < len(text) && is_name_byte(text[j]) { j += 1 }
			name := ascii.lower(text[n0:j])
			if j < len(text) && text[j] == '=' {
				j += 1
				if j < len(text) && (text[j] == '"' || text[j] == '\'') {
					q := text[j]
					end := strings.index_byte(text[j + 1:], q)
					if end < 0 { return }
					visit({name, text[j + 1:j + 1 + end]}, data)
					j += end + 2
				} else {
					v0 := j
					for j < len(text) && text[j] != ' ' && text[j] != '>' { j += 1 }
					visit({name, text[v0:j]}, data)
				}
			}
		}
		i = j
		if tag == "script" || tag == "style" {
			close := strings.index(text[i:], strings.concatenate({"</", tag}, context.temp_allocator))
			if close < 0 { return }
			i += close
		}
	}
}

@(private) is_letter :: proc(c: u8) -> bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') }
@(private) is_name_byte :: proc(c: u8) -> bool { return is_letter(c) || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == ':' }

@(private)
Link_Check :: struct {
	root:  string,
	rules: Link_Rules,
	ids:   ^map[string]map[string]bool,
	page:  ^Site_Page,
	dead:  ^[dynamic]string,
}

@(private)
visit_link :: proc(a: Tag_Attr, data: rawptr) {
	if a.name != "href" && a.name != "src" { return }
	c := (^Link_Check)(data)
	href := a.value
	if href == "" || is_external(href) || strings.has_prefix(href, "data:") || strings.has_prefix(href, "javascript:") { return }
	for prefix in c.rules.not_files { if strings.has_prefix(href, prefix) { return } }
	if strings.has_prefix(href, "/") {
		append(c.dead, fmt.aprintf("%s: %s starts with / and leaves the site (it lives under a path of its own): make it relative", c.page.rel, href))
		return
	}
	target, fragment := href, ""
	if hash := strings.index_byte(href, '#'); hash >= 0 { target, fragment = href[:hash], href[hash + 1:] }
	if q := strings.index_byte(target, '?'); q >= 0 { target = target[:q] }

	path := c.page.rel
	if target != "" {
		path = path_normalize(path_join(path_dir(c.page.rel), target))
		if strings.has_prefix(path, "..") {
			append(c.dead, fmt.aprintf("%s: %s climbs out of the site", c.page.rel, href))
			return
		}
		if strings.has_suffix(target, "/") || target == "." || target == ".." || strings.has_suffix(target, "/..") || strings.has_suffix(target, "/.") {
			path = path == "" ? "index.html" : strings.concatenate({path, "/index.html"})
		} else if c.rules.folders && strings.has_suffix(target, ".html") && !c.page.redirect && a.name == "href" {
			append(c.dead, fmt.aprintf("%s: %s names a .html: link the page's folder", c.page.rel, href))
			return
		}
	}

	if strings.has_suffix(path, ".html") {
		page_ids, known := c.ids[path]
		if !known { append(c.dead, fmt.aprintf("%s: link to missing page %s", c.page.rel, href)); return }
		if fragment != "" && fragment not_in page_ids { append(c.dead, fmt.aprintf("%s: link to missing anchor %s", c.page.rel, href)) }
		return
	}
	if !os.exists(strings.concatenate({c.root, "/", path}, context.temp_allocator)) {
		append(c.dead, fmt.aprintf("%s: link to missing file %s", c.page.rel, href))
	}
}
