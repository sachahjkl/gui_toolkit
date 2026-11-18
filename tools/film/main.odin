// film: the toolkit's films, each a tool of it shown in the showcase as a person uses it (gt:film,
// src/md/features/film.md). `tk film` builds and runs it.
//   film [name...] [-out:dir] [-list]       the films named (none: all) -> <dir>/<name>.mp4 (default build/films)
package film_tool

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "../../examples/showcase"
import "gt:film"
import host "gt:host"
import "gt:platform"
import "gt:render"

// A film: its file's name, what it shows, its script.
Film :: struct {
	name:  string,
	about: string,
	run:   proc(t: ^Take),
}

FILMS := [?]Film{
	{"exploded", "The exploded view: every box of a window in depth, turned round, its layers parting on the beat", exploded_film},
	{"themes", "Themes, finishes, the light and the dark version, the corners: one choice, the whole interface", themes_film},
	{"palette", "The command palette: every command, setting and view, found by a few letters", palette_film},
	{"layout", "A window that narrows: columns go one under the other, rows wrap, nothing spills", layout_film},
	{"toolbars", "One tool bar, two ways to narrow: wrap onto lines, or fold into its menu", toolbars_film},
	{"menus", "Menus as wide as their widest row; typing searches them and their submenus", menus_film},
	{"dialogs", "A view in a dialog, a confirmation, a prompt: they fade in and answer", dialogs_film},
	{"values", "A setting's value kind, and the control it gets", values_film},
	{"settings", "The settings page every program has: its pages, its search, a change at once", settings_film},
	{"runtime", "A plugin written, then run by gt-runtime: a log explorer of 250 000 lines in a lazy list", nil},
}

// The film's size, and the windows' logical size: the showcase at 125 % stands on the stage (1600 x 900 on 1920 x 1080),
// a full-frame window (a title card, the exploded view) at 150 % fills it.
FILM_SIZE :: [2]int{1920, 1080}
WINDOW_LOGICAL :: [2]int{1280, 720}
DPI_STAGED :: 120
DPI_FULL :: 144

// What a film works with: the recorder, the showcase, the title card.
Take :: struct {
	rec:   film.Recorder,
	app:   ^showcase.App,
	card:  ^Card,
	full:  bool,          // the showcase fills the frame (the exploded view) instead of standing on the stage
}

main :: proc() {
	out := "build/films"
	names := make([dynamic]string)
	for a in os.args[1:] {
		switch {
		case a == "-list":
			for f in FILMS { fmt.printfln("%-10s %s", f.name, f.about) }
			return
		case strings.has_prefix(a, "-out:"): out = a[len("-out:"):]
		case strings.has_prefix(a, "-"):
			fmt.eprintfln("film: %s is no flag (-out:dir, -list)", a)
			os.exit(2)
		case: append(&names, a)
		}
	}
	_ = os.make_directory_all(out)
	failed := 0
	for f in FILMS {
		if len(names) > 0 && !contains(names[:], f.name) { continue }
		path := fmt.aprintf("%s/%s.mp4", out, f.name)
		defer delete(path)
		began := time.tick_now()
		if why := shoot(f, path); why != "" {
			fmt.eprintfln("film %s: %s", f.name, why)
			failed += 1
			continue
		}
		fmt.printfln("film %s: %s in %v", f.name, path, time.tick_since(began))
	}
	for n in names {
		known := false
		for f in FILMS { known ||= f.name == n }
		if !known { fmt.eprintfln("film: no film %s (-list)", n); failed += 1 }
	}
	if failed > 0 { os.exit(1) }
}

@(private = "file")
contains :: proc(list: []string, s: string) -> bool {
	for x in list { if x == s { return true } }
	return false
}

// One film: the showcase and the title card opened, the recorder on the title card first, the script, the end.
@(private = "file")
shoot :: proc(f: Film, path: string) -> string {
	// (gt-runtime's film is its own application, not the showcase)
	if f.run == nil { return shoot_runtime(path) }
	t := new(Take)
	defer free(t)
	t.full = f.name == "exploded"
	t.app = showcase.open({args = {fmt.tprintf("--size=%dx%d", WINDOW_LOGICAL.x, WINDOW_LOGICAL.y)}, headless = true, gpu = true})
	if t.app == nil { return "the showcase does not open" }
	defer showcase.close(t.app)
	platform.set_offscreen_dpi(t.app.main.win, t.full ? DPI_FULL : DPI_STAGED)
	// (each scene opens what it opens at its first builds: its frames before the film)
	for _ in 0 ..< 4 { showcase.frame(t.app) }
	t.card = card_open()
	if t.card == nil { return "the title card does not open" }
	defer card_close(t.card)
	if why := film.start(&t.rec, card_app(t.card), {out = path, size = FILM_SIZE}); why != "" { return why }
	if info := render.adapter_info(&t.app.shared.r); info.software {
		fmt.eprintfln("film %s: on the software renderer (%s): slow", f.name, info.name)
	}
	f.run(t)
	return film.finish(&t.rec)
}

// The showcase's window as the film's.
showcase_app :: proc(t: ^Take) -> film.App {
	return {win = t.app.main.win, state = &t.app.main.state, renderer = &t.app.shared.r, user = t.app,
		frame = proc(user: rawptr) { showcase.frame((^showcase.App)(user)) }}
}

// The title, `seconds` long, then the showcase fades in.
open_with :: proc(t: ^Take, title, line: string, seconds := 2.6) {
	card_show(t.card, "gui_toolkit", title, line)
	film.switch_to(&t.rec, card_app(t.card))
	film.hold(&t.rec, seconds)
	film.switch_to(&t.rec, showcase_app(t))
	film.fade(&t.rec, 0.7)
}

// The end card fades in over the last frame of the showcase.
close_with :: proc(t: ^Take, seconds := 2.4) {
	film.pointer_show(&t.rec, false)
	card_show(t.card, "", "gui_toolkit", "gt.sacha.house")
	film.switch_to(&t.rec, card_app(t.card))
	film.fade(&t.rec, 0.7)
	film.hold(&t.rec, seconds)
}

_ :: host.Host
