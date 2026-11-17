# film: videos of an interface

`gt:film` records a program made with the toolkit as a video file, as a person would use it: a pointer that glides and
clicks, keys, typed words. The program draws its frames headless, on its graphics card, on the film's clock: a film is
made faster than it plays, and two runs give the same pictures. Design:
[src/md/features/film.md](../src/md/features/film.md).

It needs `ffmpeg` on the `PATH`. With an NVIDIA card it encodes with NVENC (`h264_nvenc`), else with `libx264`.

## Making the toolkit's films

`odin run tools/tk -- film` makes every film of `tools/film` into `build/films/<name>.mp4`: the showcase, opened
headless at 1600 × 900 on a 1920 × 1080 stage, each film a tool of the toolkit with a title card before it and an end
card after it, both drawn by the toolkit.

```
odin run tools/tk -- film                      every film
odin run tools/tk -- film themes palette       those
odin run tools/tk -- film -list                their names and what each shows
odin run tools/tk -- film -out:site/films      elsewhere
```

## Filming a program

The program opens its window headless on the card (`host.Open_Options{headless = true, headless_gpu = true}`); a film
records it.

```odin
rec: film.Recorder
app := film.App{win = h.win, state = &h.state, renderer = &sh.r, user = h,
	frame = proc(user: rawptr) { host.host_frame((^host.Host)(user)) }}
if why := film.start(&rec, app, {out = "save.mp4", size = {1920, 1080}}); why != "" { fmt.eprintln(why); return }
film.pointer_show(&rec, true, {200, 200})
film.move_to(&rec, film.center(film.box(&rec, "save")))   // the box named "save" in the last build
film.click(&rec)
film.hold(&rec, 1.5)
if why := film.finish(&rec); why != "" { fmt.eprintln(why) }
```

`film.start` makes the State's clock the film's (`ui.set_clock`): each frame moves it by 1/fps. `film.finish` writes
the last frame, waits for ffmpeg and gives the State its own clock back. Both return "" when all went well, else why not.

`Options`: `out` the file; `fps` (60); `size` the film's size (the window's when zero); `quality`, the encoder's constant
quality (18; lower is better); `encoder` (`Auto`: NVENC when a probe encodes with it); `stage`, the look of the ground
the window stands on when it is smaller than the film: its gradient, the window's corners, its shadow.

## The script

Each action makes the frames it lasts and sends its events through the program's own input
(`platform.inject_event`). Points are the window's client pixels.

| Procedure | What it does |
|---|---|
| `hold(r, seconds)` | frames, nothing done |
| `pointer_show(r, shown, at)` | the pointer shows (at a place) or hides |
| `move_to(r, to, seconds)` | the pointer glides to `to` along an ease, a move each frame: hovers light up on the way |
| `click(r, button, count)` | a press, a tenth of a second, a release; a ring spreads from it |
| `press(r)`, `release(r)` | one half of a click |
| `drag_to(r, to, seconds)` | a press, a glide with the button held, a release |
| `wheel(r, notches, seconds)` | the wheel where the pointer is, spread over the time |
| `key(r, k, mods, after)` | a key pressed and released, then `after` seconds |
| `type_text(r, text, per_second)` | words at a person's pace; Enter and Tab as keys |
| `resize(r, size)` | the window's size in pixels from the next frame; the stage centres it |
| `fade(r, seconds)` | the next frames fade in from the frame written last |
| `switch_to(r, app)` | the film goes on with another program's window (a title card, then the program) |
| `box(r, name, text, index, within)` | a box of the last build, by its name or its words (`ui.box_find`) |
| `center(b, at)` | a box's middle, or another point of it (`at`: 0..1 of its width and height) |

`Recorder.each` runs before each frame: what moves with the film's time and is no input (a camera, a value set by the
script). `frame(r)` makes one frame by hand; `frames_of(r, seconds)` says how many a time takes; `now(r)` the film's
time so far. `ease_in_out`, `smooth`, `ease_out_back` and `tween` are the script's eases.

## What a frame costs

On an RTX 4070 SUPER, the showcase at 1920 × 1080: build and draw 2 to 11 ms, the read back 5 ms, the write on a thread
of its own while the next frame is drawn. A 39-second film takes 32 seconds. On the software renderer the same film took
more than 15 minutes: `headless_gpu` is what a film needs.
