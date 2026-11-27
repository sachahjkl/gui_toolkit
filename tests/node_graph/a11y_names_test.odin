package node_graph_test

// A program that frees its model in the same build as its graph (a node removed in answer to the graph's events): the
// accessibility tree, made at the end of the build, still names each node with what it was given.

import "core:strings"
import "core:testing"
import "gt:platform"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file") FREED_SIZE :: [2]int{700, 420}

@(private = "file")
Freed :: struct {
	view:     ui.Graph_View,
	selected: [dynamic]u64,
}

@(private = "file")
freed_build :: proc(s: ^session.Session) {
	f := (^Freed)(s.user)
	titles := [2]string{strings.clone("Capture"), strings.clone("Save")}
	subtitles := [2]string{strings.clone("every 5 s"), strings.clone("PNG to Pictures")}
	nodes := [2]ui.Graph_Node{
		{id = 1, title = titles[0], subtitle = subtitles[0], pos = {40, 60}},
		{id = 2, title = titles[1], subtitle = subtitles[1], pos = {360, 60}},
	}
	ui.node_graph("###graph", &f.view, nodes[:], nil, f.selected[:], {})
	// (overwritten, then freed: a node that kept the program's bytes reads garbage, or the sanitizer stops on it)
	for str in titles { overwrite(str); delete(str) }
	for str in subtitles { overwrite(str); delete(str) }
}

@(private = "file")
overwrite :: proc(str: string) {
	bytes := transmute([]u8)str
	for &c in bytes { c = '#' }
}

@(private = "file")
described :: proc(u: ^platform.A11y_Update, name: string) -> (description: string, found: bool) {
	for _, i in u.nodes {
		if platform.a11y_node_string(u, i, .Label) == name { return platform.a11y_node_string(u, i, .Description), true }
	}
	return "", false
}

@(test)
nodes_keep_their_names_when_the_model_is_freed_in_the_build :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	f: Freed
	defer delete(f.selected)
	s := session.start(t, {size = FREED_SIZE, user = &f, build = freed_build})
	ui.a11y_capture(s.state, true)
	session.frame(s)
	u := ui.a11y_tree(s.state)
	d, ok := described(u, "Capture")
	testing.expect(t, ok, "the first node is named by its title")
	testing.expect_value(t, d, "every 5 s")
	d, ok = described(u, "Save")
	testing.expect(t, ok, "the second node is named by its title")
	testing.expect_value(t, d, "PNG to Pictures")
}) }
