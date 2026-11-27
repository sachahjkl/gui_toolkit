// Rich views (plugins.md, "As built: rich views", API level 6): an icon by its name drawn as a box of its glyph, an
// unknown one drawn as nothing and said once in the log, a highlight drawn as runs of the find bar's colours, a badge,
// a tone's colour. Through the plugin's process, as any view.
package plugins_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import lucide "gt:lucide"
import "gt:testkit"
import "gt:testkit/session"
import "gt:ui"

RICH_MANIFEST :: `{
	"id": "rich", "name": "Rich", "api": 6, "main": "main.js",
	"views": [{"id": "main", "title": "Rich", "place": "internal"}]
}`

// `again` renders the view again: the unknown icon must not be said a second time.
RICH_MAIN :: `import { views } from "gt";
let n = 0;
export function activate() {
	views.register("main", () => ({ kind: "column", children: [
		{ kind: "heading", key: "title", text: "Logs", icon: "scroll-text" },
		{ kind: "text", key: "ghost", text: "No icon " + n, icon: "no-such-icon" },
		{ kind: "text", key: "msg", text: "an Error, then another error", highlight: "error", mono: true },
		{ kind: "text", key: "bad", text: "It failed", tone: "bad" },
		{ kind: "badge", key: "level", text: "WARN", tone: "warn", icon: "alert-triangle" },
		{ kind: "field", key: "query", placeholder: "Find", icon: "search" },
		{ kind: "button", key: "again", label: "Again", icon: "refresh-cw", look: "ghost", size: "small", onClick: () => { n += 1; } },
	] }));
}
`

@(private = "file")
open_rich :: proc(t: ^testing.T) -> (s: ^session.Session, fx: ^Fx, root: string) {
	root = testkit.temp_folder(t, "plugin-rich")
	write_plugin(root, "rich", RICH_MANIFEST, RICH_MAIN)
	enable(root, "rich")
	fx = new(Fx)   // (freed by open's cleanup)
	s = open(t, fx, root)
	wait_started(s, fx, "rich")
	fx.open_view = {"rich", "main"}
	session.wait_text(s, "It failed", WAIT)
	// (the view's window takes its content's height as it comes: a click before it settles can miss its node)
	session.wait_idle(s, WAIT)
	return
}

@(test)
an_icon_by_name_is_a_box_of_its_glyph :: proc(t: ^testing.T) {
	s, _, _ := open_rich(t)
	row := session.get(s, "pv_icon_row:title")
	icon := session.get(s, "pv_icon", within = row)
	testing.expect_value(t, ui.box_text(icon), lucide.SCROLL_TEXT)
	// the field's glyph, inside its well, and the button's
	well := session.get(s, "pv:query_well")
	testing.expect_value(t, ui.box_text(session.get(s, "pv_icon", within = well)), lucide.SEARCH)
	testing.expect(t, session.find(s, "pv:again") != nil, "the button with an icon")
}

@(test)
an_unknown_icon_draws_nothing_and_is_said_once :: proc(t: ^testing.T) {
	s, _, root := open_rich(t)
	testing.expect(t, session.find(s, "pv_icon_row:ghost") == nil, "an unknown icon has a row of its own")
	testing.expect(t, session.find_text(s, "No icon 0") != nil, "its text is not shown")
	session.click(s, "pv:again")
	session.wait_text(s, "No icon 1", WAIT)
	session.wait_until(s, root, proc(s: ^session.Session, root: string) -> bool {
		data, err := os.read_entire_file(fmt.tprintf("%s/state/rich.log", root), context.temp_allocator)
		return err == nil && strings.contains(string(data), `no icon is named "no-such-icon"`)
	}, "the log of the unknown icon", WAIT)
	data, _ := os.read_entire_file(fmt.tprintf("%s/state/rich.log", root), context.temp_allocator)
	testing.expect_value(t, strings.count(string(data), `no icon is named "no-such-icon"`), 1)
}

@(test)
a_highlight_is_a_run_in_the_find_bars_colours :: proc(t: ^testing.T) {
	s, _, _ := open_rich(t)
	b := session.get(s, "pv:msg")
	runs := ui.box_rich_runs(b)
	if !testing.expect(t, len(runs) > 0, "the text is no rich paragraph") { return }
	background := ui.color_from_tags(s.state, b.tags_key, "find_match background")
	edge := ui.color_from_tags(s.state, b.tags_key, "find_match border")
	// (the letters of a match keep the text's colour: that of the runs around it)
	letters: Maybe(ui.Color)
	for r in runs { if r.background != background { letters = r.color; break } }
	found := make([dynamic]string, context.temp_allocator)
	for r in runs {
		if r.background == background {
			testing.expect_value(t, r.edge, edge)
			if l, ok := letters.?; ok { testing.expect_value(t, r.color, l) }
			append(&found, r.text)
		} else {
			testing.expectf(t, r.background.a == 0 && r.edge.a == 0, "the run '%s' has a background", r.text)
		}
		// (mono: every run in one face of its own, the monospace one, not the box's)
		testing.expectf(t, r.font != 0 && r.font == runs[0].font, "the run '%s' is not in the text's face", r.text)
	}
	// (each occurrence, case aside, in the text's own case)
	testing.expectf(t, len(found) == 2 && found[0] == "Error" && found[1] == "error", "the matches: %v", found)
}

@(test)
a_badge_and_a_tone :: proc(t: ^testing.T) {
	s, _, _ := open_rich(t)
	badge := session.get(s, "pv:level")
	testing.expect(t, session.find_text(s, "WARN") != nil, "the badge's words")
	testing.expect_value(t, ui.box_text(session.get(s, "icon", within = badge)), lucide.ALERT_TRIANGLE)
	bad := session.get(s, "pv:bad")
	want := ui.color_from_tags(s.state, bad.tags_key, "bad text")
	testing.expect_value(t, bad.target_text, want)
	plain := ui.color_from_tags(s.state, bad.tags_key, "text")
	testing.expect(t, want != plain, "the theme's bad text is its text: the test sees nothing")
}
