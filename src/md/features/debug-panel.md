# The debug panel

`gt:debug` lets a program share its own state and its own acts with a debug surface: its values shown and edited
live, its acts pressed, in a dense window beside the page. The same panels reach the tools: the devtools' `Toolkit`
domain lists their values, sets one and presses an act by the same names. The view's tools (the wireframe, the
exploded view, the box tree) show the page; this shows the program.

```odin
soldier_debug :: proc(s: ^Soldier) {
	debug.number("model", &s.model, lo = 0, hi = MODELS - 1)
	if debug.section("Transform") {
		debug.vector("rotation", &s.rotation, step = 0.01)
		debug.vector("position", &s.position)
	}
	debug.value("look", &s.look)                   // any Odin value, by reflection
	if debug.act("Print") { fmt.println(debug.odin_text(s^)) }
}

debug.panel(&app.state, "Soldier", soldier_debug, &app.soldier)   // once, at start
```

## Decisions

### A panel is a procedure the toolkit runs

The program registers a procedure once; the toolkit calls it when the panel is needed: its tab is shown, or a tool
lists, sets or presses. The procedure calls `debug.*` and the program's own code, nothing else of the interface. A run
is one of three passes, decided by who runs it:

- **Build**: the tab is shown. Each call builds its dense row and edits the program's variable in place.
- **List**: a tool asks what the panels hold. Each call writes its path, its kind and its value.
- **Apply**: a tool sets a value or presses an act. The call whose path matches parses the value into the variable, or
  returns true for the act: the program's own code runs, on the interface thread, before the frame's build.

Why: when nothing shows a panel it costs nothing, not even a branch per panel per frame; a pointer is used only while
the procedure runs, never kept across frames; a tool reaches a panel that is closed. Sections are open in List and
Apply, so every value has its path.

Refused:

- **Calls in the program's build** (`if debug.panel("Soldier") { ... }` each frame). The debug window is a view, built
  after the program's page: the calls had to keep pointers until then (a local of the build is gone by then), an act
  pressed answered one frame late, and a tool could not list a closed panel without making it lie about being open.
- **A registry of pointers** (`debug.watch(&x)` once, drawn by the toolkit later): a pointer outlives what it points
  to, and the program cannot say ranges, sections or when a value is read only without a description language.

### Acts take no arguments

An act is a button. Its arguments are values of the same panel shown before it (`debug.number("count", &d.count);
if debug.act("Spawn") { spawn(d.count) }`). A tool sets them, then presses. One concept for a person and a tool, and
no second form of input. Acts in a row flow side by side (see "A dense look").

### Paths

A value's path is its panel, its sections and its label: `Soldier/Transform/position`. A path is stable: scripts and
tests hold it. A label holds no `/`. A pass matches by a hash of the path fed piece by piece, so the Build and Apply
passes make no string.

### One surface: the debug window

The window is a view (views.md) of the window's Views, id `DEBUG_VIEW` (`"debug"`), one instance per window, as the
exploded view's panel. It opens as a floating window at the top right of the content; its home is a panel docked at the
right. The views float it, dock it, send it to a window of its own, resize it and remember where.

- Its tabs: **View** (the toolkit's: the wireframe, the exploded view, the zoom, the density, the frame times, the
  boxes), then one per panel, in the order of registration.
- **Pin** on a panel's tab sends that panel to a view of its own (`DEBUG_PANEL_VIEW`, instance its name): it floats,
  docks beside the window or splits a dock as any view. Its tab leaves the window until that view closes.
- A filter field over the rows of the tab shown: a row shows when its words (its sections, then its label) hold each
  word typed (ASCII case ignored). The sections' headers go and their names show before the label, the words found
  lit as every filtered list lights them (`ui.word_ranges`, `matched_label`): a match in a section's name shows why a
  row is there.
- Floating, its tabs are its title bar (`View_Options.dense`): no title over them, the strip as tall as a dense row
  of tabs, on the well's colour as the sections' headers, the moves (back home, a window of its own, close) small at
  its end; its free part moves it. A title bar of a dialog's size over rows of a third of its height was the one thing
  not dense; a dialog's dark step on a light theme was a grey block. The title stays the window's accessible name.
  Docked, the stack's own strip names it and the tabs are the body's first row; in a window of its own the system's
  or the program's caption stays.
- Its body scrolls inside the view.
- The key is Ctrl+Alt+Shift+D, as the wireframe's W and the exploded view's E, in every build (`TOOLKIT_DEBUG_WINDOW`,
  "In every build" below). It opens the window and closes it; Escape closes it too while the focus is in it, where the
  key puts it. `ui` reads it at the end of the build, after every reader of keys: a program's own shortcut on the same
  chord takes the press first and keeps it (plume's, galerie's, classeur's and feuille's "Compact rows" is
  Ctrl+Alt+Shift+D; there the key is theirs until they move it). Read at the start, as before, it took their press in
  every debug build.

### Every window has it

Every window that `gt:host` opens has the surface from its open, in a build with the debug window: `host_open` (a
program's windows, its dialogs that are windows, a view's own window) and `host_adopt` attach it. The key works in
every program, with the View tab; each panel the program registers adds a tab. Each window has its own surface, its
own window and its own key. A window opened without `gt:host` gets the surface when a panel is registered on its
State (`debug.panel`), or by `debug.attach`; a window that `devtools.service` serves gets it too.

The debug window sent to a window of its own is in a view's window, which has its own surface too. There the key acts
on the debug window that the window shows (`Surface.shows`, set when the window builds it): it closes it, as in its
owner's window. Before, it opened a debug window of the debug window, and the one the person wanted to close stayed
(`tests/host`). A pinned panel's window does the same.

Why: the surface came with the first panel, and most programs never registered one. The key did nothing there, and
the View tab (the wireframe, the exploded view, the frame times) was missing where it was wanted (Tower). The window
is `gt:host`'s: it opens every window, so the attach is in one place and no program has to remember it.

Refused:

- **An attach at the first key press** (`ui` would make the surface when the key comes): `ui` cannot import `gt:debug`,
  and the hook is the only link (see below).
- **An attach in each program's start**: one place to forget per program, and a dialog's window is missed.

The cost: one `Surface` and its View panel per window (a few hundred bytes), made once at the open, freed with the
State. Nothing per frame while the window is closed (`tests/debug`). A build with `TOOLKIT_DEBUG_WINDOW=false` compiles
the attach to nothing (`tests/lean_build`, step `lean_build_bare`).

The surface is the debug package's, kept in the State's `debug_hook` (`ui.Debug_Hook`): `ui` reads the key, calls the hook, and
destroys the surface with the State. `ui` cannot import `gt:debug` (that imports `ui`): the hook is the one link. The
surface allocates with the allocator of the code that made it: a program's tracking allocator sees it.

A panel's procedure that calls `debug.panel` or `debug.panel_remove` changes nothing: every pass walks the list of
panels while the procedure runs, and a panel freed under its own run is a use after free. The pointer given to
`debug.panel` is the program's to keep alive until `panel_remove` or the State's end: the surface cannot know when it
dies, as no callback API can. A procedure that panics ends the process, as any of the program's code.

### A dense look, only here

The debug window is the author's instrument: many values read at a glance, changed by small drags, the object beside
it. A person's screens follow the person's density and the program's look; this one does not, as a browser's devtools
do not follow the page. `ui.dense_scope` holds it:

- text at `DENSE_FONT_SCALE` (0.85) of the program's size, a row one line of it high (`dense_row_height`), insets and
  gaps of a few pixels, hairline borders;
- square corners: every box built in a dense scope has none (`State.square_depth`; a shape's radius, `.Fixed_Radius`,
  stays), a check box's mark too, and the window itself (`View_Options.square`: its frame, its header, its body). A
  rounded corner is the person's comfort; on an instrument it is room taken from the values and a softness that
  reads as a person's screen. Tooltips that open from it keep the program's look; a dropdown's list and a cut text's
  bubble opened from it are dense (dropdown.md, text-reveal.md): an instrument's list as tall and as loose as a
  person's covered the values it is about;
- aligned without losing room: alignment comes from columns shared and sized by their content, never from a fixed
  width reserved or an empty cell. No gap that is neither content nor a row's tight inset;
- a label and its field on one row (`dense_row`), numbers in the mono face, aligned right. The labels' column of a
  panel is as wide as its longest label shown, its sections' indent counted (`ui.Dense_Labels`): every depth's fields
  start on one edge, and a panel of short labels ("time", "key") has a narrow column. `DENSE_LABEL_MIN_EM` (2.5) at
  least, `DENSE_LABEL_MAX_EM` (11) at most: a longer label is cut and opens whole (text-reveal.md). A label is measured
  once, by its text, and kept; a build takes the widest of the last build's labels (one lookup a row, the row being
  built anyway), so a label that comes or goes moves the column at the next build. With a filter, a label says its
  sections and is not indented. Refused: a fixed column of 7 ems (a gap before every short label's field), and a share
  of the row (an indented row's share is narrower: the fields of two depths did not line up);
- acts one after another share a row, as many as it holds, then the next (Dear ImGui's SameLine, implied): a row
  each for "Print" and "Reset" was a row of nothing after a short button. What is not an act ends their row. The first
  button starts where the labels' words start (a label's text inset), at its depth: at the row's edge it stood out of
  the column, left of the labels above it (socle's Apply panel);
- the theme's colours (light or dark, their contrast checked as every theme's), not a fixed dark skin: a dark window
  over a light program reads as another program, and its contrast would be nobody's. A theme's weak ink is made for
  text at its size: a dense label's is moved from its ground until it reads at 4.5:1 (Graphite's dark was 4.4, Midnight's
  light 4.0).

The density of the person is not used: at its largest the window would hold half of its rows. Every other screen
keeps the person's density; `dense_scope` is for instruments (the debug window, a program's own inspector), never for
a person's screens.

### Dense widgets in `ui`

What the window needs that a program needs too is in `ui`, generic:

- `drag_number`: the number inside its field. A horizontal drag changes it (Shift slower, Ctrl faster), the wheel over
  it steps it, Up and Down step it from the keyboard, a double click, Ctrl+click or Enter types it (Escape gives it
  back). A press that follows a press that dragged is a new drag, never the second click of a double click: two quick
  drags from the same place typed the value. With both bounds the field fills as a slider's track, from zero when the
  range holds zero (a sign reads at a glance). The fill is the accent made faint until the value reads over it at
  4.5:1; the value's place is two ticks of the whole accent at the field's edges, seen where the faint fill is not.
  A line across the field was refused: it crossed the digits. `-` and `+` show on demand.
- `drag_vector`: N of them side by side, each marked by its axis's colour.
- `tree_header`: a collapsible row; the caller (here the surface) keeps its open state.
- `dense_row`: a label and its field on one row.

The wheel over a dense field steps it, even in a view that scrolls (the owner's choice, against `wheel_steps`' rule for
a person's pages): an instrument's fields are changed far more than its list is scrolled. The panel scrolls by its bar,
and by the wheel over its labels and its headers.

The trap of that choice: a person scrolls the panel, the pointer still, and a field slides under it and takes the rest
of the wheel. A scroll in progress keeps its view (`ui.wheel_latched`): while the wheel turns on with no rest of
`WHEEL_LATCH_MS` (350), a box that takes the wheel itself inside the view the wheel scrolls does not take it. A wheel
that starts after a rest goes where the pointer is, and a box that has the keyboard takes it at once (the person
chose it: a slider clicked in a page of settings). It is the toolkit's rule for every view, as a browser's: an editor
in a page of settings is the same trap.

### Values

- Numbers (`int`, `f32`, `f64`, and any integer or float through `value`), with bounds and a step; vectors (`[N]f32`,
  N up to 4); a bool; an enum (its names by reflection); a string; a colour (a swatch and its four channels).
- `watch`: a value shown, never edited. `plot`: the program's `ui.Value_History` as a graph across the field's whole
  width, `PLOT_ROWS` rows high, scaled from its lowest to its highest value, with those two and its last at its right.
  A sparkline of a row's height beside the value showed a shape and no number to read it by. The program pushes each frame (a write, compiled out of a release build): a history recorded only while the panel
  shows would be empty when one looks.
- `curve`, `curves`, `easing`: a value over time and a transition's easing, in an editor as wide as the panel (keys,
  handles, a playhead on the program's clock). Their design is [curve-editor.md](curve-editor.md).
- `value(label, &x)`: any Odin value by reflection. A struct is a section of its fields; a number, a bool, an enum, a
  string or a small vector is edited; an array or a slice shows `ITEMS_MAX` items and says how many more; a pointer is
  followed `DEPTH_MAX` levels deep; a map, a union, a procedure are watched as text. A field's tag says more:
  `debug:"-"` hides it, `debug:"ro"` shows it read only, `debug:"0..360"` bounds it.
- A string the surface writes is the surface's (its own allocator): it never frees the program's string, and frees its
  own when it writes again or ends.

### Not kept, printed

A tweaked value is not saved: the program's defaults stay in its code. `debug.odin_text(x)` writes a value as Odin
source (`Soldier{model = 2, position = {0, 1.5, 0}}`), what the reference's Print gives, to paste back.

### The tools

The devtools' `Toolkit.debugPanels`, `Toolkit.debugSet {path, value}` and `Toolkit.debugPress {path}` run the List and
Apply passes in `devtools.service`, before the frame's build. A value travels as text, the form the window's field
takes ("1, 2, 3", "#rrggbbaa", an enum's name): one parser for a person and a tool. `tk cdp debug`, `debug-set` and
`debug-press` are the same from a script; `devtools.service` attaches the surface to the window it serves, so every
program a tool drives has the View panel.

A section closed by the person is open to the tools: the Apply and List passes enter every section, so an act inside
one is pressed by its path. A number set by a tool that is not finite (`inf`, `nan`) is refused: it would reach the
program's variable. The commands set values and press the program's own acts: nothing of the surface runs a command,
reads or writes a file. The devtools listen on 127.0.0.1 and only when asked (`TOOLKIT_DEVTOOLS=<port>`): a tool there
has the person's trust.

### Threads

Everything runs on the interface thread: the procedure, its passes, the tools' commands (`devtools.service`). A
worker's state is shown through a snapshot the worker posts (`ui.post`) and the program keeps: the panel reads the
snapshot.

## Cost

- A release build has the window, the View tab, the curve editor and the program's panels, and no devtools' endpoint
  (`tests/lean_build`). About 1.6 MB of the executable ("In every build" below).
- A build with `-define:TOOLKIT_DEBUG_WINDOW=false`: every `debug.*` call has an empty body or returns a constant
  false; `debug.ENABLED` (`ui.DEBUG_WINDOW`) says it. No key is read. `tests/lean_build`'s step `lean_build_bare`
  checks it.
- The window closed: no procedure runs and nothing is allocated; a build reads one key. `tests/debug` counts the
  allocations and bytes of 30 frames with a panel and without.
- The window open: the tab shown builds its rows, as any view builds what it shows. A slice shows a bounded number of
  items.

### In every build

Decided by the owner: the debug window ships in every build, a release included, behind its key. A fault seen in a
release is looked at where it is, not after a debug build, and the View tab's exploded view is worth having there.
Two defines:

- `TOOLKIT_DEBUG_WINDOW` (`ui.DEBUG_WINDOW`, default true in every build): the window, its key, the View tab (the
  wireframe, the exploded view, the frame times, and their keys W and E), the curve editor, the program's panels, and
  `gt:host`'s attach. A program that does not want them builds with `-define:TOOLKIT_DEBUG_WINDOW=false`.
- `TOOLKIT_DEVTOOLS` (default as before: a `-debug` build and a test, or a program's opt-in): the CDP endpoint and its
  tools' commands. A release does not answer a variable of the person's environment.

The cost, measured on `examples/hello` (Linux, `-o:speed`, stripped; hello does not import the devtools, so the
difference is the debug window, its View tab, the curve editor and the wireframe's and exploded view's keys):
34,492,224 bytes without, 36,121,224 with: +1,629,000 bytes (+4.7 %), in every program. A program that imports
`gt:devtools` and opts in adds the server too (about 350 KB, `src/devtools/devtools.odin`). At run time, closed, it
costs a surface per window and one key read per build.

A person who presses the key by chance sees the window open, floating, with the focus in it: the key or Escape closes
it. A program whose own shortcut is the chord keeps it (the key is read last).

Refused:

- **The window behind `TOOLKIT_DEVTOOLS`** (before): a release had neither, and a program that wanted the window in
  its release took the endpoint with it.
- **The debug key read first** (before): it took the press of a program's own shortcut on the same chord, four
  programs' "Compact rows".

## Refused

- **A separate process or a web page** (a window of another toolkit, a page served by the devtools): the object is not
  beside its values, every value crosses a socket, and the program keeps a second interface in another technology.
  The devtools already give the tools the same panels.
- **Values described by a generator**: Odin's reflection gives the fields and their tags at run time; a generator adds
  a build step for what `debug.value` does.
- **Tweaks kept by default**: a value that comes back changed after a restart is a bug that nobody wrote.
