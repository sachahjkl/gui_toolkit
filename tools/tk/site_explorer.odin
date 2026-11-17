package tk

// The plugin API's explorer, plugins/api/ of the site (src/md/features/plugins.md, "An API explorer on the toolkit's
// site"): one static page made from plugin-api/api.json when the site is built, so it never lags the declarations. It
// reads nothing else: the JSON is what `tk plugin_api` writes from src/plugin_api/api.odin. The page wears the home
// page's bar and menu script (from <site>/index.html, as the Docs pages do); a small script filters its calls and nodes.
// A missing or malformed api.json stops site_build: a stale explorer is never published.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import tk_json "../../src/json"
import tk_site "../../src/site"

// The explorer's folder in the site, and its page from the site's root (what the links are made relative to).
EXPLORER_DIR :: "plugins/api"
EXPLORER_PAGE :: EXPLORER_DIR + "/index.html"

// A field of an argument list, an object or a node. `state`: the host keeps it (a field's text, a box's state): the
// person's change wins until the plugin has heard of it.
Explorer_Field :: struct {
	name, type, doc: string,
	optional, state: bool,
}

Explorer_Call :: struct {
	module, name, doc, capability, result: string,
	level:     int,
	arguments: []Explorer_Field,
}

Explorer_Node :: struct {
	name, type, doc: string,
	level:     int,
	container: bool,
	fields:    []Explorer_Field,
}

Explorer_Type :: struct {
	name, doc: string,
	is_enum:   bool,
	values:    []string,
	fields:    []Explorer_Field,
}

Explorer_Api :: struct {
	level, oldest: int,
	modules:       []string,   // in the file's order
	calls:         []Explorer_Call,
	nodes:         []Explorer_Node,
	types:         []Explorer_Type,
}

// Reads `<api_dir>/api.json` and `<api_dir>/gt.d.ts`, and `<site>/index.html` for the bar; writes `<out>/plugins/api/`:
// its page, and the two files beside it.
build_api_explorer :: proc(api_dir, site, out: string) -> string {
	json_path, dts_path := join({api_dir, "api.json"}), join({api_dir, "gt.d.ts"})
	text, has_json := read_text(json_path)
	if !has_json { return fmt.tprintf("%s cannot be read: the API explorer is made from it (odin run tools/tk -- plugin_api)", json_path) }
	api, why := explorer_read(text)
	if why != "" { return fmt.tprintf("%s: %s", json_path, why) }
	dts, has_dts := read_text(dts_path)
	if !has_dts { return fmt.tprintf("%s cannot be read: the API explorer offers it", dts_path) }
	index, has_index := read_text(join({site, "index.html"}))
	if !has_index { return fmt.tprintf("%s/index.html cannot be read", site) }
	header := between(index, "<header class=\"bar\">", "</header>")
	script := between(index, "<script>", "</script>")
	if header == "" || script == "" { return fmt.tprintf("%s/index.html has no header or no script", site) }

	dir := join({out, EXPLORER_DIR})
	if err := os.make_directory_all(dir); err != nil && err != .Exist { return fmt.tprintf("cannot make %s: %v", dir, err) }
	if !tk_site.write_text(join({dir, "index.html"}), explorer_html(api, header, script)) { return "the API explorer's page was not written" }
	if !tk_site.write_text(join({dir, "api.json"}), text) || !tk_site.write_text(join({dir, "gt.d.ts"}), dts) {
		return "the API explorer's files were not written"
	}
	fmt.printfln("the API explorer, level %d: %d calls, %d nodes", api.level, len(api.calls), len(api.nodes))
	return ""
}

////////////////////////////////
// Reading api.json (docs/plugin-api.md, "The explorer's file"). A key the explorer does not know is skipped: a level
// only adds keys. A key it needs that is missing or of another type is an error that names where.

@(private = "file")
Reader :: struct { why: string }

@(private = "file")
reader_fail :: proc(r: ^Reader, format: string, args: ..any) {
	if r.why == "" { r.why = fmt.tprintf(format, ..args) }
}

@(private = "file")
need_text :: proc(r: ^Reader, v: json.Value, key, at: string) -> string {
	s, ok := tk_json.get(v, key).(json.String)
	if !ok { reader_fail(r, "%s: no string %q", at, key) }
	return string(s)
}

@(private = "file")
need_int :: proc(r: ^Reader, v: json.Value, key, at: string) -> int {
	NONE :: min(i64)
	n := tk_json.integer(v, key, default = NONE)
	if n == NONE { reader_fail(r, "%s: no whole number %q", at, key); return 0 }
	return int(n)
}

@(private = "file")
need_bool :: proc(r: ^Reader, v: json.Value, key, at: string) -> bool {
	b, ok := tk_json.get(v, key).(json.Boolean)
	if !ok { reader_fail(r, "%s: no boolean %q", at, key) }
	return bool(b)
}

@(private = "file")
need_array :: proc(r: ^Reader, v: json.Value, key, at: string) -> json.Array {
	a, ok := tk_json.get(v, key).(json.Array)
	if !ok { reader_fail(r, "%s: no array %q", at, key) }
	return a
}

// An anchor of the page is one entry's: two would make a doc's link land on the first.
@(private = "file")
anchor_once :: proc(r: ^Reader, seen: ^map[string]bool, id, at: string) {
	if id in seen^ { reader_fail(r, "%s: %s twice", at, id) }
	seen^[id] = true
}

@(private = "file")
need_fields :: proc(r: ^Reader, v: json.Value, key, at: string) -> []Explorer_Field {
	list := need_array(r, v, key, at)
	out := make([]Explorer_Field, len(list), context.temp_allocator)
	for f, i in list {
		here := fmt.tprintf("%s.%s[%d]", at, key, i)
		out[i] = {
			name     = need_text(r, f, "name", here),
			type     = need_text(r, f, "type", here),
			doc      = need_text(r, f, "doc", here),
			optional = need_bool(r, f, "optional", here),
			state    = tk_json.boolean(f, "state"),   // (absent: not a state)
		}
		if out[i].name == "" { reader_fail(r, "%s: an empty name", here) }
	}
	return out
}

// The explorer's view of api.json, or why it cannot be one.
explorer_read :: proc(text: string) -> (api: Explorer_Api, why: string) {
	root, err := json.parse_string(text, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	if err != .None { return {}, fmt.tprintf("not JSON (%v)", err) }
	if _, is_object := root.(json.Object); !is_object { return {}, "not an object" }
	r: Reader
	api.level = need_int(&r, root, "level", "the file")
	api.oldest = need_int(&r, root, "oldest", "the file")
	if r.why == "" && (api.level < 1 || api.oldest < 1 || api.oldest > api.level) {
		reader_fail(&r, "level %d and oldest %d are not two levels", api.level, api.oldest)
	}

	anchors := make(map[string]bool, context.temp_allocator)

	modules := need_array(&r, root, "modules", "the file")
	if r.why == "" && len(modules) == 0 { reader_fail(&r, "no module") }
	names := make([dynamic]string, context.temp_allocator)
	calls := make([dynamic]Explorer_Call, context.temp_allocator)
	for m, mi in modules {
		at := fmt.tprintf("modules[%d]", mi)
		name := need_text(&r, m, "name", at)
		if r.why == "" && name == "" { reader_fail(&r, "%s: an empty name", at) }
		append(&names, name)
		list := need_array(&r, m, "calls", at)
		if r.why == "" && len(list) == 0 { reader_fail(&r, "%s: no call", at) }
		for c, ci in list {
			here := fmt.tprintf("%s.calls[%d]", at, ci)
			call := Explorer_Call{
				module     = name,
				name       = need_text(&r, c, "name", here),
				doc        = need_text(&r, c, "doc", here),
				level      = need_int(&r, c, "level", here),
				capability = need_text(&r, c, "capability", here),
				result     = need_text(&r, c, "result", here),
				arguments  = need_fields(&r, c, "arguments", here),
			}
			if r.why == "" && call.name == "" { reader_fail(&r, "%s: an empty name", here) }
			if r.why == "" && (call.level < 1 || call.level > api.level) { reader_fail(&r, "%s.%s: level %d", name, call.name, call.level) }
			anchor_once(&r, &anchors, fmt.tprintf("%s.%s", name, call.name), here)
			append(&calls, call)
		}
	}

	nodes := make([dynamic]Explorer_Node, context.temp_allocator)
	for n, ni in need_array(&r, root, "nodes", "the file") {
		here := fmt.tprintf("nodes[%d]", ni)
		node := Explorer_Node{
			name      = need_text(&r, n, "name", here),
			type      = need_text(&r, n, "type", here),
			doc       = need_text(&r, n, "doc", here),
			level     = need_int(&r, n, "level", here),
			container = need_bool(&r, n, "container", here),
			fields    = need_fields(&r, n, "fields", here),
		}
		if r.why == "" && node.name == "" { reader_fail(&r, "%s: an empty name", here) }
		if r.why == "" && (node.level < 1 || node.level > api.level) { reader_fail(&r, "the node %s: level %d", node.name, node.level) }
		anchor_once(&r, &anchors, fmt.tprintf("node.%s", node.name), here)
		append(&nodes, node)
	}

	types := make([dynamic]Explorer_Type, context.temp_allocator)
	for t, ti in need_array(&r, root, "types", "the file") {
		here := fmt.tprintf("types[%d]", ti)
		ty := Explorer_Type{name = need_text(&r, t, "name", here), doc = need_text(&r, t, "doc", here)}
		switch kind := need_text(&r, t, "kind", here); kind {
		case "enum":
			ty.is_enum = true
			values := need_array(&r, t, "values", here)
			ty.values = make([]string, len(values), context.temp_allocator)
			for v, vi in values {
				s, is_string := v.(json.String)
				if !is_string { reader_fail(&r, "%s.values[%d]: not a string", here, vi) }
				ty.values[vi] = string(s)
			}
		case "object":
			ty.fields = need_fields(&r, t, "fields", here)
		case:
			if r.why == "" { reader_fail(&r, "%s: kind %q is neither \"enum\" nor \"object\"", here, kind) }
		}
		anchor_once(&r, &anchors, fmt.tprintf("type.%s", ty.name), here)
		append(&types, ty)
	}
	if r.why != "" { return {}, r.why }
	api.modules, api.calls, api.nodes, api.types = names[:], calls[:], nodes[:], types[:]
	return api, ""
}

////////////////////////////////
// The page

// The TypeScript of a call, as gt.d.ts declares it: `views.register(id: string, render: () => Node): void`.
explorer_call_signature :: proc(c: Explorer_Call) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%s.%s(", c.module, c.name)
	for f, i in c.arguments { fmt.sbprintf(&b, "%s%s%s: %s", i == 0 ? "" : ", ", f.name, f.optional ? "?" : "", f.type) }
	fmt.sbprintf(&b, "): %s", c.result)
	return strings.to_string(b)
}

// A node as a render writes it: its kind, its key, its fields.
@(private = "file")
node_signature :: proc(n: Explorer_Node) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "{{\n  kind: \"%s\";\n  key?: string | number;\n", n.name)
	for f in n.fields { fmt.sbprintf(&b, "  %s%s: %s;\n", f.name, f.optional ? "?" : "", f.type) }
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

@(private = "file")
type_signature :: proc(t: Explorer_Type) -> string {
	b := strings.builder_make(context.temp_allocator)
	if t.is_enum {
		fmt.sbprintf(&b, "type %s =", t.name)
		for v, i in t.values { fmt.sbprintf(&b, "%s \"%s\"", i == 0 ? "" : " |", v) }
		strings.write_string(&b, ";")
		return strings.to_string(b)
	}
	fmt.sbprintf(&b, "interface %s {{\n", t.name)
	for f in t.fields { fmt.sbprintf(&b, "  %s%s: %s;\n", f.name, f.optional ? "?" : "", f.type) }
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// TypeScript as HTML: escaped, each name of a type of the file a link to its entry ("Node" to the nodes).
@(private = "file")
ts_html :: proc(text: string, links: map[string]string) -> string {
	word :: proc(c: u8) -> bool { return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') }
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(text) {
		if !word(text[i]) {
			j := i
			for j < len(text) && !word(text[j]) { j += 1 }
			strings.write_string(&b, tk_site.esc(text[i:j]))
			i = j
			continue
		}
		j := i
		for j < len(text) && word(text[j]) { j += 1 }
		name := text[i:j]
		// (a name inside a string literal, `kind: "text"`, is a value: those are lower case, the types' names are not)
		if anchor, known := links[name]; known {
			fmt.sbprintf(&b, "<a href=\"#%s\">%s</a>", anchor, name)
		} else {
			strings.write_string(&b, name)
		}
		i = j
	}
	return strings.to_string(b)
}

@(private = "file")
fields_table :: proc(b: ^strings.Builder, head: string, fields: []Explorer_Field, links: map[string]string) {
	if len(fields) == 0 { return }
	fmt.sbprintf(b, "<div class=\"api-table\"><table>\n<thead><tr><th>%s</th><th>Type</th><th></th></tr></thead>\n<tbody>\n", head)
	for f in fields {
		fmt.sbprintf(b, "<tr><td><code>%s</code>", tk_site.esc(f.name))
		if f.optional { strings.write_string(b, " <span class=\"pill\">optional</span>") }
		if f.state { strings.write_string(b, " <span class=\"pill state\" title=\"The host keeps it: what the person changed stays until the plugin has heard of it.\">state</span>") }
		fmt.sbprintf(b, "</td><td><code>%s</code></td><td>%s</td></tr>\n", ts_html(f.type, links), tk_site.esc(f.doc))
	}
	strings.write_string(b, "</tbody>\n</table></div>\n")
}

@(private = "file")
level_pill :: proc(b: ^strings.Builder, level: int) {
	fmt.sbprintf(b, " <a class=\"pill\" href=\"#level.%d\">level %d</a>", level, level)
}

// The whole page, its links made relative to plugins/api/. `header` is the inside of the home's `<header class="bar">`,
// `script` its first script (the bar's menu).
explorer_html :: proc(api: Explorer_Api, header, script: string) -> string {
	links := make(map[string]string, context.temp_allocator)
	for t in api.types { links[t.name] = fmt.tprintf("type.%s", t.name) }
	for n in api.nodes { links[n.type] = fmt.tprintf("node.%s", n.name) }
	if len(api.nodes) > 0 { links["Node"] = "nodes" }

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Plugin API · gui_toolkit</title>
<meta name="description" content="Every call a plugin's JavaScript can make and every node of a view, at level %d of the plugin API.">
<link rel="icon" href="/img/logo.png">
<link rel="stylesheet" href="/style.css">
<style>%s</style>
</head>
<body>
<!-- Made by tk site_build from plugin-api/api.json: edit src/plugin_api/api.odin, then run tk plugin_api. -->
<header class="bar">%s</header>

<main class="api">
<h1>Plugin API</h1>
<p class="lead">What a plugin's JavaScript imports from <code>"gt"</code>: the calls of each module and the nodes a view's render returns.</p>
<p class="api-actions"><a class="btn accent" href="/plugins/api/gt.d.ts" download="gt.d.ts">Download gt.d.ts</a> <a class="btn" href="/plugins/api/api.json">api.json</a> <a class="btn" href="/docs/gt-runtime/">Plugins and gt-runtime</a> <a class="btn" href="/docs/plugin-api/">Reference</a></p>
<div class="filter"><input type="search" id="api-search" placeholder="Search the calls and nodes (/)" aria-label="Search the calls and nodes" autocomplete="off"><span class="small" id="api-count">%d calls, %d nodes</span></div>
`, api.level, EXPLORER_CSS, home_links(header), len(api.calls), len(api.nodes))

	// the levels: what each added, the current one and the oldest accepted
	strings.write_string(&b, "\n<section id=\"levels\" class=\"api-levels\">\n<h2>Levels</h2>\n")
	fmt.sbprintf(&b, "<p>A manifest's <code>api</code> says the level its plugin was written for. This toolkit gives level %d and runs plugins of levels %d to %d. A level only adds.</p>\n<ol>\n", api.level, api.oldest, api.level)
	for l := api.level; l >= 1; l -= 1 {
		fmt.sbprintf(&b, "<li id=\"level.%d\"><strong>Level %d</strong>", l, l)
		if l == api.level { strings.write_string(&b, " <span class=\"pill now\">current</span>") }
		if l == api.oldest { strings.write_string(&b, " <span class=\"pill\">oldest</span>") }
		if l < api.oldest { strings.write_string(&b, " <span class=\"pill\">not run</span>") }
		added := make([dynamic]string, context.temp_allocator)
		for c in api.calls {
			if c.level == l { append(&added, fmt.tprintf("<a href=\"#%s.%s\"><code>%s.%s</code></a>", c.module, c.name, tk_site.esc(c.module), tk_site.esc(c.name))) }
		}
		for n in api.nodes {
			if n.level == l { append(&added, fmt.tprintf("<a href=\"#node.%s\"><code>%s</code></a>", n.name, tk_site.esc(n.name))) }
		}
		if len(added) > 0 { fmt.sbprintf(&b, " <span class=\"api-added\">%s</span>", strings.join(added[:], " ", context.temp_allocator)) }
		strings.write_string(&b, "</li>\n")
	}
	strings.write_string(&b, "</ol>\n</section>\n")

	// the modules and their calls
	strings.write_string(&b, "\n<section id=\"modules\">\n<h2>Modules</h2>\n")
	for m in api.modules {
		fmt.sbprintf(&b, "<div class=\"api-group\">\n<h3 id=\"module.%s\">%s</h3>\n", m, tk_site.esc(m))
		for c in api.calls {
			if c.module != m { continue }
			fmt.sbprintf(&b, "<article class=\"api-item\" id=\"%s.%s\">\n<h4><a href=\"#%s.%s\">%s.%s</a>", m, c.name, m, c.name, tk_site.esc(m), tk_site.esc(c.name))
			level_pill(&b, c.level)
			if c.capability != "None" { fmt.sbprintf(&b, " <span class=\"pill cap\">needs %s</span>", tk_site.esc(c.capability)) }
			fmt.sbprintf(&b, "</h4>\n<pre><code>%s</code></pre>\n", ts_html(explorer_call_signature(c), links))
			if c.doc != "" { fmt.sbprintf(&b, "<p>%s</p>\n", tk_site.esc(c.doc)) }
			fields_table(&b, "Argument", c.arguments, links)
			strings.write_string(&b, "</article>\n")
		}
		strings.write_string(&b, "</div>\n")
	}
	strings.write_string(&b, "</section>\n")

	// the nodes of a view
	if len(api.nodes) > 0 {
		strings.write_string(&b, "\n<section id=\"nodes\">\n<h2>View nodes</h2>\n<div class=\"api-group\">\n")
		strings.write_string(&b, "<p class=\"api-intro\">A render returns a tree of plain objects. Each has its <code>kind</code> and an optional <code>key</code>, unique in the view; a node without one is known by its place. In a container's <code>children</code>, <code>null</code>, <code>undefined</code> and <code>false</code> are skipped. A <span class=\"pill state\">state</span> field is kept by the host: what the person changed stays until the plugin has heard of it.</p>\n")
		for n in api.nodes {
			fmt.sbprintf(&b, "<article class=\"api-item\" id=\"node.%s\">\n<h4><a href=\"#node.%s\">%s</a>", n.name, n.name, tk_site.esc(n.name))
			level_pill(&b, n.level)
			if n.container { strings.write_string(&b, " <span class=\"pill\">container</span>") }
			fmt.sbprintf(&b, "</h4>\n<pre><code>%s</code></pre>\n", ts_html(node_signature(n), links))
			if n.doc != "" { fmt.sbprintf(&b, "<p>%s</p>\n", tk_site.esc(n.doc)) }
			fields_table(&b, "Field", n.fields, links)
			strings.write_string(&b, "</article>\n")
		}
		strings.write_string(&b, "</div>\n</section>\n")
	}

	// the types the calls and nodes name
	if len(api.types) > 0 {
		strings.write_string(&b, "\n<section id=\"types\">\n<h2>Types</h2>\n")
		for t in api.types {
			fmt.sbprintf(&b, "<article class=\"api-type\" id=\"type.%s\">\n<h4><a href=\"#type.%s\">%s</a></h4>\n", t.name, t.name, tk_site.esc(t.name))
			fmt.sbprintf(&b, "<pre><code>%s</code></pre>\n", ts_html(type_signature(t), links))
			if t.doc != "" { fmt.sbprintf(&b, "<p>%s</p>\n", tk_site.esc(t.doc)) }
			if !t.is_enum { fields_table(&b, "Field", t.fields, links) }
			strings.write_string(&b, "</article>\n")
		}
		strings.write_string(&b, "</section>\n")
	}

	fmt.sbprintf(&b, `</main>

<footer>
<p>gui_toolkit, MIT licence. This page is made from <a href="%s/blob/master/plugin-api/api.json">plugin-api/api.json</a> when the site is built.</p>
</footer>
<script>%s</script>
<script>%s</script>
</body>
</html>
`, GITHUB, script, EXPLORER_SCRIPT)
	return tk_site.relative_links(strings.to_string(b), EXPLORER_PAGE)
}

// Over site/style.css: its colours, faces, wells and plates.
@(private = "file")
EXPLORER_CSS :: `
.api { max-width: 960px; padding-bottom: 72px; }
.api [hidden] { display: none !important; }
.api h1 { font: 700 clamp(1.8rem, 5vw, 2.6rem) var(--mono); margin: 48px 0 8px; }
.api .lead { margin: 0 0 18px; max-width: none; font-size: 1rem; }
.api h2 { font: 700 1.35rem var(--mono); margin: 40px 0 12px; scroll-margin-top: 110px; }
.api h3 { font: 700 1.05rem var(--mono); color: var(--cyan); margin: 26px 0 10px; scroll-margin-top: 110px; }
.api-actions { display: flex; flex-wrap: wrap; gap: 10px; margin: 0 0 22px; }
.api-levels ol { list-style: none; margin: 0; padding: 0; }
.api-levels li { display: flex; flex-wrap: wrap; align-items: baseline; gap: 6px 8px; padding: 8px 0; border-top: 1px solid #000; box-shadow: inset 0 1px 0 var(--lip); scroll-margin-top: 110px; }
.api-levels li strong { font: 700 0.95rem var(--mono); min-width: 5.5em; }
.api-levels li:target strong { color: var(--accent); }
.api-added { display: flex; flex-wrap: wrap; gap: 4px 8px; flex-basis: 100%; }
.api-levels > p, .api-intro { color: var(--weak); font-size: 0.95rem; }
.api-item, .api-type {
  margin-bottom: 12px; padding: 14px 18px; border-radius: 10px; background: linear-gradient(var(--bg2), var(--bg1));
  border: 1px solid var(--edge); box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.05); scroll-margin-top: 110px;
}
.api-item:target, .api-type:target { border-color: var(--accent); box-shadow: 0 0 0 1px var(--accent), 0 0 12px rgba(111, 156, 240, 0.25); }
.api-item h4, .api-type h4 { display: flex; flex-wrap: wrap; align-items: baseline; gap: 8px; margin: 0 0 10px; font: 700 1rem var(--mono); }
.api-item h4 > a:first-child, .api-type h4 > a:first-child { color: var(--text); }
.pill { font: 0.74rem var(--mono); color: var(--weak); padding: 1px 8px; border-radius: 999px; background: var(--bg3); border: 1px solid var(--edge); white-space: nowrap; }
a.pill:hover { color: var(--text); text-decoration: none; }
.pill.now { color: var(--accent); }
.pill.cap { color: #e5c07b; }
.pill.state { color: var(--cyan); }
.api pre {
  margin: 0 0 10px; padding: 10px 12px; overflow-x: auto; border-radius: 8px; background: #080808; border: 1px solid #000;
  box-shadow: inset 0 3px 6px rgba(0, 0, 0, 0.85), 0 1px 0 var(--lip);
}
.api pre code { background: none; padding: 0; color: var(--text); font-size: 0.86rem; white-space: pre; overflow-wrap: normal; }
.api-item p, .api-type p { margin: 0 0 10px; color: var(--weak); font-size: 0.95rem; }
.api-table { overflow-x: auto; }
.api table { width: 100%; border-collapse: collapse; font-size: 0.9rem; }
.api th { text-align: left; padding: 4px 10px 4px 0; color: var(--faint); font: 600 0.74rem var(--mono); letter-spacing: 0.06em; text-transform: uppercase; }
.api td { padding: 6px 10px 6px 0; vertical-align: top; color: var(--weak); border-top: 1px solid #000; box-shadow: inset 0 1px 0 var(--lip); }
.api td:first-child { white-space: nowrap; }
`

// The search: each word typed must be in an entry's text; a module with no entry left is hidden. "/" goes to the box, and
// ?q= in the address fills it (an agent or a doc can link a search).
@(private = "file")
EXPLORER_SCRIPT :: `
  (() => {
    const input = document.getElementById('api-search'), count = document.getElementById('api-count');
    const items = [...document.querySelectorAll('.api-item')].map(el => ({ el, text: el.textContent.toLowerCase() }));
    const groups = [...document.querySelectorAll('.api-group')];
    const total = count.textContent;
    const apply = () => {
      const words = input.value.toLowerCase().split(/\s+/).filter(Boolean);
      let shown = 0;
      for (const it of items) { const on = words.every(w => it.text.includes(w)); it.el.hidden = !on; if (on) shown++; }
      for (const g of groups) g.hidden = !g.querySelector('.api-item:not([hidden])');
      count.textContent = words.length ? shown + ' of ' + items.length : total;
    };
    input.addEventListener('input', apply);
    document.addEventListener('keydown', e => {
      if (e.key === '/' && document.activeElement !== input && !e.ctrlKey && !e.metaKey) { e.preventDefault(); input.focus(); }
    });
    const q = new URLSearchParams(location.search).get('q');
    if (q) { input.value = q; apply(); }
  })();
`
