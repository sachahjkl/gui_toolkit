// gui_toolkit example: what changed in 0.55, a page per change, each showing it live.
//   odin build examples/whatsnew -vet -out:build/whatsnew.exe -subsystem:windows
//   build\whatsnew.exe                  the window
//   build\whatsnew.exe --page=lazy      open on a page (its name in lower case, or its number)
//   build\whatsnew.exe --frames=3       three frames without showing the window, then exit (a check that it runs)
package whatsnew

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "../../draw"
import "../../font"
import "../../platform"
import "../../render"
import "../../ui"

Page :: enum { Pacing, Lazy, Warning, Emboss, Rich, Merge, Wheel, Find, Smooth, Box_At, Webgpu, Tests }

PAGE_NAMES := [Page]string{
	.Pacing  = "Frame pacing",
	.Lazy    = "Lazy column",
	.Warning = "Layout warnings",
	.Emboss  = "Emboss by contrast",
	.Rich    = "Rich text versions",
	.Merge   = "next_merge",
	.Wheel   = "Wheel and hover",
	.Find    = "Find in page",
	.Smooth  = "Smooth scrolling",
	.Box_At  = "box_at",
	.Webgpu  = "WebGPU first frame",
	.Tests   = "Test guard",
}

App :: struct {
	win:     ^platform.Window,
	r:       render.Renderer,
	fonts:   font.State,
	dc:      draw.Context,
	theme:   ui.Theme,
	s:       ui.State,
	mono:    font.Font_Id,
	font:    font.Font_Id,
	pacer:   render.Pacer,
	slept:   bool,
	page:    Page,
	palette: Maybe(Page),   // the page the palette was applied for (Emboss has its own)
	n:       int,           // paragraphs of this build (their ids)
	// measures
	frames, at_once, after_rest: int,
	build_ms:   f64,   // build and layout of the last frame
	again:      bool,  // a figure shown changed: one more frame shows it
	lazy_all:   bool,
	lazy_built: [2]int,   // items built: this build, the last one (shown)
	mistake:    bool,
	warnings:   int,   // layout warnings shown
	versions:   bool,
	needle:     ui.Text_Field,
	smooth:     int,
	under:      [2]int,   // the wheel page's row under the pointer: this build, the last one
}

the_app: ^App

WHITE :: draw.Color{1, 1, 1, 1}

// A wrapped paragraph of the page.
para :: proc(text: string, weak := false) {
	app := the_app
	app.n += 1
	ui.next({width = ui.fill()})
	if weak {
		if ui.tags("weak") { ui.paragraph(fmt.tprintf("%s###p%d", text, app.n)) }
	} else {
		ui.paragraph(fmt.tprintf("%s###p%d", text, app.n))
	}
}

heading :: proc(text: string, em: f32) {
	ui.next({width = ui.fill(), height = ui.text_size(), font_size = em * 1.6})
	ui.label(fmt.tprintf("%s###h", text))
	ui.spacer(ui.px(em * 0.6))
}

gap :: proc(em: f32, k: f32 = 1) { ui.spacer(ui.px(em * k)) }

build :: proc(app: ^App) {
	em := ui.font_size()
	app.n = 0
	if app.page != .Find { ui.find("") }   // (the find page sets its needle each build; elsewhere none)
	ui.next({width = ui.fill(), height = ui.fill(), axis = .X})
	if ui.row(id = "###main") {
		// the pages
		ui.next({width = ui.px(em * 15), height = ui.fill(), axis = .Y})
		if ui.column(id = "###nav") {
			gap(em)
			for p in Page {
				ui.next({width = ui.fill(), text_align = .Left, text_pad = em})
				id := fmt.tprintf("%d  %s###nav%d", int(p) + 1, PAGE_NAMES[p], int(p))
				if p == app.page {
					if ui.tags("menu_item", "selected") { ui.button(id) }
				} else if ui.tags("menu_item") {
					if ui.button(id).clicked { app.page = p }
				}
			}
			gap(em)
			ui.next({width = ui.fill()})
			if ui.tags("weak") { ui.label(fmt.tprintf("build + layout %.2f ms###ms", app.build_ms)) }
		}
		ui.next({width = ui.px(1), height = ui.fill(), bg = ui.theme_lookup(&app.theme, {}, "border")})
		ui.build_box({.Draw_Background}, "###rule")
		ui.next({width = ui.fill(), height = ui.fill(), axis = .X})
		if ui.row(id = "###page") {
			gap(em * 1.5)
			ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
			if ui.column(id = "###content") {
				gap(em * 1.2)
				switch app.page {
				case .Pacing:  page_pacing(app, em)
				case .Lazy:    page_lazy(app, em)
				case .Warning: page_warning(app, em)
				case .Emboss:  page_emboss(app, em)
				case .Rich:    page_rich(app, em)
				case .Merge:   page_merge(app, em)
				case .Wheel:   page_wheel(app, em)
				case .Find:    page_find(app, em)
				case .Smooth:  page_smooth(app, em)
				case .Box_At:  page_box_at(app, em)
				case .Webgpu:  page_webgpu(app, em)
				case .Tests:   page_tests(app, em)
				}
				gap(em)
			}
			gap(em * 1.5)
		}
	}
}

////////////////////////////////
// the pages

page_pacing :: proc(app: ^App, em: f32) {
	heading("Frame pacing, ready-made", em)
	para("render.pace_frame and render.paced_present run the toolkit's cadence model for a window: the screen's plan, the swap chain's slot, its latency. This window uses them; so does opencode native (its own pacing code is gone).")
	gap(em)
	para("A frame less between input and screen (Direct3D 11): the renderer takes one of the swap chain latency object's counts for good, so a frame starts when the last one is on screen instead of queueing behind it. Measured in opencode native, a fast hand over a list, six runs each: 49 ms from input to screen before, 34 after, at 60 frames a second.")
	gap(em)
	para("And one thing measured and left out: showing input after a rest at once (no wait for the refresh) left the swap chain a frame deeper for the rest of the session (45 to 60 ms). The pacer does not do it.")
	gap(em)
	p := &app.pacer
	lines := [?]string{
		fmt.tprintf("frames presented        %d", app.frames),
		fmt.tprintf("  after a rest          %d", app.after_rest),
		fmt.tprintf("  shown at once         %d   (a resize step)", app.at_once),
		fmt.tprintf("swap chain latency      %d", p.latency),
	}
	for l, i in lines {
		ui.next({width = ui.fill(), height = ui.text_size(), font = ui.mono_font()})
		ui.label(fmt.tprintf("%s###l%d", l, i))
	}
}

LAZY_COUNT :: 5000

page_lazy :: proc(app: ^App, em: f32) {
	heading("A lazy column", em)
	para("ui.lazy_begin and ui.lazy_item: in a scroll box, only the items near the view are built; the others stand as a space of the height they had when last built. 5000 items of different heights here.")
	gap(em * 0.6)
	ui.next({width = ui.fill(), height = ui.text_size(), axis = .X, cross = .Center})
	if ui.row(id = "###bar") {
		ui.toggle("###all", "Build every item (as before)", &app.lazy_all)
		gap(em * 2)
		ui.next({height = ui.text_size(), font = ui.mono_font()})
		ui.label(fmt.tprintf("built this frame: %d of %d###built", app.lazy_built[1], LAZY_COUNT))
	}
	gap(em * 0.6)
	app.lazy_built[0] = 0
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.scroll_y("###lzs") {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###col") {
			lz := ui.lazy_begin(all = app.lazy_all)
			for i in 0 ..< LAZY_COUNT {
				if ui.lazy_item(lz, fmt.tprintf("###it%d", i)) { lazy_entry(app, i, em) }
			}
		}
	}
}

lazy_entry :: proc(app: ^App, i: int, em: f32) {
	app.lazy_built[0] += 1
	words := 6 + (i * 37) % 70
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "Item %d. ", i)
	for w in 0 ..< words { strings.write_string(&sb, WORDS[(i + w * 7) % len(WORDS)]); strings.write_byte(&sb, ' ') }
	ui.next({width = ui.fill()})
	ui.paragraph(fmt.tprintf("%s###t", strings.to_string(sb)))
	ui.next({width = ui.fill(), height = ui.px(1), bg = ui.theme_lookup(&app.theme, {}, "border")})
	ui.build_box({.Draw_Background}, "###sep")
	gap(em * 0.4)
}

WORDS := [?]string{"retained", "boxes", "layout", "scroll", "glyph", "frame", "swap", "chain", "paragraph", "theme", "pacing", "latency", "window", "caret", "wheel", "column"}

page_warning :: proc(app: ^App, em: f32) {
	heading("Layout warnings", em)
	para("A percentage resolves against the nearest ancestor that is not sized by its children. Inside a box sized by its children, pct(1) is a share of a box further up: in a debug build the toolkit now says so, once per box (on stderr, and ui.layout_warnings() for a tool).")
	gap(em * 0.6)
	ui.toggle("###mistake", "Make the mistake", &app.mistake)
	gap(em * 0.6)
	ws := ui.layout_warnings()
	if len(ws) == 0 {
		para("No warning yet.", true)
	} else {
		for w in ws {
			ui.next({width = ui.fill(), font = ui.mono_font()})
			if ui.tags("bad") { app.n += 1; ui.paragraph(fmt.tprintf("ui: layout: %s###w%d", w, app.n)) }
		}
	}
	gap(em * 0.6)
	if app.mistake {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y, bg = ui.theme_lookup(&app.theme, {}, "track")})
		if ui.column(flags = {.Draw_Background}, id = "card sized by its children###card") {
			ui.next({width = ui.fill(), height = ui.pct(0.8), bg = draw.hex(0xd13b2e60), fg = WHITE})
			ui.build_box({.Draw_Background, .Draw_Text}, "a box of height pct(0.8)###tall")
		}
	}
}

page_emboss :: proc(app: ^App, em: f32) {
	heading("Emboss by contrast", em)
	para("Themes with a Gradient finish (Bootstrap here) engrave a button's text. The direction now comes from the text against what is under it: lighter text sits in a groove (a dark edge above), darker text is lit from below. It came from the text alone, so grey text on a dark button took a light edge under it and looked a pixel low.")
	gap(em)
	Sample :: struct { label: string, bg, fg: u32 }
	samples := [?]Sample{
		{"Grey on dark", 0x1e1e1eff, 0xb4b4b4ff},
		{"Grey on light", 0xe8e8e8ff, 0x6a6a6aff},
		{"White on blue", 0x0a6fd1ff, 0xffffffff},
		{"Dark on yellow", 0xf8c606ff, 0x3a2a00ff},
	}
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(id = "###samples") {
		for s, i in samples {
			ui.next({width = ui.px(em * 11), height = ui.px(em * 3.4), font_size = em * 1.4, bg = draw.hex(s.bg), fg = draw.hex(s.fg), text_align = .Center})
			ui.button(fmt.tprintf("%s###s%d", s.label, i))
			gap(em)
		}
	}
	gap(em)
	para("The edge is one pixel: look closely at the top and bottom of the letters.", true)
}

RICH_COUNT :: 300

page_rich :: proc(app: ^App, em: f32) {
	heading("Rich text versions", em)
	para("rich_paragraph(id, runs, version = v): with a version, the layout cache finds the paragraph by (box, version) instead of hashing all of its text at every frame. The application changes the version when the text changes (opencode native: where the Markdown block lies in the message).")
	gap(em * 0.6)
	ui.next({width = ui.fill(), height = ui.text_size(), axis = .X, cross = .Center})
	if ui.row(id = "###bar") {
		ui.toggle("###v", "Pass versions", &app.versions)
		gap(em * 2)
		ui.next({height = ui.text_size(), font = ui.mono_font()})
		ui.label(fmt.tprintf("%d paragraphs, build + layout %.2f ms###t", RICH_COUNT, app.build_ms))
	}
	gap(em * 0.6)
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.scroll_y("###rs") {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###col") {
			accent := ui.theme_lookup(&app.theme, {}, "accent")
			for i in 0 ..< RICH_COUNT {
				runs := [?]ui.Rich_Run{
					{text = "Paragraph ", style = {bold = true}},
					{text = LOREM[(i * 13) % 200:], style = {}},
					{text = " a link", style = {color = accent, underline = true}},
				}
				ui.next({width = ui.fill()})
				ui.rich_paragraph(fmt.tprintf("###r%d", i), runs[:], version = app.versions ? u64(i + 1) : 0)
				gap(em * 0.5)
			}
		}
	}
}

LOREM := "Immediate mode with retained boxes: each frame the application describes its interface again, the toolkit keeps the boxes between frames by their keys, lays them out and draws what changed. Text is shaped once and cached; a long conversation of Markdown paragraphs is mostly text the cache already holds, and the cost that remains is finding it, which hashed every byte of every paragraph at every frame before versions."

page_merge :: proc(app: ^App, em: f32) {
	heading("next_merge", em)
	para("A helper that styles its box with ui.next replaced what its caller had set (a width, a position). ui.next_merge adds to it: the caller's fields stay, the helper's fill the rest. merge_mod is public and merges every field.")
	gap(em)
	ui.next({width = ui.px(em * 26)})
	pill("caller: width 26 em, helper: next_merge###m1", true)
	gap(em * 0.6)
	ui.next({width = ui.px(em * 26)})
	pill("caller: width 26 em, helper: next###m2", false)
	gap(em)
	para("Both helpers set a height, colours and a radius; only the first keeps the caller's width.", true)
}

pill :: proc(id: string, merge: bool) -> ui.Signal {
	m := ui.Style_Mod{height = ui.px(ui.font_size() * 2.4), bg = draw.hex(0x2f86dbff), fg = WHITE, radius = ui.font_size() * 1.2, text_align = .Center}
	if merge { ui.next_merge(m) } else { ui.next(m) }
	return ui.signal(ui.build_box({.Draw_Background, .Draw_Text, .Clickable}, id))
}

page_wheel :: proc(app: ^App, em: f32) {
	heading("Wheel and hover", em)
	para("Rolling the wheel without moving the mouse moves the rows under the pointer: the highlight now follows the row that is there (the wheel makes the pointer's position valid again). It stayed on a row that had scrolled away.")
	gap(em * 0.6)
	ui.next({width = ui.fill(), height = ui.text_size(), font = ui.mono_font()})
	ui.label(app.under[1] >= 0 ? fmt.tprintf("under the pointer: row %d###u", app.under[1]) : "under the pointer: none###u")
	gap(em * 0.6)
	app.under[0] = -1
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.scroll_y("###ws") {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###col") {
			for i in 0 ..< 80 {
				ui.next({width = ui.fill(), text_align = .Left})
				if ui.tags("menu_item") {
					if ui.button(fmt.tprintf("Row %d###r%d", i, i)).hovering { app.under[0] = i }
				}
			}
		}
	}
}

page_find :: proc(app: ^App, em: f32) {
	heading("Find in page", em)
	para("ui.find(needle, scope) every build while searching, ui.find_matches() for the rects of the last layout, ui.find_set_current(i) for the one painted as current. Matches span the runs of a rich paragraph; not across boxes, and text the build did not make is not searched.")
	gap(em * 0.6)
	ui.next({width = ui.px(em * 20)})
	ui.line_edit("###needle", &app.needle, "Find in the text below")
	needle := ui.field_string(&app.needle)
	scope := ui.box_at("###main", "###page", "###content", "###text")   // the column below, found by its path
	ui.find(needle, scope != nil ? scope.key : 0)
	ui.find_set_current(0)
	gap(em * 0.4)
	ui.next({width = ui.fill(), height = ui.text_size(), font = ui.mono_font()})
	if ui.tags("weak") { ui.label(needle == "" ? "type a word###c" : fmt.tprintf("%d matches###c", ui.find_count())) }
	gap(em * 0.6)
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if ui.column(id = "###text") {
		para(LOREM)
		gap(em * 0.6)
		runs := [?]ui.Rich_Run{{text = "A rich paragraph: the frame "}, {text = "lays", style = {bold = true}}, {text = " out the boxes, then draws the frame."}}
		ui.next({width = ui.fill()})
		ui.rich_paragraph("###rp", runs[:], version = 1)
	}
}

page_smooth :: proc(app: ^App, em: f32) {
	heading("Smooth scrolling", em)
	para("Build_Params.smooth_scroll: Follow (as animations do: the system's setting), On, or Off: the wheel jumps a step at once, even with animations on.")
	gap(em * 0.6)
	labels := [?]string{"Follow the system", "Glide", "Jump"}
	ui.next({width = ui.px(em * 24)})
	ui.segmented("###mode", labels[:], &app.smooth)
	gap(em * 0.6)
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.scroll_y("###ss") {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###col") {
			for i in 0 ..< 200 {
				ui.next({width = ui.fill(), height = ui.text_size()})
				ui.label(fmt.tprintf("Line %d: roll the wheel###l%d", i, i))
			}
		}
	}
}

page_box_at :: proc(app: ^App, em: f32) {
	heading("box_at", em)
	para("ui.box_at(ids...): the box of the last build at a path of ids from the root, from outside a build (a test, a tool, an overlay that needs a rect). The find page uses it for its scope. (The ids below are written without their three hashes.)")
	gap(em)
	paths := [?][]string{{"###main", "###nav"}, {"###main", "###page", "###content"}, {"###main", "###nav", "###nav3"}, {"###main", "###nothing"}}
	for p, i in paths {
		b := ui.box_at(..p)
		desc := b != nil ? fmt.tprintf("x %.0f  y %.0f  w %.0f  h %.0f", b.rect.min.x, b.rect.min.y, b.rect.max.x - b.rect.min.x, b.rect.max.y - b.rect.min.y) : "nil"
		ui.next({width = ui.fill(), height = ui.text_size(), font = ui.mono_font()})
		shown := make([dynamic]string, context.temp_allocator)
		for id in p { append(&shown, fmt.tprintf("\"%s\"", strings.trim_prefix(id, "###"))) }
		ui.label(fmt.tprintf("box_at(%s)  ->  %s###b%d", strings.join(shown[:], ", ", context.temp_allocator), desc, i))
	}
}

page_webgpu :: proc(app: ^App, em: f32) {
	heading("WebGPU: the first frame", em)
	para("On Direct3D 12 without DXC next to the program, wgpu compiles the shaders with FXC: seconds for the first frame's pipelines, during which the window stayed white. The renderer now presents the theme's background first, then compiles; when the first frame took over a second with FXC, it says on stderr to put dxcompiler.dll and dxil.dll next to the program (tools/fetch_wgpu.ps1).")
	gap(em)
	para("Try it: odin build examples/whatsnew -define:TOOLKIT_RENDER=wgpu -out:build/whatsnew_wgpu.exe", true)
	gap(em)
	para("docs/font-backend.md also explains now how a program with a Rust crate of its own builds the toolkit's text backend into it (one Rust standard library per program), and why the prebuilt wgpu-native cannot join it on Windows.")
}

page_tests :: proc(app: ^App, em: f32) {
	heading("A guard for the single-threaded tests", em)
	para("The tests that drive the toolkit's global UI state (keyboard, status, states, ui_robust, a11y) failed in misleading ways on several threads: bad frees, a run that never ends. They now refuse to compile without -define:ODIN_TEST_THREADS=1, with a message that says why.")
	gap(em)
	ui.next({width = ui.fill(), font = ui.mono_font()})
	app.n += 1
	ui.paragraph(fmt.tprintf("Error: Compile time assertion: #config(ODIN_TEST_THREADS, 0) == 1 (\"run these tests with -define:ODIN_TEST_THREADS=1: they drive the toolkit's global UI state one test at a time\")###p%d", app.n))
}

////////////////////////////////

frame :: proc(app: ^App) {
	if ui.building() { return }
	at_once := render.pace_frame(&app.pacer, &app.r, app.win, idled = app.slept, dragging = ui.active_key() != 0)
	app.frames += 1   // (this one, counted before it is shown)
	if app.slept { app.after_rest += 1 }
	if at_once { app.at_once += 1 }
	app.slept = false
	events := platform.poll_events(app.win, false)
	render.resize(&app.r, app.win.size)
	// the Emboss page shows a theme with a Gradient finish
	want := app.page == .Emboss ? Page.Emboss : Page.Pacing
	if app.palette != want {
		app.palette = want
		ui.apply_palette(&app.theme, want == .Emboss ? ui.PALETTE_BOOTSTRAP : ui.PALETTE_MIDNIGHT, render.blend_space(&app.r))
		platform.set_dark_title(app.win, want != .Emboss)
	}
	size := draw.Vec2{f32(app.win.size.x), f32(app.win.size.y)}
	t0 := time.tick_now()
	ui.begin_build(&app.s, {
		window_size = size, events = events, dt = 1.0 / 60, animations = platform.os_animations_enabled(),
		smooth_scroll = ui.Smooth_Scroll(app.smooth),
		dpi_scale = app.win.dpi_scale, window = app.win,
		base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = app.font, font_size = 15, text_pad = 6, cursor = .Arrow},
		clipboard_get = proc() -> string { return platform.get_clipboard(the_app.win, context.temp_allocator) },
		clipboard_set = proc(text: string) { platform.set_clipboard(the_app.win, text) },
	})
	ui.set_layout_warnings(&app.s, true)   // (on in debug builds; this page shows them in any build)
	build(app)
	ui.end_build()
	ms := time.duration_milliseconds(time.tick_since(t0))
	app.again = app.lazy_built[1] != app.lazy_built[0] || app.under[1] != app.under[0] || len(ui.layout_warnings()) != app.warnings
	app.warnings = len(ui.layout_warnings())
	app.build_ms = ms
	app.lazy_built[1] = app.lazy_built[0]
	app.under[1] = app.under[0]
	platform.set_cursor(app.win, ui.cursor(&app.s))
	draw.begin_frame(&app.dc, size)
	render.frame_begin(&app.r, ui.theme_lookup(&app.theme, {}, "background"))
	ui.draw_tree(&app.s, &app.dc)
	draw.end_frame(&app.dc)
	render.frame_end(&app.r, !at_once)
	render.paced_present(&app.pacer)
	free_all(context.temp_allocator)
}

main :: proc() {
	frames := -1
	app := new(App)
	defer free(app)
	the_app = app
	app.under = {-1, -1}
	for a in os.args[1:] {
		if strings.has_prefix(a, "--frames=") { frames, _ = strconv.parse_int(a[len("--frames="):]) }
		if a == "--mistake" { app.mistake = true }
		if strings.has_prefix(a, "--page=") {
			v := a[len("--page="):]
			if n, ok := strconv.parse_int(v); ok && n >= 1 && n <= len(Page) { app.page = Page(n - 1) }
			for p in Page { if strings.equal_fold(v, fmt.tprintf("%v", p)) { app.page = p } }
		}
	}
	font.init(&app.fonts)
	defer font.destroy(&app.fonts)
	app.win = platform.open_window("What's new in gui_toolkit 0.55", {1100, 720})
	if app.win == nil { fmt.eprintln("whatsnew: no window"); os.exit(1) }
	defer platform.destroy_window(app.win)
	if !render.init_window(&app.r, app.win, app.win.size) { fmt.eprintln("whatsnew: no renderer"); os.exit(1) }
	defer render.destroy(&app.r)
	ok: bool
	app.font, ok, _ = font.load_system_or_embedded(&app.fonts, platform.system_font_path("segoeui.ttf"), font.FALLBACK_UI_DATA)
	if !ok { fmt.eprintln("whatsnew: no UI font"); os.exit(1) }
	if mono, mok, _ := font.load_system_or_embedded(&app.fonts, platform.system_font_path("consola.ttf"), font.FALLBACK_MONO_DATA); mok { app.mono = mono }
	draw.init(&app.dc, &app.r, &app.fonts)
	defer draw.destroy(&app.dc)
	defer ui.theme_destroy(&app.theme)
	ui.apply_palette(&app.theme, ui.PALETTE_MIDNIGHT, render.blend_space(&app.r))
	ui.init(&app.s, &app.fonts, &app.theme)
	app.s.mono_font = app.mono
	defer ui.destroy(&app.s)
	defer ui.field_destroy(&app.needle)
	ui.field_set(&app.needle, "the")
	platform.set_dark_title(app.win, true)
	app.win.user = app
	app.win.on_frame = proc(user: rawptr) { frame((^App)(user)) }

	if frames >= 0 {
		for _ in 0 ..< frames { frame(app) }
		fmt.printfln("whatsnew: %d frames, %d boxes, last build %.2f ms", frames, app.s.boxes_built, app.build_ms)
		return
	}
	platform.show_window(app.win)
	for !platform.is_closed(app.win) {
		if !ui.needs_frame(&app.s) && !app.again { platform.wait_event(app.win, ui.wake_in_ms(&app.s)); app.slept = true }
		frame(app)
	}
}
