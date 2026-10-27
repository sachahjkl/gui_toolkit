package platform

import "core:mem"

// Incremental updates, two ways:
//   a11y_diff        a program that rebuilds its whole tree each frame (an immediate-mode interface) hands it over;
//                    the diff keeps a hash of every node the adapter has and writes only the nodes new or changed.
//   a11y_diff_patch  a program that knows what changed (a document's mutations) hands over only those nodes, each
//                    complete; nothing else of the tree is made again.
// Nodes that went away need nothing: their parent changed (its children), and the adapter drops what no parent reaches
// any more; the diff forgets them too (a node put back later is sent whole).
A11y_Diff :: struct {
	sent: map[u64]u64,     // node -> hash of what the adapter has
	kids: map[u64][]u64,   // node -> its children as the adapter has them (to forget what a patch takes away)
	seen: map[u64]bool,    // scratch
	out:  A11y_Update,
	root: u64,             // the root of the last diff
	nodes_sent: int,       // in the last diff (tests, statistics)
}

a11y_diff_destroy :: proc(d: ^A11y_Diff) {
	delete(d.sent)
	for _, k in d.kids { delete(k) }
	delete(d.kids)
	delete(d.seen)
	a11y_update_destroy(&d.out)
	d^ = {}
}

// Forgets what the adapter has: the next diff sends the whole tree (after a refused update, or when the adapter asks).
a11y_diff_reset :: proc(d: ^A11y_Diff) {
	clear(&d.sent)
	for _, k in d.kids { delete(k) }
	clear(&d.kids)
}

// Whether the adapter has node `id` (as far as the diff knows).
a11y_diff_has :: proc(d: ^A11y_Diff, id: u64) -> bool { return id in d.sent }

@(private)
diff_keep_kids :: proc(d: ^A11y_Diff, id: u64, children: []u64) {
	if old, ok := d.kids[id]; ok {
		if len(old) == len(children) { copy(old, children); return }
		delete(old)
	}
	d.kids[id] = len(children) > 0 ? clone_ids(children) : nil
}

@(private)
clone_ids :: proc(ids: []u64) -> []u64 {
	c := make([]u64, len(ids))
	copy(c, ids)
	return c
}

@(private)
diff_forget :: proc(d: ^A11y_Diff, id: u64) {
	delete_key(&d.sent, id)
	if k, ok := d.kids[id]; ok {
		delete(k)
		delete_key(&d.kids, id)
	}
}

// Writes into d.out the nodes of `full` the adapter does not have as they are (all of them with `whole`, or when
// nothing was sent before); returns d.out, which may hold no node (nothing changed: no need to send it, but the focus
// may have moved: compare out.focus with the last one sent).
a11y_diff :: proc(d: ^A11y_Diff, full: ^A11y_Update, all := false) -> ^A11y_Update {
	a11y_update_clear(&d.out)
	whole := all || len(d.sent) == 0 || full.root != d.root   // (another root: a whole tree states it)
	if whole { a11y_diff_reset(d) }
	d.root = full.root
	d.out.root, d.out.focus, d.out.tree, d.out.tree_info = full.root, full.focus, full.tree, whole
	clear(&d.seen)
	d.nodes_sent = 0
	for i in 0 ..< len(full.nodes) {
		id := full.nodes[i].id
		h := a11y_node_hash(full, i)
		d.seen[id] = true
		if !whole {
			if old, ok := d.sent[id]; ok && old == h { continue }
		}
		d.sent[id] = h
		diff_keep_kids(d, id, a11y_node_children(full, i))
		a11y_copy_node(&d.out, full, i)
		d.nodes_sent += 1
	}
	if len(d.sent) > len(d.seen) {
		gone := make([dynamic]u64, 0, len(d.sent) - len(d.seen), context.temp_allocator)
		for id in d.sent { if id not_in d.seen { append(&gone, id) } }
		for id in gone { diff_forget(d, id) }
	}
	return &d.out
}

// Node by node: `changed` holds the nodes that are new or changed since the last update (each with all its properties
// and children; a node whose children changed is sent with its new list), its root and focus those of the tree. Writes
// into d.out those the adapter does not already have as they are; the children a node lost are forgotten with
// everything under them (unless `changed` puts them under another node). The first update of a tree is a whole one:
// without one before (or after a11y_diff_reset), the patch is sent as a whole tree and must then be the whole tree.
a11y_diff_patch :: proc(d: ^A11y_Diff, changed: ^A11y_Update) -> ^A11y_Update {
	a11y_update_clear(&d.out)
	whole := len(d.sent) == 0 || changed.root != d.root
	if whole { a11y_diff_reset(d) }
	d.root = changed.root
	d.out.root, d.out.focus, d.out.tree, d.out.tree_info = changed.root, changed.focus, changed.tree, whole
	d.nodes_sent = 0
	// the children every changed node has now: a child moved from one node to another is not forgotten
	clear(&d.seen)
	for i in 0 ..< len(changed.nodes) {
		for c in a11y_node_children(changed, i) { d.seen[c] = true }
	}
	lost := make([dynamic]u64, context.temp_allocator)
	for i in 0 ..< len(changed.nodes) {
		id := changed.nodes[i].id
		h := a11y_node_hash(changed, i)
		if old, ok := d.sent[id]; ok && old == h && !whole { continue }
		if old, ok := d.kids[id]; ok {
			for c in old { if c not_in d.seen { append(&lost, c) } }
		}
		d.sent[id] = h
		diff_keep_kids(d, id, a11y_node_children(changed, i))
		a11y_copy_node(&d.out, changed, i)
		d.nodes_sent += 1
	}
	// what no node reaches any more: the lost children and their subtrees
	for len(lost) > 0 {
		id := pop(&lost)
		if id == d.root || id not_in d.sent { continue }
		if k, ok := d.kids[id]; ok { append(&lost, ..k) }
		diff_forget(d, id)
	}
	return &d.out
}

// Copies node `i` of `src` (with its children and properties) at the end of `dst`.
a11y_copy_node :: proc(dst: ^A11y_Update, src: ^A11y_Update, i: int) {
	n := src.nodes[i]
	a11y_node(dst, n.id, A11y_Role(n.role), n.flags, n.actions)
	dst.nodes[len(dst.nodes) - 1].bounds = n.bounds
	a11y_children(dst, a11y_node_children(src, i))
	for p in a11y_node_props(src, i) {
		#partial switch prop_storage(p.kind) {
		case .Bytes:  a11y_bytes(dst, p.kind, src.bytes[p.a:][:p.len])
		case .Ids:    a11y_ids(dst, p.kind, src.ids[p.a:][:p.len])
		case .Floats: a11y_floats(dst, p.kind, src.floats[p.a:][:p.len])
		case:         a11y_prop(dst, p)
		}
	}
}

@(private)
Prop_Storage :: enum u8 { Inline, Bytes, Ids, Floats }

@(private)
prop_storage :: proc(k: A11y_Prop_Kind) -> Prop_Storage {
	#partial switch k {
	case .Label ..= .Column_Index_Text, .Character_Lengths, .Word_Starts, .Tree_Id: return .Bytes
	case .Controls ..= .Radio_Group, .Text_Selection: return .Ids
	case .Character_Positions, .Character_Widths, .Transform: return .Floats
	}
	return .Inline
}

// A hash of everything node `i` says (not where its data sits in the update).
a11y_node_hash :: proc(u: ^A11y_Update, i: int) -> u64 {
	h: u64 = 0xcbf29ce484222325
	mix :: proc(h: ^u64, b: []u8) { for c in b { h^ = (h^ ~ u64(c)) * 0x100000001b3 } }
	n := u.nodes[i]
	head := [4]u64{n.id, u64(n.role), u64(transmute(u32)n.flags), u64(transmute(u32)n.actions)}
	mix(&h, mem.slice_to_bytes(head[:]))
	b := n.bounds
	mix(&h, mem.slice_to_bytes(b[:]))
	mix(&h, mem.slice_to_bytes(a11y_node_children(u, i)))
	for p in a11y_node_props(u, i) {
		k := [2]u64{u64(p.kind), u64(p.len)}
		mix(&h, mem.slice_to_bytes(k[:]))
		switch prop_storage(p.kind) {
		case .Bytes:  mix(&h, u.bytes[p.a:][:p.len])
		case .Ids:    mix(&h, mem.slice_to_bytes(u.ids[p.a:][:p.len]))
		case .Floats: mix(&h, mem.slice_to_bytes(u.floats[p.a:][:p.len]))
		case .Inline:
			v := [2]u64{p.a, transmute(u64)p.f}
			mix(&h, mem.slice_to_bytes(v[:]))
		}
	}
	return h
}
