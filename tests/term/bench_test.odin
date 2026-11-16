package term_test

// The grid's draw timed, on the interface's thread: a screen of 40 rows of 120 cells of words in colours, at rest and
// while lines are printed (every row moves up, one is new). Opt-in, and only worth reading from an optimised build:
//   odin test tests/term -collection:gt=src -o:speed -define:ODIN_TEST_THREADS=1 -define:TERM_TIMING=true
//     -define:ODIN_TEST_NAMES=term_test.the_draw_timed

import "core:fmt"
import "core:slice"
import "core:testing"
import "core:time"
import "gt:draw"
import "gt:render"
import "gt:term"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

TERM_TIMING :: #config(TERM_TIMING, false)

@(private = "file") BENCH_ROWS :: 40
@(private = "file") BENCH_COLS :: 120
@(private = "file") BENCH_DRAWS :: 300

// A screen whose line `first + y` is drawn on row y: a line printed is `first` one more.
@(private = "file")
Bench_Screen :: struct {
	first: int,
	dirty: term.Dirty,
}

@(private = "file")
bench_source :: proc(b: ^Bench_Screen) -> term.Source {
	return {
		data = b,
		picture = proc(data: rawptr) -> (p: term.Picture, ok: bool) {
			b := (^Bench_Screen)(data)
			p.dirty = b.dirty
			p.foreground, p.background = {1, 1, 1, 1}, {0, 0, 0, 1}
			return p, true
		},
		rows = proc(data: rawptr, sink: ^term.Sink) {
			b := (^Bench_Screen)(data)
			WORDS := [?]string{"build", "src/term/widget.odin", "ok", "0.47ms", "--release", "fn", "picture", "replay"}
			COLORS := [?]term.Color{{0.9, 0.9, 0.9, 1}, {0.4, 0.8, 0.4, 1}, {0.9, 0.6, 0.2, 1}, {0.5, 0.6, 1, 1}}
			for y in 0 ..< BENCH_ROWS {
				if !term.sink_row(sink, true) { continue }
				line := b.first + y
				x := 0
				for w := line; x < BENCH_COLS; w += 1 {
					word := WORDS[w % len(WORDS)]
					fg := COLORS[(w + line) % len(COLORS)]
					for i in 0 ..< len(word) {
						if x >= BENCH_COLS { break }
						term.sink_cell(sink, {text = word[i:i + 1], fg = fg, flags = w % 5 == 0 ? {.Bold} : {}})
						x += 1
					}
					if x < BENCH_COLS { term.sink_cell(sink, {}); x += 1 }
				}
			}
			b.dirty = .None
		},
	}
}

@(test)
the_draw_timed :: proc(t: ^testing.T) {
	when !TERM_TIMING { return }
	unwatched.run(t, proc(t: ^testing.T) {
		Bench :: struct { screen: Bench_Screen, v: term.View }
		g := new(Bench)
		defer free(g)
		g.screen.dirty = .All
		term.init(&g.v, bench_source(&g.screen), BENCH_COLS, BENCH_ROWS)
		defer term.destroy(&g.v)
		s := session.start(t, {size = {1100, 760}, user = g, build = proc(s: ^session.Session) {
			g := (^Bench)(s.user)
			term.build(&g.v, {fonts = &s.own.fonts, font = s.own.mono_font, font_bold = s.own.mono_font, font_size = 13,
				pad = 4, background = {0, 0, 0, 1}, selection = {0.2, 0.4, 0.8, 1}, faint = 0.5, cursor_alpha = 1})
		}})
		session.frames(s, 3)
		box := session.get(s, "term_box")
		// (the box's own draw alone, in a frame of the session's renderer: what the interface's thread spends on the grid)
		timed :: proc(s: ^session.Session, box: ^ui.Box, g: ^Bench, print: bool) -> (median, p90: f64) {
			ms := make([]f64, BENCH_DRAWS, context.temp_allocator)
			for i in 0 ..< BENCH_DRAWS {
				if print { g.screen.first += 1; g.screen.dirty = .All }
				draw.begin_frame(&s.own.dc, {1100, 760})
				render.frame_begin(&s.own.renderer, {0, 0, 0, 1})
				t0 := time.tick_now()
				box.custom(box, box.custom_user, &s.own.dc)
				ms[i] = time.duration_milliseconds(time.tick_since(t0))
				draw.end_frame(&s.own.dc)
				render.frame_end(&s.own.renderer)
			}
			slice.sort(ms)
			return ms[BENCH_DRAWS / 2], ms[BENCH_DRAWS * 9 / 10]
		}
		rest, rest90 := timed(s, box, g, false)
		printing, printing90 := timed(s, box, g, true)
		fmt.printfln("term draw, %d rows of %d cells: at rest median %.4f ms (p90 %.4f), printing median %.4f ms (p90 %.4f)",
			BENCH_ROWS, BENCH_COLS, rest, rest90, printing, printing90)
	})
}
