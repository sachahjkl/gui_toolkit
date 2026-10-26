package platform

import "core:mem"

// Incremental updates from whole trees: a program that rebuilds its whole tree each frame (an immediate-mode
// interface) hands it to a11y_diff, which keeps a hash of every node the adapter has and writes into `out` only the
// nodes that are new or changed. Nodes that went away need nothing: their parent changed (its children), and the
// adapter drops what no parent reaches any more.
A11y_Diff :: struct {
	sent: map[u64]u64,   // node -> hash of what the adapter has
	seen: map[u64]bool,  // scratch
	out:  A11y_Update,
	root: u64,           // the root of the last diff
	nodes_sent: int,     // in the last diff (tests, statistics)
}

a11y_diff_destroy :: proc(d: ^A11y_Diff) {
	delete(d.sent)
	delete(d.seen)
	a11y_update_destroy(&d.out)
	d^ = {}
}

// Forgets what the adapter has: the next diff sends the whole tree (after a refused update, or when the adapter asks).
a11y_diff_reset :: proc(d: ^A11y_Diff) { clear(&d.sent) }

// Writes into d.out the nodes of `full` the adapter does not have as they are (all of them with `whole`, or when
// nothing was sent before); returns d.out, which may hold no node (nothing changed: no need to send it, but the focus
// may have moved: compare out.focus with the last one sent).
a11y_diff :: proc(d: ^A11y_Diff, full: ^A11y_Update, all := false) -> ^A11y_Update {
	a11y_update_clear(&d.out)
	whole := all || len(d.sent) == 0 || full.root != d.root   // (another root: a whole tree states it)
	if whole { clear(&d.sent) }
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
		a11y_copy_node(&d.out, full, i)
		d.nodes_sent += 1
	}
	if len(d.sent) > len(d.seen) {
		gone := make([dynamic]u64, 0, len(d.sent) - len(d.seen), context.temp_allocator)
		for id in d.sent { if id not_in d.seen { append(&gone, id) } }
		for id in gone { delete_key(&d.sent, id) }
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
