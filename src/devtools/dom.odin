package devtools

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "../platform"
import "../render"
import "../ui"
import "../ascii"

// The box tree as a DOM, for Chrome's DevTools: the Elements panel shows the boxes (a tag from what the box does, its name as
// its id, its text as a text node), Layout and Computed their rects and what they are drawn with, the Accessibility tab what
// a screen reader gets for the box, and hovering a node lights its box in the window. Styles and texts can be edited, boxes
// removed (dom_edit.odin); there is no markup to edit.
// A node is the box's key, under a number of ours (a key does not fit in a JavaScript number): 2n for the box, 2n + 1 for its
// text, 1 for the document. A build changes the tree: what the client has been sent is compared with it at each frame.
// One client at a time: the last to ask for the document or to edit gets the events, and the edits of the one before it go.

@(private)
DOM_DOCUMENT :: 1

// From this alpha on, a colour is written rgb(), not rgba().
@(private)
OPAQUE_ALPHA :: 0.999

@(private)
Dom :: struct {
	to:     Reply_To,                // who gets the events (conn nil: nobody has asked)
	lit:    ^Conn,                   // who highlighted a box, which goes with it (nil: no highlight of a client's)
	ids:    map[ui.Key]int,          // the key's number (2n)
	keys:   [dynamic]ui.Key,         // the number's key
	sent:   map[int][dynamic]int,    // the children the client knows of a node
	texts:  map[int]string,          // the text nodes it knows, as it knows them
	search: [dynamic]int,            // DOM.performSearch
	counts: map[int]int,             // what it was told of a node's children, those it has not asked for
	styles: map[int]Dom_Style,       // the styles it edited (dom_edit.odin)
	history: [dynamic]Dom_Edit,      // its edits, for DOM.undo and DOM.redo
	done:   int,                     // how many of them stand: those after are undone
	mark:   int,                     // the edits since the last DOM.markUndoableState share this
}

@(private)
dom_id :: proc(srv: ^Server, key: ui.Key) -> int {
	if id, ok := srv.dom.ids[key]; ok { return id }
	append(&srv.dom.keys, key)
	id := len(srv.dom.keys) * 2
	srv.dom.ids[key] = id
	return id
}

// The box of a node (of its text node too); nil if it is not in this build.
@(private)
dom_box :: proc(srv: ^Server, s: ^ui.State, id: int) -> ^ui.Box {
	k := id / 2 - 1
	if k < 0 || k >= len(srv.dom.keys) { return nil }
	b := s.boxes[srv.dom.keys[k]]
	return ui.box_current(s, b) ? b : nil
}

// The node a command is about: `nodeId` or `backendNodeId`, the same number here.
@(private)
dom_param :: proc(p: json.Object) -> int {
	if v, ok := p["nodeId"]; ok && num(v) != 0 { return int(num(v)) }
	return int(num(p["backendNodeId"]))
}

@(private)
dom_tag :: proc(s: ^ui.State, b: ^ui.Box) -> string {
	switch {
	case b == s.root:                                     return "html"
	case .Text_Input in b.flags:                          return "input"
	case .Clickable in b.flags:                           return "button"
	case b.flags & {.View_Scroll_X, .View_Scroll_Y} != {}: return "scroll"
	case b.first == nil && ui.box_text(b) != "":          return "text"
	}
	return "box"
}

// The children of a node as the client sees them: its text, then the boxes worth showing.
@(private)
dom_children :: proc(srv: ^Server, s: ^ui.State, id: int) -> [dynamic]int {
	out := make([dynamic]int, context.temp_allocator)
	if id == DOM_DOCUMENT {
		if s.root != nil { append(&out, dom_id(srv, s.root.key)) }
		return out
	}
	if id % 2 == 1 { return out }
	b := dom_box(srv, s, id)
	if b == nil { return out }
	if ui.box_text(b) != "" { append(&out, id + 1) }
	for c := b.first; c != nil; c = c.next { if worth(s, c) { append(&out, dom_id(srv, c.key)) } }
	return out
}

@(private)
dom_remember :: proc(srv: ^Server, id: int, kids: []int) {
	list, ok := &srv.dom.sent[id]
	if !ok {
		srv.dom.sent[id] = {}
		list = &srv.dom.sent[id]
	}
	clear(list)
	append(list, ..kids)
}

// A node of the protocol. depth: how far down its children go with it (-1: all); a box with only a text has it with it (what
// Elements shows on one line). remember: the client's tree holds what is written (DOM.describeNode's answer stays out of it).
@(private)
dom_write :: proc(sb: ^strings.Builder, srv: ^Server, s: ^ui.State, id, depth: int, remember := true) {
	if id == DOM_DOCUMENT {
		kids := dom_children(srv, s, id)
		fmt.sbprintf(sb, `{{"nodeId":1,"backendNodeId":1,"nodeType":9,"nodeName":"#document","localName":"","nodeValue":"","childNodeCount":%d,"documentURL":"toolkit://window","baseURL":"toolkit://window","xmlVersion":"","compatibilityMode":"NoQuirksMode"`, len(kids))
		if depth != 0 { dom_write_children(sb, srv, s, id, kids[:], depth, remember) }
		strings.write_string(sb, "}")
		return
	}
	b := dom_box(srv, s, id)
	if id % 2 == 1 {
		text := b != nil ? ui.box_text(b) : ""
		fmt.sbprintf(sb, `{{"nodeId":%d,"backendNodeId":%d,"parentId":%d,"nodeType":3,"nodeName":"#text","localName":"","nodeValue":%s}}`, id, id, id - 1, json_quote(text))
		if remember { dom_text_sent(srv, id, text) }
		return
	}
	if b == nil {
		fmt.sbprintf(sb, `{{"nodeId":%d,"backendNodeId":%d,"nodeType":1,"nodeName":"GONE","localName":"gone","nodeValue":"","childNodeCount":0,"attributes":[]}}`, id, id)
		return
	}
	tag := dom_tag(s, b)
	kids := dom_children(srv, s, id)
	fmt.sbprintf(sb, `{{"nodeId":%d,"backendNodeId":%d,"nodeType":1,"nodeName":%s,"localName":%s,"nodeValue":"","childNodeCount":%d,"attributes":[`, id, id,
		json_quote(ascii.upper(tag)), json_quote(tag), len(kids))
	dom_write_attrs(sb, b)
	strings.write_string(sb, "]")
	only_text := len(kids) == 1 && kids[0] == id + 1
	if depth != 0 || only_text { dom_write_children(sb, srv, s, id, kids[:], depth, remember) }
	if remember { srv.dom.counts[id] = len(kids) }
	strings.write_string(sb, "}")
}

// What a box says of itself, as attributes.
@(private)
dom_attrs :: proc(b: ^ui.Box) -> [dynamic][2]string {
	out := make([dynamic][2]string, context.temp_allocator)
	attr :: proc(out: ^[dynamic][2]string, name, value: string) { if value != "" { append(out, [2]string{name, value}) } }
	attr(&out, "id", b.name)
	if b.a11y != nil && b.a11y.role != .Unknown { attr(&out, "role", ax_role_name(b.a11y.role)) }
	if b.a11y != nil { attr(&out, ATTR_LABEL, b.a11y.name) }
	class := strings.builder_make(context.temp_allocator)
	for f in SHOWN_FLAGS {
		if f in b.flags { fmt.sbprintf(&class, "%s%v", strings.builder_len(class) > 0 ? " " : "", f) }
	}
	attr(&out, "class", strings.to_string(class))
	return out
}

@(private)
dom_write_attrs :: proc(sb: ^strings.Builder, b: ^ui.Box) {
	for kv, i in dom_attrs(b) { fmt.sbprintf(sb, `%s"%s",%s`, i > 0 ? "," : "", kv[0], json_quote(kv[1])) }
}

// DOM.requestChildNodes: the children of a node the client does not have. Those it has are not sent again: each node of an
// answer is a new object in Chrome's frontend, and the tree element it is unfolding would hold the old one, whose children
// never come. (Blink's PushChildNodesToFrontend does the same.)
@(private)
dom_push_children :: proc(srv: ^Server, s: ^ui.State, id, depth: int) {
	if srv.dom.to.conn == nil { return }
	if known, ok := srv.dom.sent[id]; ok {
		if depth == 1 { return }
		for k in known { if k % 2 == 0 { dom_push_children(srv, s, k, depth > 0 ? depth - 1 : depth) } }
		return
	}
	kids := dom_children(srv, s, id)
	dom_remember(srv, id, kids[:])
	dom_set_child_nodes(srv, s, id, kids[:], depth > 0 ? depth - 1 : depth)
}

// The children of a node, sent as an event; depth: how far down they go with it.
@(private)
dom_set_child_nodes :: proc(srv: ^Server, s: ^ui.State, id: int, kids: []int, depth: int) {
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, `{{"parentId":%d,"nodes":[`, id)
	for k, i in kids {
		if i > 0 { strings.write_byte(&sb, ',') }
		dom_write(&sb, srv, s, k, depth)
	}
	strings.write_string(&sb, "]}")
	event(srv.dom.to.conn, srv.dom.to.session, "DOM.setChildNodes", strings.to_string(sb))
}

@(private)
dom_write_children :: proc(sb: ^strings.Builder, srv: ^Server, s: ^ui.State, id: int, kids: []int, depth: int, remember := true) {
	if remember { dom_remember(srv, id, kids) }
	strings.write_string(sb, `,"children":[`)
	for k, i in kids {
		if i > 0 { strings.write_byte(sb, ',') }
		dom_write(sb, srv, s, k, depth > 0 ? depth - 1 : depth, remember)
	}
	strings.write_string(sb, "]")
}

@(private)
dom_text_sent :: proc(srv: ^Server, id: int, text: string) {
	if old, ok := srv.dom.texts[id]; ok { delete(old) }
	srv.dom.texts[id] = strings.clone(text)
}

// The client no longer knows this node, nor what is under it.
@(private)
dom_forget :: proc(srv: ^Server, id: int) {
	if t, ok := srv.dom.texts[id]; ok { delete(t); delete_key(&srv.dom.texts, id) }
	delete_key(&srv.dom.counts, id)
	list, ok := srv.dom.sent[id]
	if !ok { return }
	for k in list { dom_forget(srv, k) }
	delete(list)
	delete_key(&srv.dom.sent, id)
}

@(private)
dom_reset :: proc(srv: ^Server, s: ^ui.State, gone := false) {
	if gone {   // (its edits go with it: the window is as its program builds it again)
		for _, st in srv.dom.styles { delete(st.text); delete(st.base) }
		clear(&srv.dom.styles)
		dom_history_clear(&srv.dom)
		if s != nil { ui.box_edits_clear(s) }
	}
	for _, list in srv.dom.sent { delete(list) }
	clear(&srv.dom.sent)
	clear(&srv.dom.counts)
	for _, t in srv.dom.texts { delete(t) }
	clear(&srv.dom.texts)
	clear(&srv.dom.search)
	if srv.dom.to.conn != nil { release(srv.dom.to) }
	srv.dom.to = {}
	srv.dom.lit = nil
	if s != nil { ui.set_inspected(s, 0) }
}

@(private)
dom_destroy :: proc(srv: ^Server) {
	dom_reset(srv, nil, gone = true)
	delete(srv.dom.styles)
	delete(srv.dom.history)
	delete(srv.dom.counts)
	delete(srv.dom.ids)
	delete(srv.dom.keys)
	delete(srv.dom.sent)
	delete(srv.dom.texts)
	delete(srv.dom.search)
}

// What changed in this build, for the nodes the client knows. Each frame, while a client looks at the tree.
@(private)
dom_sync :: proc(srv: ^Server, s: ^ui.State) {
	if srv.dom.lit != nil && conn_gone(srv.dom.lit) {
		srv.dom.lit = nil
		ui.set_inspected(s, 0)
	}
	to := srv.dom.to
	if to.conn == nil { return }
	if conn_gone(to.conn) { dom_reset(srv, s, gone = true); return }
	if s.root == nil || !ui.box_current(s, s.root) { return }
	dom_sync_node(srv, s, DOM_DOCUMENT)
}

@(private)
dom_sync_node :: proc(srv: ^Server, s: ^ui.State, id: int) {
	old, known := srv.dom.sent[id]
	to := srv.dom.to
	kids := dom_children(srv, s, id)
	if !known {
		// (it has not asked for them: it still says whether there is something to unfold)
		if n, told := srv.dom.counts[id]; told && n != len(kids) {
			srv.dom.counts[id] = len(kids)
			event(to.conn, to.session, "DOM.childNodeCountUpdated", fmt.tprintf(`{{"nodeId":%d,"childNodeCount":%d}}`, id, len(kids)))
		}
		return
	}
	same := len(old) == len(kids)
	if same { for k, i in kids { if old[i] != k { same = false; break } } }
	if !same {
		contains :: proc(list: []int, x: int) -> bool { for v in list { if v == x { return true } }; return false }
		// what stays must be in the same order, else it goes and comes back
		kept := make([dynamic]int, context.temp_allocator)
		for k in old { if contains(kids[:], k) { append(&kept, k) } }
		w := 0
		ordered := true
		for k in kids { if contains(old[:], k) { if kept[w] != k { ordered = false; break }; w += 1 } }
		if !ordered { clear(&kept) }
		for k in old {
			if contains(kept[:], k) { continue }
			event(to.conn, to.session, "DOM.childNodeRemoved", fmt.tprintf(`{{"parentNodeId":%d,"nodeId":%d}}`, id, k))
			dom_forget(srv, k)
		}
		prev := 0
		for k in kids {
			if !contains(kept[:], k) {
				sb := strings.builder_make(context.temp_allocator)
				dom_write(&sb, srv, s, k, 0)
				event(to.conn, to.session, "DOM.childNodeInserted", fmt.tprintf(`{{"parentNodeId":%d,"previousNodeId":%d,"node":%s}}`, id, prev, strings.to_string(sb)))
			}
			prev = k
		}
		dom_remember(srv, id, kids[:])
	}
	for k in kids {
		if k % 2 == 1 {
			b := dom_box(srv, s, k)
			if t, ok := srv.dom.texts[k]; ok && b != nil && t != ui.box_text(b) {
				event(to.conn, to.session, "DOM.characterDataModified", fmt.tprintf(`{{"nodeId":%d,"characterData":%s}}`, k, json_quote(ui.box_text(b))))
				dom_text_sent(srv, k, ui.box_text(b))
			}
		} else {
			dom_sync_node(srv, s, k)
		}
	}
}

// The client gets to know the node (what a pick or a search gives it must be in its tree): its parents' children, from the top.
@(private)
dom_push :: proc(srv: ^Server, s: ^ui.State, id: int) {
	if srv.dom.to.conn == nil { return }
	b := dom_box(srv, s, id)
	if b == nil { return }
	chain := make([dynamic]int, context.temp_allocator)
	for p := b.parent; p != nil; p = p.parent { append(&chain, dom_id(srv, p.key)) }
	#reverse for pid in chain {
		if pid in srv.dom.sent { continue }
		kids := dom_children(srv, s, pid)
		dom_remember(srv, pid, kids[:])
		dom_set_child_nodes(srv, s, pid, kids[:], 0)
	}
}

// The deepest box worth showing at a point of the window (the last one built is on top).
@(private)
dom_at :: proc(s: ^ui.State, b: ^ui.Box, p: [2]f32) -> ^ui.Box {
	if b == nil || !ui.box_current(s, b) { return nil }
	inside := p.x >= b.rect.min.x && p.x < b.rect.max.x && p.y >= b.rect.min.y && p.y < b.rect.max.y
	if !inside { return nil }
	for c := b.last; c != nil; c = c.prev {
		if r := dom_at(s, c, p); r != nil { return r }
	}
	return worth(s, b) ? b : nil
}

@(private)
dom_search :: proc(srv: ^Server, s: ^ui.State, b: ^ui.Box, query: string) {
	if !ui.box_current(s, b) || !worth(s, b) { return }
	has :: proc(text, query: string) -> bool { return text != "" && strings.contains(strings.to_lower(text, context.temp_allocator), query) }
	if has(b.name, query) || has(ui.box_text(b), query) || dom_tag(s, b) == query { append(&srv.dom.search, dom_id(srv, b.key)) }
	for c := b.first; c != nil; c = c.next { dom_search(srv, s, c, query) }
}

@(private)
dom_px :: proc(v: f32) -> string { return fmt.tprintf("%.1fpx", v) }

// What a box is drawn with, as CSS's words, as it looks on the screen: sRGB (a box holds linear light). What can be edited.
@(private)
dom_style_editable :: proc(srv: ^Server, b: ^ui.Box) -> [dynamic][2]string {
	out := make([dynamic][2]string, context.temp_allocator)
	d := f32(dpi(srv))
	px := dom_px
	color :: proc(c: ui.Color) -> string {
		ch :: proc(v: f32) -> int { return int(render.linear_to_srgb(v) * 255 + 0.5) }
		if c.a >= OPAQUE_ALPHA { return fmt.tprintf("rgb(%d, %d, %d)", ch(c.r), ch(c.g), ch(c.b)) }
		return fmt.tprintf("rgba(%d, %d, %d, %.2f)", ch(c.r), ch(c.g), ch(c.b), c.a)
	}
	if .Draw_Background in b.flags { append(&out, [2]string{"background-color", color(b.bg)}) }
	if .Draw_Border in b.flags { append(&out, [2]string{"border-color", color(b.border)}) }
	if ui.box_text(b) != "" { append(&out, [2]string{"color", color(b.text_color)}) }
	if b.transparency != 0 { append(&out, [2]string{"opacity", fmt.tprintf("%.2f", 1 - b.transparency)}) }
	append(&out, [2]string{"width", px((b.rect.max.x - b.rect.min.x) / d)})
	append(&out, [2]string{"height", px((b.rect.max.y - b.rect.min.y) / d)})
	if ui.box_text(b) != "" {
		append(&out, [2]string{"font-size", px(b.font_size / d)})
		append(&out, [2]string{"padding", px(b.text_pad / d)})
	}
	if b.radius > 0 { append(&out, [2]string{"border-radius", px(b.radius / d)}) }
	return out
}

// What it gets from the layout: read only.
@(private)
dom_style_fixed :: proc(srv: ^Server, b: ^ui.Box) -> [dynamic][2]string {
	out := make([dynamic][2]string, context.temp_allocator)
	d := f32(dpi(srv))
	px := dom_px
	append(&out, [2]string{"display", "flex"})
	append(&out, [2]string{"flex-direction", b.layout_axis == .X ? "row" : "column"})
	append(&out, [2]string{"left", px(b.rect.min.x / d)})
	append(&out, [2]string{"top", px(b.rect.min.y / d)})
	if b.flags & {.View_Scroll_X, .View_Scroll_Y} != {} {
		append(&out, [2]string{"overflow", "scroll"})
		append(&out, [2]string{"scroll-top", px(b.view_off.y / d)})
		append(&out, [2]string{"scroll-height", px(b.view_bounds.y / d)})
	}
	append(&out, [2]string{"cursor", fmt.tprintf("%v", b.cursor)})
	return out
}

@(private)
dom_write_props :: proc(sb: ^strings.Builder, props: [dynamic][2]string) {
	for kv, i in props {
		if i > 0 { strings.write_byte(sb, ',') }
		fmt.sbprintf(sb, `{{"name":"%s","value":%s}}`, kv[0], json_quote(kv[1]))
	}
}

// An accessible node for a box, its parents and children (the Accessibility tab); a box that is no node says so.
@(private)
dom_ax_partial :: proc(sb: ^strings.Builder, srv: ^Server, s: ^ui.State, id: int, relatives: bool) {
	u := ui.a11y_tree(s)
	b := dom_box(srv, s, id)
	i := b != nil ? ui.a11y_find(s, b.key) : -1
	if i < 0 {
		fmt.sbprintf(sb, `{{"nodes":[{{"nodeId":"box%d","ignored":true,"ignoredReasons":[{{"name":"uninteresting","value":{{"type":"boolean","value":true}}}}],"role":{{"type":"role","value":"none"}},"backendDOMNodeId":%d,"childIds":[]}}]}}`, id, id)
		return
	}
	only := make([dynamic]int, context.temp_allocator)
	append(&only, i)
	if relatives {
		parent := ax_parents(u)
		at := u.nodes[i].id
		for {
			up, ok := parent[at]
			if !ok { break }
			found := false
			for n, k in u.nodes { if n.id == up { append(&only, k); found = true; break } }
			if !found { break }
			at = up
		}
		for c in platform.a11y_node_children(u, i) {
			for n, k in u.nodes { if n.id == c { append(&only, k); break } }
		}
	}
	ax_write_nodes(sb, srv, u, only[:], false)
}

// The node of an accessible node's id, as the protocol writes it.
@(private)
dom_ax_index :: proc(u: ^platform.A11y_Update, hex_id: string) -> int {
	for n, i in u.nodes { if fmt.tprintf("%x", n.id) == hex_id { return i } }
	return -1
}

// A box's rect as the protocol's quad, in CSS pixels.
@(private)
dom_quad :: proc(b: ^ui.Box, d: f64) -> string {
	x0, y0, x1, y1 := f64(b.rect.min.x) / d, f64(b.rect.min.y) / d, f64(b.rect.max.x) / d, f64(b.rect.max.y) / d
	return fmt.tprintf("[%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f]", x0, y0, x1, y0, x1, y1, x0, y1)
}

// This client takes the tree over: it gets the events from now on, and when it goes its edits go with it. Those of a client
// before it go now.
@(private)
dom_take :: proc(srv: ^Server, s: ^ui.State, to: Reply_To) {
	dom_reset(srv, s, gone = srv.dom.to.conn != nil && srv.dom.to.conn != to.conn)
	srv.dom.to = hold(to)
}

// The commands of DOM.
@(private)
cmd_dom :: proc(c: ^Cmd) -> Answer {
	srv, s, to, p := c.srv, c.s, c.to, c.p
	sb := &c.sb
	d := dpi(srv)
	// (what tells the tree's client something, or moves its edits: DOM.getDocument takes the tree over, an edit too)
	switch c.method {
	case "DOM.requestChildNodes", "DOM.pushNodesByBackendIdsToFrontend", "DOM.getNodeForLocation", "DOM.performSearch", "DOM.getSearchResults",
	     "DOM.discardSearchResults", "DOM.markUndoableState", "DOM.undo", "DOM.redo":
		if srv.dom.to.conn != nil && srv.dom.to.conn != to.conn {
			error_reply(to, CDP_ERROR_SERVER, "another client has the tree: DOM.getDocument takes it over")
			return .Sent
		}
	}
	switch c.method {
	case "DOM.getDocument":
		dom_take(srv, s, to)
		strings.write_string(sb, `{"root":`)
		dom_write(sb, srv, s, DOM_DOCUMENT, int(num(p["depth"], 1)))
		strings.write_string(sb, "}")
	case "DOM.requestChildNodes":
		// (the event before the answer: on the answer the client reads the children it has)
		dom_push_children(srv, s, dom_param(p), int(num(p["depth"], 1)))
		strings.write_string(sb, "{}")
	case "DOM.describeNode":
		strings.write_string(sb, `{"node":`)
		dom_write(sb, srv, s, dom_param(p), int(num(p["depth"], 0)), remember = false)
		strings.write_string(sb, "}")
	case "DOM.pushNodesByBackendIdsToFrontend":
		ids, _ := p["backendNodeIds"].(json.Array)
		strings.write_string(sb, `{"nodeIds":[`)
		for v, i in ids {
			dom_push(srv, s, int(num(v)))
			fmt.sbprintf(sb, "%s%d", i > 0 ? "," : "", int(num(v)))
		}
		strings.write_string(sb, "]}")
	case "DOM.getNodeForLocation":
		f := f32(d)
		b := dom_at(s, s.root, {f32(num(p["x"])) * f, f32(num(p["y"])) * f})
		if b == nil { error_reply(to, CDP_ERROR_SERVER, "no box at this point"); return .Sent }
		id := dom_id(srv, b.key)
		dom_push(srv, s, id)
		fmt.sbprintf(sb, `{{"backendNodeId":%d,"nodeId":%d,"frameId":"%s"}}`, id, id, srv.id)
	case "DOM.getBoxModel":
		b := dom_box(srv, s, dom_param(p))
		if b == nil { error_reply(to, CDP_ERROR_SERVER, "this box is not in the window any more"); return .Sent }
		q := dom_quad(b, d)
		fmt.sbprintf(sb, `{{"model":{{"content":%s,"padding":%s,"border":%s,"margin":%s,"width":%.0f,"height":%.0f}}}}`, q, q, q, q, f64(b.rect.max.x) / d - f64(b.rect.min.x) / d, f64(b.rect.max.y) / d - f64(b.rect.min.y) / d)
	case "DOM.getContentQuads":
		b := dom_box(srv, s, dom_param(p))
		if b == nil { error_reply(to, CDP_ERROR_SERVER, "this box is not in the window any more"); return .Sent }
		fmt.sbprintf(sb, `{{"quads":[%s]}}`, dom_quad(b, d))
	case "DOM.performSearch":
		clear(&srv.dom.search)
		if s.root != nil { dom_search(srv, s, s.root, strings.to_lower(str(p["query"]), context.temp_allocator)) }
		fmt.sbprintf(sb, `{{"searchId":"1","resultCount":%d}}`, len(srv.dom.search))
	case "DOM.getSearchResults":
		lo, hi := clamp(int(num(p["fromIndex"])), 0, len(srv.dom.search)), clamp(int(num(p["toIndex"])), 0, len(srv.dom.search))
		strings.write_string(sb, `{"nodeIds":[`)
		for id, i in srv.dom.search[lo:max(lo, hi)] {
			dom_push(srv, s, id)
			fmt.sbprintf(sb, "%s%d", i > 0 ? "," : "", id)
		}
		strings.write_string(sb, "]}")
	case "DOM.discardSearchResults":
		clear(&srv.dom.search)
		strings.write_string(sb, "{}")
	case "DOM.hideHighlight":
		ui.set_inspected(s, 0)
		srv.dom.lit = nil
		strings.write_string(sb, "{}")
	case "DOM.setNodeValue":
		id := dom_param(p)
		b := dom_box(srv, s, id)
		if b == nil || id % 2 == 0 { error_reply(to, CDP_ERROR_SERVER, "not the text of a box in the window"); return .Sent }
		if srv.dom.to.conn != to.conn { dom_take(srv, s, to) }
		dom_text_edit(srv, s, id, b.key, str(p["value"]))
		strings.write_string(sb, "{}")
	case "DOM.removeNode":
		b := dom_box(srv, s, dom_param(p))
		if b == nil || b == s.root || dom_param(p) % 2 == 1 { error_reply(to, CDP_ERROR_SERVER, "this node cannot be removed"); return .Sent }
		if srv.dom.to.conn != to.conn { dom_take(srv, s, to) }
		dom_remove_edit(srv, s, dom_param(p), b.key)
		strings.write_string(sb, "{}")
	case "DOM.getAttributes":
		strings.write_string(sb, `{"attributes":[`)
		if b := dom_box(srv, s, dom_param(p)); b != nil && dom_param(p) % 2 == 0 { dom_write_attrs(sb, b) }
		strings.write_string(sb, "]}")
	case "DOM.setAttributeValue":
		if e := dom_attr_edit(srv, s, to, dom_param(p), [][2]string{{str(p["name"]), str(p["value"])}}, ""); e != "" { error_reply(to, CDP_ERROR_SERVER, e); return .Sent }
		strings.write_string(sb, "{}")
	case "DOM.setAttributesAsText":
		if e := dom_attr_edit(srv, s, to, dom_param(p), attrs_parse(str(p["text"]))[:], str(p["name"])); e != "" { error_reply(to, CDP_ERROR_SERVER, e); return .Sent }
		strings.write_string(sb, "{}")
	case "DOM.removeAttribute":
		if e := dom_attr_edit(srv, s, to, dom_param(p), nil, str(p["name"])); e != "" { error_reply(to, CDP_ERROR_SERVER, e); return .Sent }
		strings.write_string(sb, "{}")
	case "DOM.markUndoableState":
		srv.dom.mark += 1
		strings.write_string(sb, "{}")
	case "DOM.undo":
		dom_undo(srv, s)
		strings.write_string(sb, "{}")
	case "DOM.redo":
		dom_redo(srv, s)
		strings.write_string(sb, "{}")
	case "DOM.getNodesForSubtreeByStyle":   // (the Layout tab's overlays of grids and flexboxes: there is no overlay to draw them)
		strings.write_string(sb, `{"nodeIds":[]}`)
	case "DOM.resolveNode":
		b := dom_box(srv, s, dom_param(p))
		tag := b != nil ? dom_tag(s, b) : "box"
		fmt.sbprintf(sb, `{{"object":{{"type":"object","subtype":"node","className":"%s","description":"%s","objectId":"node:%d"}}}}`, tag, tag, dom_param(p))
	case:
		return .Unknown
	}
	return .Reply
}

// The commands of CSS.
@(private)
cmd_css :: proc(c: ^Cmd) -> Answer {
	srv, s, to, p := c.srv, c.s, c.to, c.p
	sb := &c.sb
	switch c.method {
	case "CSS.getComputedStyleForNode":
		b := dom_box(srv, s, dom_param(p))
		strings.write_string(sb, `{"computedStyle":[`)
		if b != nil {
			dom_write_props(sb, dom_style_editable(srv, b))
			strings.write_byte(sb, ',')
			dom_write_props(sb, dom_style_fixed(srv, b))
		}
		strings.write_string(sb, "]}")
	case "CSS.setStyleTexts":
		edits, _ := p["edits"].(json.Array)
		style_id :: proc(v: json.Value) -> int {
			edit, _ := v.(json.Object)
			id, _ := strconv.parse_int(strings.trim_prefix(str(edit["styleSheetId"]), "toolkit-"))
			return id
		}
		// (all or none: an error says nothing was done)
		for v in edits {
			if dom_box(srv, s, style_id(v)) == nil { error_reply(to, CDP_ERROR_SERVER, "this box is not in the window any more"); return .Sent }
		}
		strings.write_string(sb, `{"styles":[`)
		for v, i in edits {
			edit, _ := v.(json.Object)
			id := style_id(v)
			b := dom_box(srv, s, id)
			if srv.dom.to.conn != to.conn { dom_take(srv, s, to) }
			dom_style_set(srv, s, id, b, str(edit["text"]))
			if i > 0 { strings.write_byte(sb, ',') }
			css_write_style(sb, id, str(edit["text"]))
		}
		strings.write_string(sb, "]}")
	case "CSS.getMatchedStylesForNode", "CSS.getInlineStylesForNode":
		id := dom_param(p)
		b := dom_box(srv, s, id)
		strings.write_string(sb, `{"attributesStyle":{"cssProperties":[`)
		if b != nil { dom_write_props(sb, dom_style_fixed(srv, b)) }
		strings.write_string(sb, `],"shorthandEntries":[]},"inlineStyle":`)
		css_write_style(sb, id, b != nil ? dom_style_text(srv, id, b) : "")
		strings.write_string(sb, `,"matchedCSSRules":[],"inherited":[],"inheritedPseudoElements":[],"pseudoElements":[],"cssKeyframesRules":[],"cssPositionTryRules":[],"cssPropertyRules":[],"cssPropertyRegistrations":[],"cssFunctionRules":[],"cssAtRules":[]}`)
	case "CSS.getEnvironmentVariables", "CSS.trackComputedStyleUpdates", "CSS.trackComputedStyleUpdatesForNode":
		strings.write_string(sb, "{}")
	case "CSS.takeComputedStyleUpdates":   // (the frontend asks again, at its own pace: the Styles panel is refreshed by the tree's events)
		strings.write_string(sb, `{"nodeIds":[]}`)
	case "CSS.getPlatformFontsForNode":
		strings.write_string(sb, `{"fonts":[]}`)
	case "CSS.getBackgroundColors":
		strings.write_string(sb, `{"backgroundColors":[]}`)
	case "CSS.getAnimatedStylesForNode":
		strings.write_string(sb, `{"animationStyles":[]}`)
	case:
		return .Unknown
	}
	return .Reply
}

// The commands of Overlay.
@(private)
cmd_overlay :: proc(c: ^Cmd) -> Answer {
	switch c.method {
	case "Overlay.highlightNode":
		b := dom_box(c.srv, c.s, dom_param(c.p))
		ui.set_inspected(c.s, b != nil ? b.key : 0)
		c.srv.dom.lit = b != nil ? c.to.conn : nil
	case "Overlay.hideHighlight":
		ui.set_inspected(c.s, 0)
		c.srv.dom.lit = nil
	case:
		return .Unknown
	}
	strings.write_string(&c.sb, "{}")
	return .Reply
}

// The commands of Accessibility: the Accessibility tab, and tools.
@(private)
cmd_accessibility :: proc(c: ^Cmd) -> Answer {
	srv, s, p := c.srv, c.s, c.p
	sb := &c.sb
	switch c.method {
	case "Accessibility.getFullAXTree":
		ax_write_nodes(sb, srv, ui.a11y_tree(s), nil, true)
	case "Accessibility.queryAXTree":
		ax_write_nodes(sb, srv, ui.a11y_tree(s), ax_matches(ui.a11y_tree(s), p)[:], false)
	case "Accessibility.getPartialAXTree":
		dom_ax_partial(sb, srv, s, dom_param(p), p["fetchRelatives"] == nil || bool_of(p["fetchRelatives"]))
	case "Accessibility.getAXNodeAndAncestors":
		dom_ax_partial(sb, srv, s, dom_param(p), true)
	case "Accessibility.getRootAXNode":
		u := ui.a11y_tree(s)
		parent := ax_parents(u)
		strings.write_string(sb, `{"node":`)
		wrote := false
		for n, i in u.nodes {
			if n.id not_in parent { ax_write_node(sb, srv, u, i, parent); wrote = true; break }
		}
		if !wrote { strings.write_string(sb, "null") }
		strings.write_string(sb, "}")
	case "Accessibility.getChildAXNodes":
		u := ui.a11y_tree(s)
		only := make([dynamic]int, context.temp_allocator)
		if i := dom_ax_index(u, str(p["id"])); i >= 0 {
			for k in platform.a11y_node_children(u, i) {
				for n, x in u.nodes { if n.id == k { append(&only, x); break } }
			}
		}
		ax_write_nodes(sb, srv, u, only[:], false)
	case:
		return .Unknown
	}
	return .Reply
}
