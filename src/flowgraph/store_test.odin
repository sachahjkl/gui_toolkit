package tk_flowgraph

import "core:strings"
import "core:testing"

@(private = "file")
entry_of :: proc(name: string, labels: []string, g: Graph) -> (e: Graph_Entry) {
	e.name = strings.clone(name)
	for l in labels { append(&e.labels, strings.clone(l)) }
	e.graph = g
	return
}

// What set_text writes, set_parse reads back the same: ids, names, labels, nodes (every type of parameter, a text that
// needs escaping, a position with a fraction), links.
@(test)
the_text_gives_back_the_graphs :: proc(t: ^testing.T) {
	cat := &SAMPLE
	set: Graph_Set
	defer set_destroy(&set)
	set_add(&set, entry_of("Screenshot é", {"region", "screen"}, sample_graph({.Capture, .Resize, .Save, .Reveal}, {{0, 1}, {1, 2}, {2, 3}})))
	set_add(&set, entry_of("Empty", {}, {}))
	g := &set.list[0].graph
	resize := graph_node(g, 2)
	resize.pos = {10.5, -20.25}
	percent, filter := param(cat, resize, "percent"), param(cat, resize, "filter")
	percent.number = 33.3
	filter.number = 2
	save := graph_node(g, 3)
	name, tint, open := param(cat, save, "name"), param(cat, save, "tint"), param(cat, save, "open")
	testing.expect_value(t, param(cat, save, "keys").text, "Ctrl+Alt+S")   // (a Hotkey's default, as a Text's)
	keys := param(cat, save, "keys")
	delete(keys.text)
	keys.text = strings.clone("Ctrl+Shift+Print")
	name.text = strings.clone("say \"hi\"\n\\ ok\x01")
	tint.color = {1, 2, 3, 4}
	open.number = 1
	editor := node_add(g, cat, int(Sample.Editor), {0, 300})
	_, linked := link(g, cat, {editor, 1, 3, 1})   // (an action link: done -> when)
	testing.expect(t, linked)

	text := set_text(&set, cat)
	defer delete(text)
	back, why := set_parse(text, cat)
	defer set_destroy(&back)
	testing.expect_value(t, why, "")
	testing.expect_value(t, len(back.list), len(set.list))
	testing.expect_value(t, back.next_id, set.next_id)
	for &a, i in set.list {
		b := &back.list[i]
		testing.expect_value(t, b.id, a.id)
		testing.expect_value(t, b.name, a.name)
		testing.expect_value(t, len(b.labels), len(a.labels))
		for l, j in a.labels { testing.expect_value(t, b.labels[j], l) }
		testing.expect_value(t, b.graph.next_id, a.graph.next_id)
		testing.expect_value(t, len(b.graph.nodes), len(a.graph.nodes))
		testing.expect_value(t, len(b.graph.links), len(a.graph.links))
		for na, j in a.graph.nodes {
			nb := b.graph.nodes[j]
			testing.expect_value(t, nb.id, na.id)
			testing.expect_value(t, nb.kind, na.kind)
			testing.expect_value(t, nb.pos, na.pos)
			for p, k in na.params {
				testing.expect_value(t, nb.params[k].number, p.number)
				testing.expect_value(t, nb.params[k].text, p.text)
				testing.expect_value(t, nb.params[k].color, p.color)
			}
		}
		for l, j in a.graph.links { testing.expect_value(t, b.graph.links[j], l) }
	}
}

// What the text gets wrong is dropped: an unknown kind, a link of kinds that disagree, a link to nothing, an unknown
// parameter; an id taken twice gets a new one; what is missing takes its default.
@(test)
what_the_text_gets_wrong_is_dropped :: proc(t: ^testing.T) {
	text := `{"version": 1, "graphs": [
		{"id": 4, "name": "A", "labels": ["region", 3], "nodes": [
			{"id": 1, "kind": "capture", "x": 0, "y": 0},
			{"id": 2, "kind": "teleport", "x": 0, "y": 0},
			{"id": 3, "kind": "save_file", "x": 0, "y": 0, "params": {"format": 1, "unknown": 3, "quality": "high"}},
			{"id": 3, "kind": "blur", "x": 0, "y": 0},
			{"id": 4, "kind": "read_qr", "x": 0, "y": 0}],
		 "links": [{"from": 1, "from_port": 0, "to": 3, "to_port": 0}, {"from": 3, "from_port": 0, "to": 4, "to_port": 0},
		           {"from": 1, "from_port": 0, "to": 2, "to_port": 0}]},
		{"id": 4, "name": "B", "nodes": [], "links": []}]}`
	set, why := set_parse(text, &SAMPLE)
	defer set_destroy(&set)
	testing.expect_value(t, why, "")
	testing.expect_value(t, len(set.list), 2)
	a, b := &set.list[0], &set.list[1]
	testing.expect_value(t, len(a.graph.nodes), 3)    // (the unknown kind and the second id 3 are dropped)
	testing.expect_value(t, len(a.graph.links), 1)    // (a file into a picture's port, a link to nothing)
	testing.expect_value(t, len(a.labels), 1)         // (a label that is no text)
	testing.expect(t, b.id != a.id)                   // (an id taken twice gets a new one)
	testing.expect_value(t, param_int(&SAMPLE, &a.graph.nodes[1], "format"), 1)
	testing.expect_value(t, param_int(&SAMPLE, &a.graph.nodes[1], "quality"), 90)   // (not a number: the default)
	testing.expect_value(t, a.graph.next_id, 4)
}

@(test)
a_broken_text_is_refused :: proc(t: ^testing.T) {
	cases := []string{"{not json", "[1, 2]", `{"version": 99, "graphs": []}`, `{"version": 1}`, `{"graphs": [3]}`}
	for text in cases {
		set, why := set_parse(text, &SAMPLE)
		testing.expectf(t, why != "", "%q is refused", text)
		set_destroy(&set)
	}
}

// A program keeps the names of its file: the list's key, the labels' key, its version.
@(test)
the_format_names_the_keys :: proc(t: ^testing.T) {
	format := Store_Format{version = 2, list = "workflows", labels = "triggers"}
	set: Graph_Set
	defer set_destroy(&set)
	set_add(&set, entry_of("Edit then share", {"edit"}, sample_graph({.Capture}, {})))
	text := set_text(&set, &SAMPLE, format)
	defer delete(text)
	testing.expect(t, strings.contains(text, `"workflows": [`))
	testing.expect(t, strings.contains(text, `"triggers": ["edit"]`))
	testing.expect(t, strings.contains(text, `"version": 2`))
	back, why := set_parse(text, &SAMPLE, format)
	defer set_destroy(&back)
	testing.expect_value(t, why, "")
	testing.expect_value(t, back.list[0].labels[0], "edit")
	_, newer := set_parse(text, &SAMPLE)   // (version 2 is newer than the default's 1)
	testing.expect(t, newer != "")
}
