# Changelog

All notable changes to gui_toolkit. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project follows [semantic versioning](https://semver.org); while the version is `0.x`, a minor bump may change the API. The version
is also available in code as `ui.VERSION`. What is not released yet is in `changelog.d/`, not under "Unreleased": two branches never
conflict on this file.

## [0.200.0] - 2026-11-12

### Added
- **`platform.toplevels`, `toplevel_activate`: the session's windows**, other programs' too (their app id, title, focus, minimized), and one brought to the front: Wayland's wlr-foreign-toplevel-management (sway, Hyprland, niri, labwc, ShojiWM); none elsewhere yet.
- **`List_State.no_typeahead`: the letters typed are the program's**: a list with it does not take the letters typed for its type-ahead, so a filter given them by `type_to_field` gets them while the list has the keyboard (a file manager's list).

### Fixed
- **A window whose picture the compositor has not shown yet keeps its timers**: a program's timed work (a sample, a poll) goes on while its window is on a hidden workspace, or on an output with nothing else to draw; it stopped until the compositor showed the window again.
- **An empty state's icon is large**: `ui.empty_state` drew its icon at the text's size, a small mark over the title; it is drawn at 2.4 times the text's size now.
- **A dialog holds the keys of the list behind it**: a list that had the keyboard took Enter, Escape and the arrows while a dialog was open over it, so an Enter that answered the dialog also opened the row behind. A list now reads no key while a dialog it is not in is open.

## [0.199.0] - 2026-11-12

### Added
- **`ui.empty_state`: what a view shows when it has nothing to show**: in the middle of the view, an icon in the weak colour, a title, a note, and a button for each thing that can be done about it (the action clicked is returned).

### Fixed
- **A box in a rounded corner takes that corner**: a title bar's background, a header or any box that fills the corner of a rounded box around it (a dialog, a card, a menu) is rounded there too (`box_drawn_radii`): its square corner showed outside the rounded one. And every widget's own drawing (`rad`, the colour pickers, the tiles, the floating panels' clip) is square under 3 px, as the boxes are (`radius_drawn`).

## [0.197.4] - 2026-11-12

### Fixed
- **The clipboard with no window on Windows**: `get_clipboard` and `set_clipboard` given no window read nothing and write nothing, as on Linux; they crashed.

## [0.198.0] - 2026-11-12

### Added
- **`process.Signal`: `Quit`, `User1`, `User2`** (SIGQUIT, SIGUSR1, SIGUSR2): what a program's "Send signal" menu offers besides the others.
- **`dialog_top_draw`: a strip across the top of a dialog** (a title, a search field), as a box's custom draw: its `bg` (else a field's darker background), the dialog's top corners as drawn (`DIALOG_RADIUS_EM`), inside its rim, a line under it. The command palette's field uses it.

### Fixed
- **A corner rounded at under 3 px is square**: with a program's little rounding a dialog's corner was rounded at two pixels and a half, and its antialiasing made a blob outside the corner of its 1 px edge (`ROUND_LEAST_PX`).
- **A raised panel's frame over what is in it** (machined and edged finishes): a dialog's lit rim and edge were drawn under its content, so a title's background or a tab's line covered them along one side and not the next. The frame is drawn after the panel's children (`machined_plate_frame`).
- **A window at rest sleeps again on Wayland**: since 0.196.0 the compositor's word that it showed a picture asked for a repaint each time, so a window at rest drew a new picture at every refresh, for ever (a core kept busy). The word now asks for a repaint only when a picture waited for it (`platform.frame_shown_held`, which host calls); a covered window still draws its picture when it is shown again.

## [0.197.3] - 2026-11-12

### Changed
- **A scroll bar held stays grey**: its thumb a step further toward the text than under the pointer, not the accent (too much accent in the window).

## [0.197.2] - 2026-11-12

### Added
- **`ui.confirm`: the question before an act that is not taken back**: a title, a note, what it acts on a line each (the others counted), Cancel and the act's button in the danger colours; Enter answers what is safe (Cancel, or the act with `enter_confirms`) and its button says "(Enter)"; it answers `.Confirmed` or `.Cancelled`. Its own words are in `Confirm_Labels`.

### Changed
- **A scroll bar in the interface's colours**: its thumb a surface's border at rest, the weak text under the pointer, the accent while held, its track the theme's track, with a rim a little toward the text (every finish but Flat). The text's light, up to 55 %, made it near white on a dark theme.

## [0.197.1] - 2026-11-12

### Changed
- **A scroll bar's thumb looks like a thing to take**: a rim a little stronger than its face, and three grip lines across its middle cut in the background's colour (on a thumb long enough to hold them), in every finish but Flat.

## [0.197.0] - 2026-11-12

### Added
- **`scrollbar_under(box, point)`**: which bar of a box takes a press at a point (the one shown, a little wider toward the content), for a program that hears the pointer before the interface and leaves that press to the bar (a terminal's grid in a box that scrolls).

### Fixed
- **A menu's search is a field and the menu holds still**: what is typed in a menu opened with `search` is edited with a field's keys (`ui.field_key`, which `line_edit` uses too): Ctrl+A, Backspace on the selection, Ctrl+Backspace for a word, the caret moved by the arrows once something is typed, a paste. While it filters, the menu keeps the corner and the width of its first layout: it no longer narrows at each letter or moves from under the pointer.

## [0.196.3] - 2026-11-12

### Fixed
- **`label_fuzzy`'s matches are readable**: lit on the theme's `match_bg`, as a list's and the palette's are; 30 % of the accent, blended in linear light, made a chip too light for the text on it.

## [0.196.2] - 2026-11-11

### Fixed
- **The command palette's field strip has the dialog's corners**: it was rounded at the theme's radius whatever the program's rounding, so a dialog with square or little rounded corners showed a second, rounder corner inside its own. `box_drawn_radius` gives a custom draw the corners a box is drawn with.

## [0.196.1] - 2026-11-11

### Changed
- **`flate` and `png.decode` are faster**: `flate.deflate` takes a quarter to a third less time and `flate.inflate` gives 1.3 to 2 times its rate, for the same bytes. `png.decode` of an 8-bit RGBA picture takes less than half its time. `render.readback_poll` of a linear target moves opaque pixels 4 at once, as it does for an sRGB target.
- **Reading pixels back is faster**: a capture of the frame and `render.readback_poll` of an sRGB target move opaque pixels 4 at once (about 5 times less time for the capture, about 20 times for an opaque readback). The pixels are the same.
- **`png.encode` and `flate.deflate` are faster**: `.Small` writes a 1400 x 925 screenshot in about 30 ms where it took about 95 ms, and `flate.deflate` takes about half its time on pictures. The filters of a row and the bytes of a match are compared 16 at once (SSE, NEON). A row with bytes of value 128 can take another filter than before: such a file differs by a few bytes, and reads back to the same pixels.

## [0.196.0] - 2026-11-11

### Fixed
- **A window the compositor does not show no longer freezes its program** (Wayland): a picture presented in Fifo waited for the compositor's word that it showed the last one, which a covered window never gets, so a program whose main window another of its windows covered whole stopped answering. A window now presents a picture only once the last one was shown (`platform.frame_shown_pending`, `frame_shown_ask`); while it waits it reads its input and draws nothing, and the word asks for the next picture.

## [0.195.1] - 2026-11-11

### Changed
- **The command palette as in opencode native**: a magnifier before its field and the number of results at the end of the line, a carved line under the field, and the selected line sunk in a well with a bar of the accent at its left, its text in the theme's own colour (it was a raised face of the accent, the text on it hard to read).

### Fixed
- **What a search found is readable**: it is drawn in the text's own colour on the tint of the accent (theme `match`); the accent's colour on its own tint read badly, worst on a dark theme. This is true in the palette, a list, and a table's filter.

## [0.195.0] - 2026-11-11

### Added
- **A table lights what its filter matches**: each word of `Table_Layout.highlight` in the cells, in the theme's `match` on `match_bg`; `table_apply` sets it to the filter, a program that builds its rows sets it.
- **A table's header menu** (`table_menu_items`): the right-clicked column back to its own width and unsorted (`table_column_reset`, `Table_Layout.menu_column`), the rows unsorted, the columns shown, the default columns; its words in `Table_Menu_Labels`.

### Fixed
- **A table read again stays where it was scrolled**: `table_apply` brought the selected row back into view at each new reading with no filter, so a list refreshed every second could not be scrolled away from it. Only a filter cleared brings it now.

## [0.194.0] - 2026-11-11

### Added
- **`palette_match`: how a palette ranks one entry**, for a program with a palette of its own: its label whole or at the starts of its words, then its tags, then its group, then the same with a slip or two (`fuzzy_typos`); its score and what lights in its label. The command palette uses it.

## [0.193.0] - 2026-11-11

### Added
- **`fuzzy_typos`: a word typed with a slip still finds its word** (a letter missing, one too many, one for another, two swapped; none in a word of three letters, one up to six, two beyond), whole or its beginning: "Qestart pencode" finds "Restart opencode native". The command palette tries it after every exact match, on the label then with the tags, and lights the words it found.

## [0.192.3] - 2026-11-11

### Fixed
- **The command palette keeps its edge along its field**: the field's darker strip began on the dialog's lit rim (machined and edged finishes), so the dialog's edge showed only at its corners. The strip now begins inside it.

## [0.192.2] - 2026-11-11

### Fixed
- **All of a resize grip's bevel is its corner**: the pointer on the bevel's upper part, past the corner's size, showed the bottom or the right edge's cursor and took that edge; it now has the corner's cursor and resizes from the corner (a dialog's grip, a floating panel's).

## [0.192.1] - 2026-11-11

### Changed
- **The command palette's field has the darker background of a field**: still from edge to edge, with no frame of its own, its strip now reads as the place to type. Its top corners follow the dialog's.

## [0.192.0] - 2026-11-11

### Added
- **A dock's panel in a window of its own** (`Dock_Options.windows`): the menu's *Open in a window* lets the panel go as a close does, `Dock_Result.windowed` names it, and the program opens the window and builds the panel there; `dock_add` brings it back when the window closes.

## [0.191.1] - 2026-11-11

### Fixed
- **A `strip_grid` line scrolls with a mouse's wheel**: over a line that is cut, the wheel turned the usual way scrolls it sideways (it went to the page, and only a wheel turned sideways or a touchpad moved the line). A line that holds all its cells leaves the wheel to the page.
- **A box that fills its parent fills it under a box that scrolls sideways too**: under a box with `Allow_Overflow_X` (a table's titles, its rows), a `fill()` kept the size its parent had before an ancestor shrank, the window's width: a table beside a sidebar was as wide as the window and scrolled for nothing.

## [0.191.0] - 2026-11-11

### Added
- **`tk_changelog.with_badge`**: a README's version badge (shields.io) and its alt text set to a version, for a program's `set_version` (it was the toolkit's own tool's).
- **`Table_Column.descending_first`**: a column of text sorted from the largest at its first click, as a number is (a date: the newest first).
- **A table's header holds the program's own pieces**: `Table_Header_Options` builds a lead before the first title (a box that checks every row) and a piece in each title (a filter's funnel, shown while the pointer is on it); `Table_Column.unsorted` marks a column whose title sorts nothing (a count beside the sizes).
- **In the edged finish a dock's stack is a window**: its strip is a title, the accent fading out from its left, lit where the keyboard's focus is and dimmed toward the bar elsewhere (`caption_face(..., lit)`).
- **`section_header(..., inline = true)`**: as wide as its words, for a header in a row with other things (the keys a panel answers, a button).
- **`strip_grid`: a strip that opens into a grid**: its cells on one line that scrolls sideways; "Show all" under it lays them out as a grid wrapped to the width, "Show fewer" folds them back. The button is there only when the line does not hold them all.
- **`Palette_Options`**: a program's palette shows the commands run last on top, puts a command first while searching (an alias typed whole), shows its own text of each command's keys (its user's keys, a sequence) and a foot line; Ctrl, Alt or Shift with Enter chooses too (`Command_Palette.chosen_mods`), for what else the program does with the command.
- **`cli`: a program's command line from one table of its options**: `cli.check` answers `--help` with the help made from the table and `--version` with the version, and refuses an option the table does not have (why, then the help; exit code 2), so a typo or a guess no longer starts the program as if nothing was said. Options take a value (`--session=<id>`), an optional one (`--settings[=<n>]`), one in the next argument (`--pref <name=value>`), or are hidden (what tools pass). The help lists the options by group, then examples, the environment the program reads, and its files.

### Changed
- **A table's tinted cell is square** (`table_cell` with `bg`), whatever radius the style has: it is part of its row, as the rows are.
- **The Console theme is named Kernel**: the name of what it comes from. A program that stored "Console" finds no theme of that name.
- **A row is square**: a row of a list, of a table or of a menu has no rounded corners, whatever radius the style around it has: a selected row's fill runs from edge to edge, row under row.
- **An offscreen renderer does not pre-warm** (WebGPU): it makes a pipeline when it first draws with it. Pre-warmed, each one compiled all eight pipelines on a thread and `destroy` waited for them, used or not: every test session paid them, and on WARP the slowest CI packages spent most of their time there (`subpixel_slug` and `scenarios`: 48 s to 30 s on a GPU). A window's renderer still pre-warms: its start hides the compiles. `TOOLKIT_WGPU_PREWARM` is gone.

### Fixed
- **A wheel turned up past the top no longer glides over what comes above it**: content inserted above the view while it heads for a top it was stopped at (a page read before the first, a lazy column) carries that stop along, as any other place. A view sent to the start as such goes there with the new `view_top` (Home), and still ends at the start whatever comes above.
- **A test run by `unwatched.run` keeps its name in `build/session/`**: its folder had the anonymous body's procedure name ("pkg::test$anon-pkg:file.odin:123"), so a tool that looks for a test's pictures by its name found none.
- **`changelog.new_fragment` with no root writes in the current folder**: it wrote `/changelog.d`, at the root of the disk, and refused the fragment it could not read back ("it is empty").

## [0.190.2] - 2026-11-11

### Fixed
- **A dialog closed by its own button gives the keys back at once**: the first key after the click (Escape, a shortcut) went nowhere when no frame came between them, held by a dialog no longer there (0.189.1).

## [0.190.1] - 2026-11-11

### Fixed
- **`release.notes` and `release.ship` find a changelog named `CHANGELOG.md` without a folder**: they looked for it at the root of the disk (0.190.0).

## [0.190.0] - 2026-11-11

### Added
- **`gt:changelog`**: a project's CHANGELOG made of fragments, one file per change in `changelog.d/`, as the toolkit's own. `release.ship` now assembles the fragments into the version's section and deletes them, instead of renaming `[Unreleased]`; it refuses a malformed fragment and a release with nothing in it. A hand-written `[Unreleased]` section is assembled too, after the fragments, and removed. `release.changelog_release` and `release.changelog_section` are gone: `changelog.assemble` and `changelog.section` replace them.

## [0.189.1] - 2026-11-11

### Fixed
- **An open dialog holds the keys**: code built outside it gets no key from `key_press`, `key_take`, `key_pressed_peek` or `command_pressed` while it is open. A program reads its keys before it builds its dialogs: Escape in a dialog opened from the palette closed the window behind it instead. `ui.set_keys_behind_dialogs(&state, true)` turns it off; `ui.dialog_open()` says whether one is open.

## [0.189.0] - 2026-11-11

### Added
- **`ui.key_held(key)`**: whether a key is held now, from its press in the window to its release, by its own events (not by the modifiers' state, which a compositor may leave stale); none once the user left the window. Ctrl held alone, for a monitor that stops its refresh while it is.

## [0.188.0] - 2026-11-11

### Added
- **A table's columns moved by their titles**: a title dragged sideways moves its column (the first stays first), a line in the accent's colour where it will go; `Table_Layout.order`, `table_layout_move`, `table_order_text` / `table_order_apply` to keep the order (columns added since stay where they are); `Table_Header_Events.moved`, `Table_Events.moved`.

### Changed
- **A table's third click leaves its rows unsorted**: the data's own order (`TABLE_UNSORTED`, `none` in `table_sort_text`), not the table's first sort; `Table_Layout.default_sort` and `default_descending` are gone. `Table.order` (the rows shown) is `Table.rows`.

## [0.187.2] - 2026-11-11

### Fixed
- Linux: **a portal that answers "no preference" for the colour scheme no longer makes the system light**: the GTK settings (`gtk-application-prefer-dark-theme`, a dark `GTK_THEME` or theme name) decide then, as with no portal. A session whose portal has no backend for it answers 0; a program following the system showed its light version, and the machined finish flat.

## [0.187.1] - 2026-11-11

### Fixed
- `ui.preview` fits its content from its very first frame: what fits was worked out from last frame's size of the box, none for a box new this frame, and a picture showed at its pixels, too large and off centre, for a frame.

## [0.187.0] - 2026-11-11

### Added
- **A title bar in the finish shown**: `caption_face(dc, r, top, bottom)` paints a title bar's face: in the edged finish the accent fading out from the left with its hairlines (the console's window), in the machined one a shaded face, flat one colour. `caption_ink(c)` is the colour words take on it. In the edged finish the window's close button is a red block, at rest too.
- **The system's title bar, by choice**: `platform.system_title_available(w)` says whether the system can draw a window's title bar (Windows, X11, a Wayland compositor with server-side decorations such as KDE; not GNOME). A program offers it as a preference and switches with `set_integrated_title` at any time; `ui.window_buttons` draws nothing while the title bar is the system's. The test sessions take `integrated_title`.
- **The edged finish and the Console theme**: `Finish.Edged` draws the machined reliefs crisp, nothing blurred: a dark hairline around a face, a lit line along its top, a shade along its bottom; a well with dark lines under its top and a lit lip; a panel (a dialog, a menu) outlined all around in its border's colour, lit; square corners, except what is round by its shape (a radio, a switch, a slider's knob: `shape_rad`). `Console` (blue black, the hues of a console) is made for it. With them, pieces of a dense dashboard: `section_header` (a stripe, a title in capitals in its hue, a note, a value), `tile` (a tile of colour with its words), `stacked_bar` (a bar cut in parts with their words), `title_strip` (a title on the accent fading out, a red block that closes), `hue(.Cyan)` (the hues of the theme shown) and `relief_face`.

### Fixed
- **A renderer that ends waits for the GPU**: `render.destroy` lets the GPU finish what it was given first (Direct3D 11: an event query; WebGPU: a poll that waits). An offscreen frame is only flushed, and a renderer released while WARP still drew it could end the process.
- **A widget's bold is the family's own** (a toast's title, a section's name, segmented in words): `ui.styled_face(face, bold, italic)` (`styled_face_of(state, ...)` outside a build) gives the face the program declared for that family, else the system's family, else a simulated one. The widgets asked `font.styled_face`, which simulated the bold of an embedded face: its strokes thickened by an algorithm, the bar of an e lost its join at small sizes. `rich_set_faces` is now `set_family` (it serves every widget, not rich text alone), and `State.rich_faces` is `families`.
- **`fsx.read_all` never gives the start of a larger file**: it read between two stats of the name that agreed, and on Windows a file replaced twice within one tick of the clock had the size and the time of the first, so the first part of the larger one between came back. It reads through one open file now (its size and its bytes of that file, whatever takes its name meanwhile). The test's writer gives every file one time, so it fails on every system without the fix.

## [0.186.0] - 2026-11-11

### Added
- `prefs_page.update_badge`: the Updater's state as a button of a program's status bar: Install, Downloading, Restart to update. **Machined: wells and keys are filled shapes from the outside in** (the lit rim, the dark edge, the surface): at a small scale their rings were strokes side by side, broken in the curves, their greys changing along them.

## [0.185.0] - 2026-11-11

### Added
- `prefs_page.Options.version`: the program and its version ("Papier 0.15.0") at the bottom of the settings' pages.

## [0.184.0] - 2026-11-11

### Added
- **What a search found, lit**: a line of a filtered list shows the parts that match in the theme's `match` colour on its `match_bg` (`ui.word_ranges`, `ui.match_runs`, `ui.matched_label`). The palette, a menu that searches and a settings page's search do it.

## [0.183.0] - 2026-11-11

### Added
- **Tags**: `config.Def.tags` and `ui.Command.tags`, other words a setting or a command is found by ("colours" and "dark" for a theme, "exit" for Quit). The settings' search reads a preference's tags; the palette a command's, a match of them after one of its label; `prefs_page.palette_commands` gives a setting's line its preference's tags.

## [0.182.0] - 2026-11-11

### Added
- **The settings in the command palette**: `prefs_page.palette_commands` gives one command per preference the pages show (its title, under `Settings · <page>`), and `prefs_page.show` opens the page on the one chosen, alone, its page underneath.

## [0.181.0] - 2026-11-11

### Added
- **A toast is as tall as its words, and may have a title**: its text goes on to the next lines inside it instead of past its edge, and the stack places each by its height. `toast_titled(kind, title, body, action, user)`: the title bold on its line (cut with "…"), the text under it.
- **`segmented(look = .Text)`**: a segmented control in words, as wide as they are, `separator` between them ("All / Active 2 / Done 1"); the chosen word bold and underlined, the others weak until the pointer is on them.

### Fixed
- **A thin ring's rounded corners are as heavy as its sides**: blended in linear light, the pixels a curve cuts were paler than a browser draws them (a 1 px border looked thinner in its corners). `draw.rect` and `draw.rect_corners` take the `backdrop` a ring is drawn over; its edge then blends as in sRGB values. A box's border gives its own: the colour under it (`box_under`).

## [0.180.3] - 2026-11-11

### Fixed
- `ui.preview`'s bar is as wide as what it holds: at a fixed width its last button went past its edge.

## [0.180.2] - 2026-11-11

### Fixed
- **A segmented control's labels are centred on their key**: they were laid out on the whole track while the key slides on the track less its padding, each a little further right of its key than the one before.

## [0.180.1] - 2026-11-11

### Fixed
- `ui.preview`'s bar shows its zoom in percent: the label had a fill width beside the buttons and got none of it.

## [0.180.0] - 2026-11-11

### Added
- **`ui.preview`** and **`ui.preview_image`**: content (a picture, a page, a diagram) that fits its box, then zooms with the wheel around the pointer, moves with a drag, goes to its pixels and back with a double click, answers +, −, 0 and the arrows; a bar over its corner (`Preview_Options.buttons`) shows the zoom and −, +, 1:1, Fit. docs/preview.md.

### Changed
- **Machined: a segmented control is a slot with a key in it**: the track carved in the surface (`machined_well`), grooves between its segments, the chosen one a raised metal key, in the text's colour, its corners rounded. **A switch's channel and knob lie on whole device pixels**, and **a well's surface stops inside its edge**: a lit colour (a switch that is on) no longer spills onto the rim around the opening.

## [0.179.0] - 2026-11-11

### Changed
- **Machined: a segmented control is a slot with a key in it**: the track carved in the surface (`machined_well`), grooves between its segments, the chosen one a raised metal key with a small light of the accent under its label (`machined_light`), in the text's colour. **A switch's channel and knob lie on whole device pixels**: their 1 px rims no longer step along the curves.

## [0.178.0] - 2026-11-11

### Fixed
- **A check box or a radio whose label wraps** had its mark at the top of its row, above the middle of its first line (Setup's "Shortcut on the Desktop"): the mark is now centered on the first line, as on a row of one line.

## [0.177.1] - 2026-11-11

### Added
- `Box_Flag.Scrollbar_None`: a scroll box that shows no bar (a table's titles, which follow the rows' sideways scroll).

## [0.177.0] - 2026-11-11

### Changed
- **Tables as in a file manager**: a column's rule is at its right edge and resizes that column, the columns after it move (the fill column takes its width at the first drag; the table then scrolls); a third click on a title comes back to the table's own sort (`table_sort_click`). **A horizontal scroll bar** for every box that scrolls sideways (`View_Scroll_X`), along its bottom edge.
- **The palette's field is flush with its edges**, on a strip with a line under it; the commands' keys stay clear of the scroll bar.

## [0.176.1] - 2026-11-11

### Fixed
- **The command palette no longer crashes on a search that keeps nothing**: it brought line 0 of an empty list into view.

## [0.176.0] - 2026-11-11

### Fixed
- `syntax.guess` finds Odin written as `proc name(...)`, with no `::` nor `:=` in it.

## [0.175.1] - 2026-11-11

### Fixed
- **A second window never waits for the screen** (`render.set_present_wait`, set by `host` for every window but the first): on Wayland a Fifo present waited for a frame callback the compositor never sent to a window it did not show, and froze every window of the thread. Its frames now go out in a mailbox (else with tearing).

## [0.175.0] - 2026-11-11

### Added
- **Code in the theme's colours**: `ui.code_runs` (runs for `rich_paragraph`) and `ui.code_highlight` (a `text_edit`'s highlight) colour tk_syntax's classes with the theme's new entries `code_keyword`, `code_string`, `code_comment`, `code_func` and `code_type`. A `Palette` carries the theme's other hues (`blue`, `purple`, `cyan`, `rose`).

## [0.174.0] - 2026-11-11

### Added
- **`syntax.guess`**: the language of a text with no name (a copy, a paste): its `#!` line, JSON, or the language whose `signs` and keywords it holds the most of, only for a text with the punctuation of code (prose, addresses and paths are none). **SQL** (`Language.fold_case`: keywords in any case).

### Changed
- **Middle-click autoscroll is on by default**: every scroll region of every program (`scroll_y`, lists, tables, a vlist) takes a click of the wheel and scrolls by the pointer, as in the browsers. A program whose middle button does something else calls `ui.set_autoscroll_enabled(&state, false)`.

## [0.173.0] - 2026-11-11

### Added
- **`line_edit(clearable = true)`**: while it holds text, a cross at its end empties it; the field keeps the keyboard, and Undo brings the text back.

### Fixed
- **A menu, a tooltip, a popover or a dialog built from inside a field is one of its own**: it wore the tags around it ("input floating"), and a field's menu was drawn with a field's see-through background (`push_tags_isolated`, `pop_tags_isolated`). A menu takes the window's style, not the field's.

## [0.172.0] - 2026-11-11

### Added
- **`platform.drop_types`**: the MIME types a drag over the window offers, from its enter on. On Linux the data is read only at the drop: a target judges a drop of a program's own format by its types (it refused it before).

### Changed
- **The command palette is a dialog the user resizes** (`Command_Palette`, `palette_open(&p)`, `palette(&p, commands, enabled) -> (chosen, resized)`): `modal_sized` with its corner's grip, `PALETTE_WIDTH_EM` by `PALETTE_HEIGHT_EM` at first, its size the program's to keep; a command's `icon` before its label. **A table narrower than its columns scrolls sideways** (`table_min_width`, `table_scroll_sync`; `table_build` does it); `Size.least` is a floor of the resolved size too.

## [0.171.0] - 2026-11-10

### Added
- **A text field's menu**: a right click on a `line_edit` opens Undo, Redo, Cut, Copy, Paste, Delete and Select all, each with its keys and its icon (`ui.field_menu`; a secret's neither copies nor cuts; `menu = false`: the program has its own). **`menu_item` takes `icon_font`**: an item's icon may be a character of any face (0: `State.icon_font`), so a menu of the toolkit's draws Lucide's whatever the program's icons are.

## [0.170.0] - 2026-11-10

### Fixed
- **A Mermaid gantt chart's section names** sat on the left edge of their band (mermaid-svg sets them there, its whole padding after them): `gt_mermaid` moves them half that padding in.

## [0.169.0] - 2026-11-10

### Fixed
- **A Mermaid gantt chart in `dateFormat X` or `x`** (seconds or milliseconds since 1970, as a model writes the timing of calls) was refused: "cannot parse task end". mermaid-svg reads no such format: `gt_mermaid` gives it the chart with its dates written as `YYYY-MM-DD HH:mm:ss` (UTC), its directives, ids and durations as they were.
- **Resizing a table's column no longer moves the columns after the fill column a frame late.** The fill column took the header's width of the last build: it is now `fill_least` (`Size.least`: a size the layout never shrinks under), resolved in the build it is in. A list's stripes are fainter again (0.8 %).

## [0.168.0] - 2026-11-10

### Added
- **`lucide`: twelve more icons** for a program's menus: `ARCHIVE`, `ARCHIVE_RESTORE`, `CALENDAR_CLOCK`, `CLIPBOARD_COPY`, `FILE_DIFF`, `FILE_DOWN`, `HASH`, `LOG_OUT`, `MESSAGE_SQUARE_QUOTE`, `QUOTE`, `SERVER`, `TEXT_QUOTE`. docs/lucide.md says how a program draws its own icons, from a font of its own, with no constant in the toolkit.

### Fixed
- **`archive.kind_of` and `syntax.language_of_file`** fold a file's extension by ASCII (`ascii.lower`), as the toolkit's rule wants for names (`unicode_case` failed on them). The test of the launcher's activation token builds with `-vet` on Windows.

## [0.165.1] - 2026-11-10

### Changed
- **A list's stripes are fainter**: every second row 1.5 % toward the theme's tint, from 3 %: the stripes guide the eye across a line without drawing it.

### Fixed
- **`archive`**: an entry named with a `.` or `..` part or a drive is left out of the index (a copy of a folder out of a malicious archive made folders outside its destination); `find` looks entries up by name.

## [0.167.0] - 2026-11-10

### Fixed
- **`testkit/unwatched` builds with `-vet` off Windows**: its Windows code and imports are in `unwatched_windows.odin`; a program whose tests import it no longer stops on unused imports there.

## [0.166.0] - 2026-11-10

### Added
- **`platform.activation_token_from_env`** and **`platform.raise_window_token`**: a second start hands the token its launcher gave it (XDG_ACTIVATION_TOKEN, DESKTOP_STARTUP_ID) to the first, whose window comes up with it on Wayland.
- **`syntax`**: the colours of source code as runs of classes (`spans`, `language`, `language_of_file`), the site's lexer made a package of its own; Python, Go, TypeScript and the shell coloured too. `site.Code_Language` is `syntax.Language`.
- **`archive`**: what a zip, a tar or a gzipped tar holds (`open`, `children`, `find`), a file of it read or extracted (`read`, `extract`; a name that would leave its folder refused). Read only, pure Odin.
- **`testkit/unwatched`** (was `tests/unwatched`, the toolkit's own): a test's body on a thread the runner of `core:testing` does not watch, for a program's tests on Windows. There the runner fails a test on any exception of its thread, even one DirectWrite, Direct3D or DXGI raises and catches itself ("Signal caught: Unknown", now and then). `unwatched.run` now also does the body's `testing.cleanup`s on its thread when it returns: a window or a testkit session made in the body ends on the thread that made it. docs/testkit.md.

## [0.165.0] - 2026-11-10

### Added
- **`prefs_page.Options.preview`**: each value a held slider moves to, for the program to show at once; the preference is still written at the release.

### Changed
- **Machined: a graph with a grid is a well, a meter bar a slot** (`line_graph`, `meter_bar`): a screen set in the surface, a run lit in a carved slot.

## [0.164.0] - 2026-11-10

### Changed
- **The Gradient finish is a shade, the Machined one a relief everywhere.** Gradient: a face a few percent lighter at its top than at its bottom and a fine lit line, no white gloss nor engraved text (the text reads as on the plain colour). Machined: cards, dialogs, menus and tooltips are plates (`Box_Flag.Plate`); check boxes, radios, switches, sliders and progress bars are wells with a raised key or a lit face in them; buttons' bevels are stronger; an accent fill (`paint_rect`) is a lit face; the light engraving under dark text is fainter. `tk finish_shots` pictures fidget's pages in each finish; fidget takes `--finish=name`.

## [0.163.0] - 2026-11-10

### Added
- **`release.Config.update`**: a program that updates itself; `package_` writes the program alone and its manifest signed by `$UPDATE_SIGNING_KEY` beside the archive (a release without the key is refused).

### Fixed
- **Setup, a copy of the Nix store beside what an earlier install left**: it read as "To repair", with "The installed program is missing" in red, when an icon or a menu entry of an earlier install was left. A copy of the Nix store with no installed copy is now the Nix package's (`State.Nix_Package`, `setup.state_of`): the screen says an earlier install left files, and offers only to remove them ("Remove what is left"), never a repair that would install this copy beside the package. `setup.leftover` says when something is left.

## [0.162.0] - 2026-11-10

### Added
- `paint.rgba_shrink`: RGBA8 bytes shrunk without a canvas, each pixel the alpha-weighted average of what it covers, for a thumbnail of a large picture.

## [0.161.0] - 2026-11-10

### Added
- **`warn_button`**, beside `accent_button` and `danger_button`: the warning hue behind black text, for an action done with care (end a task, stop a service). docs/themes.md lists the button variants.

## [0.160.0] - 2026-11-10

### Fixed
- **A table's fill column keeps `TABLE_FILL_MIN_EM`** (`ui.table_width`): in a window too narrow for its columns, the last columns go past the edge, cut, instead of the fill column going to nothing under its neighbours' text.

## [0.159.2] - 2026-11-10

### Fixed
- **`ui.type_to_field`** takes an input method's text again right after a shortcut: only the modifiers of the frame's own key presses count (`State.typed_mods`).

## [0.159.1] - 2026-11-10

### Fixed
- **`ui.type_to_field`** no longer takes a shortcut's letter: Alt+P gives the text "p" too, which went to the filter instead of the shortcut.

## [0.159.0] - 2026-11-10

### Added
- **Stripes, rules and tints of a list's rows**: `List_State.zebra` and `.rules` (every second row shaded, a hairline under each), `list_row`'s `tint`, `table_cell`'s `border` (a busy cell's outline); `animations_on` and `keep_animating` for a program's own motion.

## [0.158.0] - 2026-11-10

### Added
- **`ui.table_cell` takes `fg`**, the colour of its text, beside `bg`: a cell tinted by its value keeps a text that reads on it.

## [0.157.0] - 2026-11-10

### Changed
- `platform.move_to_active_monitor(w, follow)`: the monitor under the pointer by default (`.Pointer`: a pointer moved to another monitor is followed with no click), or the one of the window in front (`.Focus`). `active_monitor_parse` reads "pointer" or "focus".

## [0.156.0] - 2026-11-10

### Fixed
- **`prefs_page`**: a slider dragged and let go keeps its value. `ui.slider` moves its value only while the button is down, and the page read the preference again at the release: what was dragged was never written, and the slider went back. The page now keeps the value while the button is down and writes it when it comes up.

## [0.155.0] - 2026-11-10

### Added
- **`config.words_match`: phrases**: words between double quotes are one, spaces and all (`"Session 2"` is not in "Session 12"); a quote left open runs to the end of the query. The settings' search has them too.

## [0.154.0] - 2026-11-10

### Added
- **`config.words_match(query, fields..)`**: whether every word of a query is in one of several fields, in any case: a search over a thing's title, id and folder at once. `config.matches` (a preference's search) uses it.

## [0.153.0] - 2026-11-10

### Added
- **`svg.raster`**: a drawing made into pixels on the CPU (a `paint.Canvas`), where no frame is drawn: a diagram to copy as a picture or to save as a PNG file. Its shapes, dashes and markers are those `svg.draw_doc` draws; its texts are filled from the outlines of the program's faces.

## [0.152.0] - 2026-11-10

### Fixed
- **`desktop.watch_start` on Linux**: a place made in the moment between the failed watch of it and the watch of its parent (its CREATE came before that watch) was not followed: once an ancestor is watched, the next directory toward the place is looked for, and the place settles one level down when it is there. (`watch_follows_places_that_come_and_go` failed now and then.)

## [0.151.0] - 2026-11-10

### Added
- `site`: the home page's download for the reader's system (`Changelog_Options.downloads`): `<!-- download -->` becomes one button per system, the reader's shown by a script of the page (the first when it is not known), and `<!-- download-others -->` a line that offers the others.

## [0.150.0] - 2026-11-10

### Added
- `platform.move_to_active_monitor`: a window goes to the monitor the user works on (the one of the window in front, else under the pointer), at the same place of its work area (`rect_on_work`), before a program called up by a shortcut shows it. Windows.

### Fixed
- `setup` dialog: one option per line, its tile as tall as its label: a long label wraps in it instead of running past its edge.

## [0.149.0] - 2026-11-10

### Added
- **Diagrams: the `svg` and `mermaid` packages** (docs/diagrams.md). `svg.parse` reads a drawing in SVG (paths and every command of them, rects, circles, ellipses, lines, polygons, texts and tspans, markers, transforms, fills, strokes, dashes, opacities, the style attribute) and `svg.draw_doc` draws it with the toolkit's paths and fonts, at any scale. `mermaid.diagram` lays out a Mermaid diagram's text (flowchart, sequence, class, state, ER, gantt, pie, mindmap, timeline, git graph...) through mermaid-svg in native/mermaid (`tools/tk build_mermaid`, about 1 MB; `-define:MERMAID_NATIVE_LINK=false` for a program that builds `gt_mermaid` into its own Rust library) and gives that drawing.

## [0.148.0] - 2026-11-10

### Added
- **`platform.placement_text`, `placement_parse`**: a window's placement as a preference's text ("120 80 1400 900", "maximized" after it) and back, so that a program opens its window where it was, on the monitor it was on (`set_placement` brings it onto one that is there).

## [0.147.0] - 2026-11-10

### Added
- `setup.updated(cfg, version)`: after the Updater put a new program in place of the installed copy, its install manifest and the system's record (Settings > Apps) say the new version.

## [0.146.0] - 2026-11-10

### Added
- `prefs_page`: `Options.updater` and `update_pref` show a program's Updater under the line of its update preference: its state in words, Check now, Install when a version is on offer, Restart now (`Options.restart`) when one is installed. `update.status_words` says a state in a sentence.

## [0.145.1] - 2026-11-10

### Fixed
- `toolbox.update_command keygen` writes a key outside a work tree: it refused every path (the key's file, which does not exist yet, was looked up to make its absolute path).

## [0.145.0] - 2026-11-10

### Added
- **`update.Updater`**: a program updates itself. A thread of its own checks the release a while after the start and then every day, downloads the program it names, checks it against the signed manifest and puts it in place; automatic or offered (`check_now`, `install_now`), its state in `update.status`, the program told of each change (`news`). A copy from the Nix store is left to its package manager.
  - **`gt:http`** (`tk_http`): one GET over HTTP or HTTPS with what the system has (WinHTTP; libcurl loaded at run time on Linux), redirects followed, the body bounded.
  - `toolbox.update_command`: the `update` command of a project's tool (keygen, pubkey, the signed manifest of a release, verify), for its product; `toolbox.update_manifest` for a release step.

## [0.144.0] - 2026-11-10

### Added
- **`ui.line_edit`'s `reveal`**: a secret field (a password) with an eye at its end that shows the text and hides it again (`reveal: ^bool`, kept by the program); shown, it is text, copied as any other; the field keeps the keyboard. **`ui.lucide_icons`**: the lucide package's face, loaded when first needed, for the marks the toolkit's own icon font has not.

## [0.143.0] - 2026-11-10

### Added
- **`toolbox.write_logo`**: the files a program makes from its logo, from its drawing (a proc that gives a canvas of a size): the PNG sizes, the `.ico` of its Windows executable (PNG entries, or DIBs below a size), the project's picture (`.project/image.png`).
  - `toolbox.version_header` and `write_version_header`: the C header (`VER_MAJOR`, `VER_MINOR`, `VER_PATCH`, `VER_STRING`) a Windows executable's `.rc` includes for its VERSIONINFO, written only when it changes.
  - `toolbox.exe_has_icon` (Windows): an executable carries its icon group 1.

## [0.142.0] - 2026-11-10

### Added
- **`ui.hotkey_field`**: a field that records a key combination from the keys pressed (a click, then the keys; Escape gives it up), for a program's shortcut. `ui.hotkey_recording` says when one records (a program lets its global hotkey go then).
  - `platform.Hotkey.char`: a key named by the character it types on the user's layout, when Key has none (the French ù): read and written by `hotkey_parse` and `hotkey_text`, registered on Windows (`VkKeyScanW`), sent on Wayland (its keysym `U00F9`, `keysym_of`).
  - `platform.Event.char`: a `Key_Press` of a key Key does not name comes with the character it types with no modifier (Windows, Wayland). `ui.key_take` gives a `platform.Hotkey`.
  - `prefs_page`: `Options.hotkeys` names the preferences that hold a key combination (recorded, not typed); `Options.problem` shows what the program says under a line.
- **`setup.update`** and the controller of the Setup for a screen of the program's own: `headline`, `install_label`, `can_uninstall`, `busy`, `closing`, `start_install`, `start_uninstall`, `pick_folder`, `open_installed`, `close`. The dialog uses the same.

### Changed
- **A menu that searches**: its field is a band from edge to edge at the menu's top, in a field's background with the menu's separator under it, no frame of its own.
- **A menu that searches** (`ctx_menu_open(..., search = true)`) shows its query in a field: a magnifier, what is typed and a caret that blinks, "Type to search" while nothing is.

### Fixed
- **`setup.facts`**: on Windows, a program installed in the default folder (`%LOCALAPPDATA%\Programs\<name>`, or an `install_folder` that is the same path) was taken for an install "to repair" after its restart: the record of the default folder counted as no record. `desktop.install_recorded` reads the record alone.

## [0.141.1] - 2026-11-10

### Fixed
- **The widgets' marks** (a check in a menu or a check box, a dropdown's and a submenu's arrow, a stepper's signs, a toast's sign) are drawn in the toolkit's own icon font (`ui.widget_icons`), whatever `icon_font` the program sets: with Lucide as its icon font, a check was a letter "V".

## [0.141.0] - 2026-11-10

### Added
- **`Toolkit.click`** takes CDP's `modifiers` (Alt 1, Ctrl 2, Shift 8): a Ctrl or Shift click, as a test marks rows of a list.
- **`lucide`**: `BUG`, `GIT_FORK`, `LIST_CHECKS`, `MICROCHIP`, `NETWORK`, `PAUSE`, `SCROLL_TEXT`, `THERMOMETER`, `ZOOM_IN`, `ZOOM_OUT`.
- **`ui.table_widths_text`, `table_widths_apply`, `table_sort_text`, `table_sort_apply`**: a table's column widths and sort as a preference's text (`pid=6.5,command=30`, `-memory`), and back.
- **Lists mark more than one row** (`List_State.multi`): a Ctrl click marks a row besides the active one, a Shift click a range, Ctrl+A every row; a marked row is drawn as the active one and goes with its row's identity (`list_is_marked`, `list_mark_count`, `list_mark`, `list_mark_all`, `list_marks_clear`, `list_row_id`).
- **`desktop`**: the desktop entry says `StartupWMClass=<slug>`, the window's class: a launcher and a dock match the program's window to its entry by it.
- **`process.affinity`, `process.set_affinity`** (Linux): the logical processors another process may run on, read and set for every thread of it, by pid and start time as `set_priority`; `Cpu_Set` with `cpu_set_has`, `cpu_set_put`, `cpu_set_count`.

### Changed
- **`ui.key_name`**: the Escape key is "Escape" in menus, tooltips and the sheet of the keys, as the other keys are named whole ("Delete", "Page Down").
- **`ui.palette`** keeps a command only when what is typed is in its label whole, or in pieces that each begin a word, the words in order (`ui.fuzzy_words`): "prio" finds "Raise the priority" and no longer "Previous section". The text whole ranks before pieces, the start of a word before elsewhere.

### Fixed
- **`process.set_priority`** lists the threads through a descriptor of the process's own `/proc/<pid>` folder, whose start time it checks, and its pidfd says afterwards whether the process still ran: a pid given to another process in between is no longer read or changed.

## [0.140.0] - 2026-11-10

### Added
- **`desktop.Identity.actions`**: the desktop entry's actions (`Desktop_Action`: `Actions=` and a `[Desktop Action id]` group each, the program run with its arguments), which a launcher's right click offers.
- **`ui.Command`**: a program's commands in one table (label, group, keys) give its key handling (`command_pressed`), its menus' and tooltips' key texts (`chord_text`, `command_shortcut`, `command_tip`), a command palette that searches as you type, the best matches first (`palette_open`, `palette`) and a sheet of the keys (`shortcuts_sheet`); docs/commands.md.

## [0.139.0] - 2026-11-10

### Added
- **`ui.key_take`**: the frame's first key press not taken yet, with its modifiers (a recorder of shortcuts).
- **`release` package**: a program's release steps for a project's tool: `package_` (the archive and its SHA-256), `notes` (the changelog's section), `ship` (the changelog dated, the version set, the checks, the commit, the tag, the push), and the pure version and changelog helpers.
- **`desktop.theme_icon`**: an application's icon by its name (a desktop entry's Icon=) from the person's icon theme, the themes it inherits, hicolor, then pixmaps; an absolute path is the file itself (Linux; elsewhere none).
- **`ui.segmented` `tips`**: a tooltip per segment, also the segment's description for a screen reader.
- **`ui.type_to_field`**: a printable character typed while no text field has the keyboard gives it to one field (a filter), which takes the character in the same build: just start typing to search.
- **`ui.table_build` and its layers**: a sortable table of texts (`Table`, `Table_Data`, `table_apply`, `table_keys`): titles that sort and reverse, rules that resize, a columns' menu (`table_column_items`), the keyboard while a filter field has it (arrows, pages, Ctrl+Home/End, Enter, Menu and Shift+F10), cut cells shown whole in a tooltip, the selection strong while the window is the user's; `table_header`, `table_cell` and `Table_Layout` for a table that builds its own rows (docs/data-views.md).
- **`ui.Value_History`, `ui.line_graph`, `ui.sparkline`, `ui.meter_bar`**: the last N values of a sample, their graph (each series an area under its line, grid and frame, a top found with a floor: `graph_top`), the same small and bare, and a flat bar of how full something is that turns to the bad colour past a threshold (docs/data-views.md).
- **`ui.Worker`**: a reader on its own thread: the interface asks (`worker_ask`, asks during a run make one more run), the job swaps its result in under the worker's lock and wakes the window (`worker_published`), the interface takes it once (`worker_take`).
- **`platform.interface_addresses`**: the IPv4 and IPv6 addresses of every network interface with their netmask and whether the interface is up or the loopback (Linux: getifaddrs; elsewhere an empty list).
- **`process.signal_process` / `set_priority` / `process_start_time`**: a signal or a nice value for another process named by its pid and its start time; on Linux the pid is pinned with a pidfd and the start time read again before `pidfd_send_signal`, and the nice value is set on every thread (other systems: `.Unsupported`).
- **`dbus.call` / `call_async` `interactive`**: the call carries ALLOW_INTERACTIVE_AUTHORIZATION, so a service that checks with polkit (systemd on a system unit) can ask the user for a password instead of refusing.
- **`ascii.compare_fold`**: the order of two names, case ignored (ASCII) first, then the bytes (a table sorted A to Z). docs/ascii.md describes the package.

## [0.138.0] - 2026-11-10

### Added
- **`lucide.REDO_2`**: the redo icon.
- **`ui.splitter`'s `flush`**: the handle is its rule alone, the panes meet at it (their rules and a selected row reach it, with no strip beside it), and it is grabbed as wide as a usual handle all the same. **`Box.hit_outset`**: how far a box's hit area reaches past its rect.
- **`ui.ctx_menu_open(..., search = true)`**: a menu searched by typing (fuzzy): the items that do not match go, a submenu's items come up into the menu, the first match is selected.
- **`desktop.open_terminal`**: a terminal opened in a folder ($TERMINAL or a common terminal on Linux, Windows Terminal or the command prompt on Windows).
- **`ui.splitter` options `fill` and `line_at`**: the handle painted in a pane's colour, its rule at its start or end (one line with the next pane's edge, not two side by side).
- **`instance.serve_start`, `serve_stop`**: an Owner served on a thread of its own, for a program whose loop sleeps until its window has an event.
- **`desktop.file_icon` (the size its file is chosen by apart from the size made: `choose`), `file_icon_key`, `file_icon_destroy`, `svg_available`**: the system's icon of a file or a folder, as its file manager shows it: on Linux the person's icon theme (Icon Theme specification, the type from shared-mime-info, SVG files rendered by librsvg opened at run time), on Windows the shell's icon of the path.
  - `platform.cursor_resample` is now `platform.rgba_resample` (an icon theme's PNG files are reduced with it).
  - `platform.portal_icon_theme`: the icon theme the desktop shows, from the Settings portal (`org.gnome.desktop.interface` `icon-theme`); `file_icon` reads it before the GTK and KDE files.

### Fixed
- **`desktop.file_icon`**: two threads asking the first icons at once no longer share the theme's cache unlocked; the portal is asked with no lock held (`file_icons_forget` asks the theme again); `file_icon_key` reads no file; on Windows the icons come at 48 and 256 pixels too, COM is started on the asking thread, an icon with no alpha takes its mask; `open_terminal` quotes a drive's root and shows no dialog when Windows Terminal is missing, `$TERMINAL` may hold arguments.
- **`ui.hline` in the machined finish** keeps its two lines, the dark one and the lit one under it: the rule is two lines tall there, both inside its box. The lit line was drawn under the box, where the pane after it covered it (a lone dark line), and showed through a clear splitter's handle as a ledge.

## [0.137.0] - 2026-11-09

### Added
- **`config.Def.hidden`**: a preference the program keeps for itself (a layout, a last choice): `prefs_page` shows it on no page and its search does not find it.

## [0.136.0] - 2026-11-09

### Added
- **`prefs_page.Page_Info.names`**: the preferences a page shows, in this order, whatever their category (nil: those of its category, as before), so that a program's settings pages need not be its registry's categories, which its editor of every preference keeps.
- **`draw.replay(..., compare = true)`**: with partial redraw (`damage_auto`), a replayed picture is compared with the last frame's (the picture, its version, its slots, the matrix, the alpha, the outer clip, its batches' state and textures) and drawn again only when one of them changed, where the picture draws (not its whole scissor). Off by default: a replay is redrawn every frame, as before.

## [0.135.0] - 2026-11-09

### Added
- **`platform.send_hotkey`**: presses a key combination for whatever window has the keyboard, another program's (a clipboard history pastes into the program it was called from). Windows: `SendInput`; Wayland: a virtual keyboard of the seat (`zwp_virtual_keyboard_v1`); X11: none yet. `keysym_name_of` gives a key's xkb name. See docs/platform.md.

## [0.134.0] - 2026-11-09

### Added
- **`checkbox` and `radio` take `wrap`**: a label longer than the row goes on to the next lines, the row as tall as they are and its mark on the first, instead of running past the row's edge.

## [0.133.0] - 2026-11-09

### Fixed
- **A capture of a window with partial redraw is taken when nothing changed**: a frame that drew nothing was not presented and had no texture to copy, so a capture asked for then failed (DevTools' screenshots, once a dialog had opened). A frame a capture waits for is now presented (`damage_skips_present`).

## [0.132.0] - 2026-11-09

### Changed
- **`setup`**: the dialog is laid out dense, as a tool's panel: its own title bar (the name, the close control), a framed header (what is offered for the state, the versions, the state as a badge), the install location, "Options" as a grid of framed boxes two a line, a framed box of what the disk says, then the buttons. It opens 46 × 34 em. `Config.square`: every corner of the dialog square (its panel, frames, fields and the toolkit's buttons).

## [0.131.0] - 2026-11-09

### Added
- **`setup.Dialog.at`**: where the last frame put the dialog's buttons (Install, Uninstall, the secondary one: `Button_Role`), for a program's automation and its tests. The dialog opens 31 em high (27 before), so a program's choices show without scrolling.

## [0.130.0] - 2026-11-09

### Added
- **`ui.current_state`**: the State whose build is open on this thread (nil outside a build), for a widget that works on other threads and posts to it (`ui.post`) when its work ends.
- **`platform.Clipboard_Content.files_cut`, `platform.clipboard_files_cut`**: files cut on the clipboard, for a move, as file managers do it. Windows writes and reads `Preferred DropEffect` = move. Linux also offers `x-special/gnome-copied-files` (`copy` or `cut`, then the URIs) and, for a cut, `application/x-kde-cutselection`; it reads the cut from either. Pure helpers: `gnome_copied_files_encode`, `clipboard_files_cut_decode`.
- **`lucide`**: the icons of classeur, a file manager: folders (open, plus, search, input, output, symlink), the kinds of files (text, code, image, music, video, archive, spreadsheet, link), the arrows, the panels, the columns and rows, the bookmark, the star, the filter, the scissors and paste, the terminal, the USB drive.
- **`modal_sized(..., top)`**: a resizable dialog held at a height of the window (a command palette) instead of centered; its bottom edge and corners follow the pointer, its top has no grips.

### Changed
- **`desktop.watch_start`**: no timer any more. A place that does not exist (nothing installed yet, a folder or a key deleted) is followed through its nearest existing ancestor, which wakes the program only when the next folder (or key) toward the place comes; the place that comes is watched itself. On Linux the watcher also follows the install folder, the Desktop and the autostart folder, and an overflow of inotify's queue is a change.
- **`setup`**: the dialog does its work on a thread of its own and follows the disk while it is open.
  - Reading the state, Install, Uninstall and the folder picker run on the dialog's thread, one at a time; the dialog says "Working…" and its buttons wait; the end of the work and a change seen by the watcher wake the program (`ui.post` to the State of the dialog's last frame). `setup.dialog` is called every frame, open or not.
  - While open, the places of the install are watched (`desktop.watch_start`): a change made elsewhere is read again at once; `setup.stale` lets the program ask for it too.
  - `Config.choices`: the program's own options of an install, shown as boxes; `Config.prepare` receives their values (`prepare(o, choices, user)`) and is called before anything is read or written, so a test can point every place at a folder of its own.
  - `Config.folder`: the user may choose the install folder before the first install (`install(c, shortcut, choices, folder)`; checked with `desktop.check_install_dir`).
  - Uninstall asks for a second click. A newer installed copy is named as such (`is_downgrade`: "Go back to <version>").

### Fixed
- **`setup.facts`**: a program with no icons that is not installed reads as not installed, not as an install to repair.

## [0.129.0] - 2026-11-09

### Added
- **`lucide`**: `ALIGN_LEFT`, `CLIPBOARD`, `EDIT`, `FILES`, `IMAGE`, `PIN_OFF`, `SAVE`, the icons papier draws (it uses the toolkit's set in place of its own copy).

## [0.128.0] - 2026-11-09

### Added
- **`lucide`: the Lucide icons as a font** (`lucide.DATA`) and constants for their characters (`lucide.SEARCH`, `lucide.PALETTE`, `lucide.DOWNLOAD`...): one set of icons for every program of the toolkit, in place of each program's own copy.

## [0.127.0] - 2026-11-09

### Added
- **`setup`: the program's own look, and the Desktop's shortcut on Linux.** `Config.backdrop`, `Config.button` (`Button_Kind`: `Normal`, `Accent`, `Danger`) and `Config.close` let a program draw the dialog's backdrop, its buttons and a close control as its own dialogs do. The dialog asks for a shortcut on the Desktop on Linux too: `desktop` has a `Desktop_Shortcut` part there (a copy of the entry in `xdg_desktop_dir`, executable; another program's file stays). The `setup` package has its tests (the states, the versions, when a start offers the dialog). The dialog can be resized from its edges and its corner (`Dialog.size`, which the program may keep); what it says scrolls when it is small, its buttons stay under it.

## [0.126.0] - 2026-11-09

### Added
- **`setup`**: a program installs itself for the user from a dialog of its own, over the desktop package: the state of the install (`facts`, `state_of`), Install (the copy, the launchers, the program's own parts by `Config.prepare`, the system's record), Uninstall (what the running copy holds goes at the end of the process), Repair, Upgrade, Open the installed copy, and the offer at a start (`wanted`, the user's choice kept by the program). It was opencode native's Setup. See docs/setup.md.
- **The console launcher** (`tools/console_launcher`, `src/console_launcher`): `<stem>.com` beside a program of the Windows subsystem, which `desktop.install` writes with the PATH entry. In cmd or PowerShell it gives a console command its output and its exit code and lets a window go. A program builds its own with its mark and its rules (`LAUNCHER_DEFAULT`, `LAUNCHER_OTHERS`: words as the first argument, flags anywhere, `(none)`) and embeds the bytes. It was Wren's (src/tools/wrencom). See docs/desktop.md.

## [0.125.0] - 2026-11-09

### Added
- **`qr` and `ui.qr_code`**: QR Codes (ISO/IEC 18004, model 2), as Project Nayuki's generator makes them: numeric, alphanumeric or byte mode, levels L, M, Q and H, the smallest version that holds the text, the mask of lowest penalty. `ui.qr_code` draws one dark on white in whole device pixels with its quiet zone, encoded again only when its text changes ([docs/qr.md](docs/qr.md)).
- **`platform.notify`**: system notifications without a tray icon (title, body, PNG icon, urgency, buttons, replace in place, silent), `notify_close`, `notify_supported`, `notify_set_app`; clicks, buttons and closes come back as `Notification_Click`, `Notification_Action` and `Notification_Closed` events of the window. Linux: org.freedesktop.Notifications (desktop-entry, urgency and image-data hints; an ActivationToken lets `raise_window` bring the window to the front on Wayland, `notify_activation_token`). Windows 10 and later: WinRT toasts under a registered AppUserModelID. See docs/notifications.md.

### Changed
- **Text in colour stripes is a touch bolder** (Slug): `font.Settings.slug_stripe_weight` (default `SLUG_STRIPE_WEIGHT_PX`, 0.2 px, at every size) moves the stems' sides out, across only, so striped text no longer reads thinner than grey text and keeps its baseline and x-height. The Slug shaders take the edges' moves per axis.
- **`winrt.event_handler_make`**: the callback receives the sender and the arguments of the event (`callback(user, sender, args)`), and an optional `done(user)` runs when the last reference goes; **`winrt.typed_event_handler_iid`** and **`SIG_INSPECTABLE`** give the IDs of `TypedEventHandler<S, T>`. A program that passes a callback of its own to `event_handler_make` changes its signature to `proc(user, sender, args: rawptr)` (Papier's clipboard history does).
- **`platform.tray_notify`** on Linux shows its notification through the code of `notify`: one Notify call for both; info is a low urgency, error a critical one.

### Fixed
- **Offscreen windows on Linux** hear the session bus and the accessibility bus while they wait: notifications and portal answers reach a window that has no display.

## [0.124.1] - 2026-11-09

### Fixed
- **Linux: `system_subpixel_text` reads fontconfig** (`antialias`, `rgba`) instead of always saying RGB: a configuration that asks for BGR, grey or no smoothing is followed. The colour-stripe text tests (`tests/subpixel`, Slug) run on Linux too, with the built-in face.

## [0.124.0] - 2026-11-09

### Added
- **`winrt`** and **hotkeys**: what a program needs for the Windows clipboard history and a global shortcut.
  - `winrt`: Windows Runtime APIs from Odin with no projection: HSTRINGs, activation factories, the interface IDs of generic instances computed from their signatures (`async_iids`, `event_handler_iid`), `await` for an `IAsyncOperation<T>` (a completion handler, a timeout that cancels), event handlers of the program's own, read-only vectors. See docs/winrt.md.
  - `platform.hotkey_register`, `hotkey_unregister`, `hotkey_parse`, `hotkey_text`: a key combination the system gives a window wherever the keyboard is, as a `Hotkey` event with its id. Windows: `RegisterHotKey`; Linux has none (the compositor binds shortcuts to commands). See docs/platform.md.
  - `prefs_page`: a page of `Options.pages` with no preference in the registry is not shown (a program that registers some preferences on one system only).
  - `platform.uri_list_to_paths` on Windows: `file:///C:/x` reads as `C:/x`, not `/C:/x`.

## [0.123.0] - 2026-11-09

### Fixed
- **`config.save_user`** makes the folder of its file when it is not there: a program's first save from its settings no longer fails (papier's Settings lost a change, read back from no file).

## [0.122.0] - 2026-11-09

### Fixed
- **`prefs_page`**: a number with a unit no longer makes its line as tall as the page (the unit took the height of a parent sized by its children).

## [0.121.0] - 2026-11-09

### Changed
- **`draw.damage_auto`** works out the region in linear time: 0.45 ms instead of 2.0 to 2.6 ms for 10,000 spans (`-o:speed`). A span is compared by parts (what it drew between two children); `Damage_Memory` holds `parts` and `next` (swapped, not copied), `Damage_Span` is now `Damage_Part`, `Damage_Auto_Stats` has `parts` (was `spans`), `ms`, `px_drawn` and `px_window`, and `Damage_Whole.Offscreen` is now `Plane`. A second memory in one frame asserts.
- **A resize grip sits in a square corner**: a resizable dialog (`modal_sized`) and a floating dock panel keep their bottom right corner square, and their grip is a bevel cut across it in the theme's `resize_grip shade` (the border colour: darker on a light theme, lighter on a dark one), with its dots on it, clear of its edge. Boxes have `square_corners` (`ui.Corners`) for this; `ui.paint_rect_corners`, `ui.box_radii` and `ui.radii_grown` are new.
- **`ui.theme_show` takes the blend space** (`theme_show(&theme, list, choice, &shown, render.blend_space(&r))`): a program that draws in sRGB gets its translucent entries for sRGB. It applies again when the definition of the theme shown changes (a themes file read again with the same names) or the space changes, and a change of the glow alone bumps `Theme.serial`.

### Fixed
- **`Toolkit.metrics`**: `damage` counts the pixels of the served window (from its `ui.State`), not those of the window the shared renderer drew last.
- **`draw.offscreen_begin`** no longer makes the frames of automatic damage whole: what is drawn into an offscreen target damages nothing, so a drag image keeps partial redraw on.
- **Wayland**: `platform.minimize` before the first `show_window` (or while hidden) is asked at the show, once the toplevel's first configure came, as `set_maximized` and `set_fullscreen` are. A window with no fractional scale from the compositor yet follows the output's integer scale, and a hidden window no longer sets a buffer scale on its destroyed surface.
- **"Open with" on Linux** follows the MIME Applications specification: a `mimeapps.list` removes associations only for its level and the ones after it (a system list no longer removes what the user added), `<desktop>-mimeapps.list` gives defaults, a type with no `[Default Applications]` entry gets its most preferred application as default, and a type comes before its parents. A link that loops under `applications/` no longer overflows the stack. What was read is cached until a file or folder read changes (under 1 ms a call, against 10 to 16 ms in a debug build).

### Security
- **`desktop.exec_expand`** refuses an `Exec` line the Desktop Entry specification refuses: a field code in a quoted argument (`sh -c "viewer %f"` let a file name such as `a;rm -rf ~.txt` run as shell code), an unknown code, `%F` `%U` `%i` inside an argument, two file codes. It returns `ok`; `exec_arguments` returns `Exec_Argument` (`text`, `quoted`). "Open with" lists no application with such a line.

## [0.120.0] - 2026-11-09

### Added
- **`prefs_page`**: a program's settings page from its `config` registry, with no code per preference, in the look of opencode native's settings: the search in a well and the pages with their icons on the left; the page's title and a line per preference on the right (its title and description, a switch, a segmented choice or a list, a slider or a field with its unit, a reset button, a carved line); a search shows what matches in every page. `Options.custom` gives a preference a control of the program's own; `theme_cards` shows the themes as cards in their own colours. `Options.changed` runs after each change, for the program to save and apply it. See docs/prefs_page.md.

## [0.119.0] - 2026-11-09

### Added
- **Web addresses in plain text become links**: `ui.rich_links(text, style, &runs)` turns a string into rich runs whose `http://` and `https://` addresses are links in the theme's link colour, underlined, without the sentence's closing marks around them (`ui.web_address_len`).

## [0.118.0] - 2026-11-09

### Added
- **Automatic partial redraw**: `ui.set_partial_redraw` (or `Host.partial_redraw` in `host`) redraws only the boxes whose drawing changed since the last frame, with no rectangle marked by hand; an idle frame redraws nothing, a caret blink or a hover a small rectangle, custom draws included. Underneath, `draw.damage_auto` with `draw.damage_span_begin` / `damage_span_end` compares a digest of what each span draws (`draw.Damage_Memory`, `damage_volatile`, `damage_whole`, `ui.damage_stats`); `render.texture_version` and `render.damage_building` are new, and a frame with a region is whole when the clear colour, blend space, text or corner settings change. `Toolkit.metrics` (DevTools) reports it: the partial frames, why the others were whole, and the share of pixels drawn.

## [0.117.0] - 2026-11-09

### Added
- **The machined finish** (`Finish.Machined`): bevelled buttons that sink when pressed, fields and segmented tracks as sunken wells with a ring of the accent when focused, separators as carved grooves (box flags `.Sunken`, `.Groove`); flat on a light palette. Its primitives for a program's own surfaces: `machined_bevel`, `machined_well`, `machined_groove`, `machined_plate`, `machined_lamp`, `machined_pip` (each draws its flat form outside the finish); `Theme.glow` sets its halos. It draws up to `MACHINED_OVERFLOW_PX` outside a box: a region redrawn alone must hold that margin. fidget: a Machined finish switch (Ctrl+M).

### Changed
- **Themes replace the named palettes**: `ui.THEMES` (25 themes, most with a dark and a light version: opencode native's and the toolkit's), `Theme_Def`, `Theme_Colors`, `theme_palette`, `theme_palettes`, `palette_of`, `theme_find`; `theme_show` applies a theme, a mode (system, dark, light) and a finish, and follows the system; `theme_recolor` moves a program's own colours to the theme shown; `themes_read` reads a user's themes. `NAMED_PALETTES`, `palette_named` and the `PALETTE_*` constants are gone: `palette_of("Midnight")`, `palette_of("Midnight", light = true)` for Daylight. `Palette.well`: the colour of sunken surfaces. See docs/themes.md.

## [0.116.0] - 2026-11-09

### Added
- **`desktop.handlers_for_file`, `desktop.open_with`**: "Open with": the applications the system knows for a type of file, the default first, and a file opened with one of them (Linux: shared-mime-info, desktop entries, mimeapps.list; Windows: the shell's handlers). Also `desktop.exec_arguments`, `desktop.exec_expand` and `platform.launch_detached` (Linux).

## [0.114.2] - 2026-11-09

### Fixed
- **A window never shown is in no task bar (Wayland)**: `open_window` makes a surface with no role, and the toplevel is made at the first `show_window`. A program that starts hidden in the notification area was listed in the task bars that show every toplevel (ShojiWM). `set_maximized` and `set_fullscreen` asked before the first show are asked by the new toplevel.

## [0.115.0] - 2026-11-09

### Fixed
- **The wheel goes to the box that scrolls its way**: a box that scrolls only sideways (`.View_Scroll_X`, a wide table) no longer takes an up-and-down wheel from the page around it, and Shift+wheel scrolls such a box sideways, as in a browser. A box that scrolls itself still gets the wheel as it is (a number field steps further with Shift).

## [0.114.1] - 2026-11-09

### Fixed
- **The tests of the toolbox build on Windows again**: the test of `start_group` is Linux's only (`#+build linux`: a file name that ends in `_test` gives Odin no system). The test of a host at rest counts its wakes: an event of the desktop may end one wait, a wait that does not sleep wakes hundreds of times.
- **`platform.wait_event` (Wayland)**: less than a millisecond left is a millisecond of sleep. It returned at once, and a loop that waits until a deadline spun through its last millisecond (about 150 wakes).

## [0.114.0] - 2026-11-09

### Added
- **`ui.field_frame`, the box flag `.Focus_Within`, the theme tag `bare`**: one surface for a field and what goes with it (an icon, a count), with one focus ring around all of it while a box inside has the focus. A field built under `bare` draws no background, border or focus ring of its own: no box inside a box, no square ring inside round corners.

## [0.113.0] - 2026-11-09

### Added
- **`toolbox.start_group`, `toolbox.stop_group`** (Linux): a command in a process group of its own, stopped with all it started (a wrapper such as NixOS's sway leaves its real program running when only the wrapper is stopped). `tk desktop_tests` uses them.

## [0.112.0] - 2026-11-09

### Added
- **`platform.raise_window` (Wayland)**: asks the focus through `xdg_activation_v1`, with the seat's last input serial. It did nothing before. A program shown by a shortcut of the compositor now gets the keyboard on compositors that do not focus a new window by themselves.

## [0.111.3] - 2026-11-09

### Fixed
- **Tray (Linux)**: `GetAll` of the StatusNotifierItem includes `IconPixmap`. Panels that read the properties in one call (Quickshell, Waybar) showed the "missing icon" pattern.

## [0.111.2] - 2026-11-09

### Fixed
- **Wayland: a wait sleeps through the renderer's own traffic**: the presentation feedback and the FIFO events of the frame just shown, and the ids of the renderer's callbacks, made the connection readable at each refresh, and every wait ended there: a window at rest drew a frame at each refresh. A wait now ends on what is the window's (its input, a repaint asked for), a change of the clipboard, a wake, a bus or the time. `tests/linux_desktop` checks that a wait at rest sleeps its time.

## [0.111.1] - 2026-11-09

### Fixed
- **Linux: the loop sleeps at rest again**: the system's repaint request (a configure, an expose) stayed set, so every `hosts_wait` ended at once and a window drew frames for ever (60 a second; a core for a hidden one). `host_frame` now takes the request (its frame answers it), and a hidden window's request ends no wait. `tests/linux_desktop` checks that no frame is due at rest.

## [0.111.0] - 2026-11-09

### Added
- **`desktop`: the `Autostart` part**: the program starts with the user's session (`Options.autostart`, with `autostart_arguments`: `--hidden` for a program of the notification area). Linux: an XDG autostart entry (`$XDG_CONFIG_HOME/autostart/<slug>.desktop`, `autostart_dir`, `<prefix>AUTOSTART_DIR`); Windows: the value of the key under `HKCU\...\CurrentVersion\Run`. Status, repair when the arguments change, removal of only what is the program's.

## [0.110.0] - 2026-11-09

### Added
- **`host.host_hide`**, **`host.host_show`**: a window with its renderer off the screen and back, the renderer's surface released first (**`render.surface_drop`**) and made again at the first frame after the show (`render.surface_remake(r, handles)`, which now takes the window's native handles). `tk desktop_tests` builds its tests with the native text backend and tests a host's hide and show with its renderer.

### Fixed
- **Wayland**: a window shown again after `hide_window` no longer ends the connection (`must ack the initial configure before attaching buffer`): the hide destroys the surface with its role, since the last frames' content updates could wait behind a FIFO barrier of `wp_fifo_v1` that an unmapped surface never clears, and the new role's first commit with them.

## [0.109.0] - 2026-11-09

### Added
- **`platform.hide_window`**: a shown window off the screen and back with `show_window` in a few milliseconds, its interface kept (a program in the notification area): Wayland (the toplevel role made again, its first configure waited for), X11 (withdrawn), Windows (`SW_HIDE`). `Window.shown_again` counts the shows after a hide; `host_frame` then makes a new swap chain (**`render.surface_remake`**), which Vulkan's FIFO on Wayland would otherwise wait on for good.

## [0.108.0] - 2026-11-09

### Added
- **`platform.needs_frame_outline`**: a window with an integrated title bar and no frame of the system's (Linux: no server-side decorations, not tiled, no X11 frame extents; neither maximized nor full screen) gets a 1-pixel outline in the theme's border colour, drawn by `ui`.

### Fixed
- **An integrated title bar on Linux works as a frame**: a press on the caption moves the window (Wayland `xdg_toplevel.move`, X11 `_NET_WM_MOVERESIZE`), the bands along its four sides resize it (with the resize cursor over them), a double click on the caption maximizes or restores it, and a right click there opens the compositor's window menu. Nothing of that happened: the window could not be moved. The window menu now gets the press's serial and the surface's coordinates.

## [0.107.0] - 2026-11-09

### Added
- **`png` package**: the one PNG codec of the toolkit. `png.encode(rgba, width, height, .Small | .Fast)` writes straight RGBA8 as a PNG file (`.Small`: the filter of least sum per row and `flate.deflate`; `.Fast`: Sub and `flate.deflate_runs`), `png.decode` reads any PNG (every colour type, bit depth, palette, `tRNS`; 16 bits rounded to 8) as straight RGBA8, `png.rgba8_of` converts any `core:image` picture. `platform.clipboard_image_decode(mime, bytes)` reads a PNG, JPEG or BMP file, `platform.clipboard_pick_mime(offered, wanted)` picks the type to read of another program's offer.

### Changed
- **One PNG codec everywhere**: `paint.png_encode` / `png_decode`, `cdp.png_encode` / `png_decode`, the screenshots of `devtools`, `testkit/session`'s pictures, the CBDT emoji of `font` and the Windows clipboard use the `png` package. `devtools.png_encode` is removed: `png.encode(rgba, w, h, .Fast)` writes the same file. The Windows clipboard no longer links `vendor:stb/image`, and `platform.png_encode` writes at `.Fast` (a 1400 x 925 picture in 2 ms rather than 90).

### Removed
- **`platform.png_encode_hook` and `platform.png_decode_hook`**: the toolkit has its own PNG codec on every system (`platform.png_encode` / `png_decode`), so an application has nothing to set.

### Fixed
- **Linux: pasting another program's image or files**: `platform.clipboard_get_image` read nothing unless the application had set a PNG hook, so an image copied by a screenshot tool, a browser's Copy image or `wl-copy --type image/png` did not paste. It is read now on Wayland and X11 through the toolkit's PNG codec, and an offer of `image/jpeg` or `image/bmp` alone is read too; `clipboard_formats` says `.Image` for them. `clipboard_get_files` also reads GNOME Files' `x-special/gnome-copied-files` when there is no `text/uri-list`. The tray's PNG icon is decoded the same way.
- **`tk desktop_tests` leaves no compositor running**: a server it starts (and the test program) runs in a process group of its own, and is stopped with its whole group, also on a failure, a time limit or a signal to `tk`. A wrapper such as NixOS's sway (`dbus-run-session`, which runs sway and a session bus beside it) took the signal alone and left sway, swaybg and the bus running, holding the command's output open. Their output goes to files now, the test program's printed when it ends. `a_lost_server_closes_its_windows` stops its second server with its children, so the window hears the compositor go.

## [0.106.0] - 2026-11-08

### Added
- **Content that fades out at its edges**: `draw.mask_edge_fade` draws the mask of a `push_mask` that fades the content to transparent over given widths at the left, top, right and bottom edges; `ui.next({edge_fade = ...})` gives it to a box that clips, so that a list that scrolls fades out where it goes on instead of ending in a straight cut.

## [0.105.0] - 2026-11-08

### Added
- **`platform.can_hide_windows`**: whether a window can exist unseen, made and never shown. Yes on Windows; no on Wayland and X11, where a toplevel is shown as soon as it has a buffer: a program that needs an unseen window opens an offscreen one there.

### Fixed
- **Variable faces off Windows**: `font.axes` reads a face's axes from its `fvar` table, and `font.with_variations` makes an instance the native backend opens at its location (a simulation of it keeps it). Both did nothing there, so a variable font was drawn at its default instance: a web font in `font-weight: 400` whose default is 300 came out light.

## [0.104.1] - 2026-11-08

### Fixed
- **Docs tables on a phone, on every site**: the rule that keeps a table's columns wide enough is in the documentation's own style sheet (`docs_css`), not only in `DOCS_CODE_CSS`; Wren's docs, whose site has its own table styles, squeezed them still.

## [0.104.0] - 2026-11-08

### Added
- **`site.Meta.changelog_page` and `version_anchor`**: where a site tells a version (the feed's links, llms.txt), for a site whose changelog is another page or whose anchors are written otherwise (Wren's `changelog/#v0-7-0`).

### Fixed
- **Docs tables on a phone**: each column keeps room for its text (26 characters, at most 70 % of the screen) and the table scrolls sideways in its frame. The columns were squeezed to one word a line.

## [0.103.0] - 2026-11-08

### Added
- **`site.build_docs`**: a documentation site from a project's Markdown: a page per document in the site's header and footer, a menu from `docs/_nav.txt` (folded under a "Documentation" toggle on a phone, no script), a search with no server, collapsible groups, a breadcrumb, the previous and next pages, "On this page", the old addresses sent on. `site.check_links` checks a built site's links without a browser; `site.check` also checks the documentation pages at 390 px. Wren's documentation generator moved here; the toolkit's Docs section uses it.

### Changed
- **`site.render_markdown`** replaces `markdown_html`: one converter (Wren's, which reads more: blockquotes, HTML blocks, aligned tables, autolinks, titles, heading anchors, unique ids), with coloured code blocks (`site.write_code_block`, `site.Code_Language`), the headings and the plain text of a document. A `|` in a code span no longer splits a table cell, two trailing spaces are a hard break, and a title keeps a `_` inside a word.

## [0.102.0] - 2026-11-08

### Added
- **`toolbox` package** (`tk_toolbox`, [docs/toolbox.md](docs/toolbox.md)): what the tools of a project share. `run` (the output shown or appended to a log; a working directory, an environment, a time limit, `echo`), `capture` (the standard output and the exit code, the standard error shown on failure), `env_with`, `exit_code` and `succeeded` (a Windows exit code read as the program's signed 32-bit code), `sha256_hex` and `sha256_file`, `download_pinned` (curl with retries, GitHub's API when a release download fails, a file whose SHA-256 is wrong removed), `download_through_api`, `release_asset_id` and `system_program`. `tools/tk` uses it; its own copies of these procedures are gone.
- **`paint` package** (`tk_paint`, [docs/paint.md](docs/paint.md)): a vector rasterizer on the CPU for pictures made ahead of time, pure Odin and deterministic: an RGBA canvas with a transform, paths (lines, quadratic and cubic Béziers, arcs, rounded rectangles, ellipses, polygons), `fill` (non-zero, even-odd) and `stroke` / `widen` (width, miter, bevel and round joins, flat, square and round caps) with antialiasing, solid colours and linear / radial gradients that pad or repeat, `set_clip`, `draw_canvas` / `resize` (cubic for downscaling, nearest for magnifying), `png_encode` / `png_decode`, `ico_encode` with PNG or DIB entries (`dib_encode`). `tk make_logo` and `tk make_icon` draw with it on Windows and Linux; GDI+ and tools/tk/gdiplus_windows.odin are gone.
- **`desktop` package** (`tk_desktop`, [docs/desktop.md](docs/desktop.md)): the integration of a program with the user's desktop (Start menu and desktop shortcuts, the PATH with a console launcher, the freedesktop.org entry and icons, a link in `~/.local/bin`, and for a browser its registration and URL schemes), its watcher, its command line, and the installed copy (manifest, Settings > Apps record, uninstall, NixOS runtime). Every name and mark is a field of the program's `Identity`; every place is an injectable root. Moved from Wren and made generic. **`process` package** (`tk_process`, [docs/process.md](docs/process.md)): `command_line_args` (UTF-8 on Windows), `console_write` / `console_error` (a Windows program with a window writes to its parent's console), `executable_path`, `parent_dir`.
- **`tk site_docs`**: the documents of `docs/` as a "Docs" section of the website, with its own Markdown to HTML converter (`tools/tk/site_docs.odin`). The Pages workflow runs it.
- **`cdp` and `site` packages** (src/cdp, src/site): a client of the DevTools protocol for tools (a window or a browser, input, waits, pictures, screencasts, scripts, timelines compared with another run) and the steps of a project website (CHANGELOG.md to a changelog page, news and classic pages, what a page says when shared, Markdown to HTML, the pages checked in a real browser), generic: opencode native uses both. docs/cdp.md, docs/site.md.

### Changed
- **The Node tools are tk commands**: `tk cdp` (was tools/cdp.mjs), `tk screenshots`, `tk theme_shots`, `tk timeline_test` (was tests/e2e/timeline.mjs), `tk doc_check` (same flags: `--root`, `--extra`), `tk site_build`, `site_changelog`, `site_meta`, `site_card`, `site_check`. The CI and the Pages workflow run only Odin; Node is no longer needed.

### Fixed
- **`tk site_check`** checks the site as it is published (the Docs pages and the 404 too) and waits for what each step leads to instead of fixed delays (opencode native's check, now shared): the old check hung when the viewer did not open. **`tk theme_shots`** reads the palettes from src/ui/theme_default.odin (tools/theme_shots.mjs still read ui/, gone since the packages moved to src/).

## [0.101.0] - 2026-11-08

### Changed
- **The library's packages are in `src/`** (`src/ui`, `src/platform`...): a program's collection points there (`-collection:gt=<toolkit>/src`), and the examples, tests, tools and docs apart from it. **Every step is a command of `tools/tk`**, on Windows and Linux: `build` (an example; `build.bat` and `./build.sh` are its shortcuts), `ci` (what tools/linux_ci.sh did), `desktop_tests` (what tools/linux_desktop.sh did, its fake xdg-open an Odin program), `build_text` on Linux too. The scripts are gone. `flake.nix`: the development shell on Linux (the pinned Odin with wgpu-native, Rust, the virtual desktops' servers).

## [0.100.0] - 2026-11-08

### Added
- **`config.Search`**: the search of a settings UI made of pages (`search_begin`, `search_page`, `search_shows`, `searching`): which preferences a query shows (every word in the name, the title or the description; a page whose title matches shows all of it) and each page's heading before its first match. The UI keeps its own layout.

## [0.99.0] - 2026-11-08

### Added
- **`update`** (package `tk_update`): signed updates of a program, from Wren and opencode native. A `Product` (name, signing context, public key) checks what a release publishes: one manifest per platform and channel (`manifest_name`, channels optional), signed with Ed25519, for a strictly newer version and the release's own file name (`check_release`). `place` puts the downloaded program in place of the running one after its size and SHA-256 (Windows: renamed aside, put back on failure; Linux: renamed over), `remove_leftovers` cleans up at the next start, and `manifest_of`, `manifest_bytes` and `sign` are the release tool's side. [docs/update.md](docs/update.md).
- **`platform.set_app_id`**: the program's id on the Linux desktop, the name of its .desktop file: Wayland's app_id and X11's WM_CLASS (which windows on X11 had none of). By default the executable's file name, where every window said "gui_toolkit", so a task bar could not find the program's icon and name.

### Changed
- **`tk release`** publishes a version on Windows or Linux (tools/tk), in place of tools/release.ps1, which is gone: the CHANGELOG section and the version, the commit, the annotated tag, the push and the GitHub release. The About picture is taken again on Windows only.

### Fixed
- **System fonts on Linux take fontconfig's aliases and generic families**: `font.load_system` and `font.has_system_family` give "Courier New" the installed font the configuration binds to it (Liberation Mono, by 30-metric-aliases.conf), and `monospace`, `serif`, `sans-serif` and the other generic families the font fontconfig picks. They refused any answer whose family was not the one asked for, so such a name was missing and text fell to the next font.

## [0.98.3] - 2026-11-08

### Fixed
- **`tools/tk`'s pinned downloads** (wgpu-native, DXC, the emoji font) try again, and a file of a GitHub release whose download fails comes through GitHub's API (with `GH_TOKEN` or `GITHUB_TOKEN` when set), checked against its SHA-256 as before: GitHub's release downloads answered 504 for over an hour while its API served the same files, and a CI fetching wgpu-native failed. The tool's own tests run in `run_tests` (`tk_tool`).

## [0.98.2] - 2026-11-08

### Fixed
- **`platform.custom_cursor_info` on Linux** says the size and hotspot of the cursor as it is shown, the image at the scale it is shown at (`scale`, or the window's: `custom_cursor_scale`), as on Windows; it said those of the source image whatever the scale. The scaling is shared with the pixels made for X and Wayland (`custom_cursor_geometry`).

## [0.98.1] - 2026-11-07

### Fixed
- **A lazy column lets its view move by less than a pixel**: the item the view is on was kept in its place by its rect, rounded to whole pixels; that error, read as a move of the content, put a view moving by less than a pixel a frame (a slow glide, the wheel's click just past its dead zone) back where it was every few frames, and it did not move. Its place is now read where the layout put it, not rounded.

## [0.98.0] - 2026-11-07

### Fixed
- **Instance buffers go back down after a peak**: the draw context's instance list and the renderer's instance buffer (D3D11, and WebGPU's tables) are no longer kept at the size of the largest frame ever drawn; after `render.SHRINK_FRAMES` frames in a row that used less than `1/render.SHRINK_RATIO` of them, they shrink to what is drawn (`render.shrink_due`).
- **Text outside the clip makes no instance**: a glyph placed in screen pixels and wholly outside the clip rectangle is no longer drawn (nothing recorded in a picture: it is replayed elsewhere). Text drawn again in strips, as a find in page paints the letters of its matches, made every glyph of the box in every strip: a needle with thousands of matches took 72 MB of instances and 300 MB of buffers in one frame.

## [0.97.0] - 2026-11-07

### Changed
- **`ui.find_sweep`** (breaking): a find in a lazy column reads the column a slice of items at each frame (`FIND_SWEEP_ITEMS`), from the top down, instead of building all of it in one frame: a long document no longer freezes the window when a needle rests. It returns the items this build makes for it, given to **`ui.lazy_begin(sweep = ...)`** (was `lazy_begin(all = find_sweep())`); the text of the scope around the items (the column's own boxes, before them and after them) is read too, in reading order. Until a sweep ends, what the last one found stands; **`ui.find_progress`** says how far it is, and `find_count` while `find_pending` is what it has read so far. A match not counted yet has the index -1.

## [0.96.0] - 2026-11-07

### Added
- **`ui.press_hand`**: the press held on one box goes on on another, with what it keeps (`ui.press_data`), for a gesture whose item is built in another place while it lasts: a tab dragged out of a list into a grid of pinned ones, whose boxes have other parents, stays one drag.

## [0.95.0] - 2026-11-07

### Added
- **Contrast**: `ui.luminance` and `ui.contrast` (WCAG's ratio), `ui.to_oklch` / `ui.from_oklch` for linear colours, and `ui.readable(fg, ground, ratio)`: the colour moved along its OKLCH lightness, its hue and chroma kept, only as far as it must to read on the ground (lighter on a dark one, darker on a light one).
- **The system's light / dark, on Windows too, and when it changes**: `platform.dark_mode_preferred()` reads Windows' app mode (AppsUseLightTheme) as it read the portal and GTK on Linux; `platform.color_scheme_serial()` moves when the choice may have changed (WM_SETTINGCHANGE "ImmersiveColorSet", the portal's SettingChanged): an app that follows the system compares one integer a frame.

## [0.94.0] - 2026-11-07

### Changed
- **Selected text reads on its selection**: the selected part of a selectable box's text (labels, paragraphs, rich paragraphs) is painted again over the selection in the theme's new `"selection text"` colour (by default the text's). A faint text, a dimmed run, was lost on the selection's colour.

## [0.93.0] - 2026-11-07

### Changed
- **The wheel scrolls as the system says**: a notch moves `platform.wheel_lines()` lines (Windows' setting, lines per notch, characters across; three on Linux), each `ui.WHEEL_LINE_PX` (100/3 logical px, a browser's line) at the window's scale, in whole pixels; where the system says a page, a page less a line. Every view scrolls by `ui.wheel_step(box, axis)`, text fields too. Before, a notch was 4 em of the box's font whatever the setting.

### Fixed
- **A tab is drawn as space**: `font.TAB_SPACES` (4) spaces wide, the same wherever it is (measured as shown), with a space's glyph. Fonts have no glyph for it: it was drawn as a missing one (a box) in code and in tools' output.

## [0.92.0] - 2026-11-07

### Added
- **`host.host_adopt`**, hooks **`still`** and **`after_frame`**, **`Host.times`**: a window and a renderer an application made in its own order of start become a host; a window whose picture would not change is not built; what a program does between two frames goes after the picture; the last picture's draw and present times.

### Removed
- **`ui.Reorder`** and **`ui.reorder_frame`** are gone: the drag of a reordered list is kept on the press of the item's box (ui.press_data) and ends with it (the button went up, the box went, the user left the window). The procedures take the item's box key in place of a `^Reorder` and an id: `reorder_begin(item, moved, threshold, press, slot)`, `reorder_dragging(item)`, `reorder_item_pos(item, slot, pointer, lo, hi, rate)` (its animation keyed by the item's box too). Lists whose items share ids drag apart, the box's key being its list's.
- **`ui.Dock.held`** is gone: `ui.dock_held(&d)` asks the press whether the left button holds one of the dock's controls (a tab or a floating panel's title, a handle, a floating panel's corner). It keeps nothing, so it ends with the press (the release, the box held going, the user leaving the window) and says the same at any time of the frame. Write `ui.dock_held(&app.dock)` where `app.dock.held` was read.

## [0.91.0] - 2026-11-07

### Added
- **`ui.lazy_pin`**, **`ui.lazy_pinned`**: the view stays on an item, a given distance into it, placed after each layout whatever grows around it; what the last layout found of it says when it has settled.
- **ui.press_data**: what a gesture keeps lives on its press: the zero T when the press began, the same while it lasts, gone when it ends by whatever way (release, its box gone, the user leaving the window). A press of the same box again, even in one batch of input, starts from zero.
- **ui.window_clipboard_get, ui.window_clipboard_set**: Build_Params' clipboard procedures for the system's clipboard of the build's window, so a program no longer needs a global to reach its window.
- **platform.events_waiting**: whether a window has something for its next poll_events, without waiting. A loop of several windows asks each before it sleeps, because the poll of one window of the thread takes the others' messages.
- **host**: a window as an object, above ui and render. host_open, host_frame (pace, input, resize, builds, picture, present), host_close, and hosts_wait / hosts_due / hosts_frame for several windows on one renderer. Hooks cover what a rich application's frame does of its own: params, input, builds (several in a frame: host_build), hold (no picture this frame), after_build, before_input, dragging, rest_frame. It keeps the orders that matter: input is read with the renderer given back, a step of a resize is that window's alone, buffers keep the monitor's size, and only the first window is paced. examples/hello and examples/todo use it; the way by hand is unchanged.
- **render.surface_scope**: surface_use until the end of the calling scope, so a frame on a second window cannot forget to go back.
- **ui.view_limit, ui.view_reveal, ui.view_reveal_offset, ui.view_jump, ui.view_shift**: the verbs of a scroll box's view, for code that wrote view_off, view_target and view_anim by hand. view_reveal says whether the target moved, so a caller decides on scrollbar_reveal itself; view_shift keeps a glide under way and leaves a target at the top there.

### Changed
- **A lazy column** looks each item up once per build, in one map: an item's height is noted after the layout that placed it.
- **Splitters, dialog grips, floating panel corners, range sliders**: what their drag starts from is kept on the press (ui.press_data), not in the State's one drag payload. ui.drag_store and ui.drag_load stay, for gestures that read an earlier press (panes).
- **render.Window_Target**: what is one window's is now a struct of its own, included by using in Renderer and Surface, and Wgpu_Window on the WebGPU side; surface_use exchanges them whole, so a new window field needs no list. Field access is unchanged, except that Surface.gen and Surface.space_epoch are now Surface.swap_gen and Surface.swap_space, and Surface.wgpu_backing is a ^Wgpu_Window.
- **A row taller than its view keeps its top**: ui.list, menus, reorder_offset, the focus and the accessibility reveal now follow the rule ui.vlist had, instead of showing the row's bottom.
- **A box's name and text**: copied as they are at each build, without going through the formatter.

### Fixed
- **WebGPU second windows**: a window's frame format now goes with it through surface_use, as its offscreen target does on Direct3D 11.
- **Scrolling**: dragging a scroll bar's thumb or stepping a long menu ends a glide under way, which could pull the view back for a frame; a ui.vlist whose rows moved during a glide no longer starts the glide over.

## [0.90.0] - 2026-11-06

### Added
- **`render.surface_init` `under_children`**: a composition surface below the window's child windows. A web view moved into a window with a composition surface stayed hidden behind it.

## [0.89.0] - 2026-11-06

### Added
- **`ui.tween`**: a value that reaches its target in a set time, gently at both ends, for what the eye follows from end to end.
- **`draw.glyph_run_stroke`**: the outlines of a glyph run as a line of a width.
- **`font.glyph_ink_extent`, `font.run_ink_spans`**: where the ink of a glyph or a run crosses a band, from the outlines, kept per glyph and band: the gaps of a skipping underline.

## [0.88.0] - 2026-11-06

### Fixed
- **Text in a dialog or a popover can be selected**: their panel took every press, so a plain `.Selectable` label in it selected nothing, showed no text cursor, and a label made `.Clickable` to get the press counted as a button. The panel is now `.Press_Stop` (new `Box_Flag`: clickable only so that what is under it gets no press): a press on it is a press on nothing, selectable text in it takes its own, and a selection stays on the surface it started on, whatever is built behind it.

## [0.87.0] - 2026-11-06

### Added
- **`push_clip_polygon` takes several contours**: a point past `render.POLYGON_BREAK` ends one, with no edge to the next: a clip with holes.
- **`draw.Path`**: lines, quadratic and cubic Bézier curves, arcs and rounded rectangles, flattened to a tolerance, filled (`path_fill`, nonzero or even-odd, holes included) or stroked (`path_stroke`, round ends and joins, even in translucent colors), with `path_contains` for hit tests, `path_bounds`, `bezier_cubic_at`, `bezier_quad_at` and `draw.bezier`.
- **`draw.line`, `draw.polyline`**: a line of any angle, with round ends and antialiased edges.

### Changed
- **`render.release_targets`** takes the textures to leave: a picture still on screen stays, for the program to carry over to the new generation.

## [0.86.0] - 2026-11-06

### Added
- **`platform.drag_silence_limit`**: for tests, how long a drag may stay silent before it is given up.
- **`Signal.pointer_clicked`**: the click was the button's, so the pointer is where it says. `clicked` stays true for Enter, Space and a screen reader too.
- **`platform.cancel_close`**: takes back a Close the app answered by staying open: `is_closed` no longer stays true for good.
- **Event.lost**: a Mouse_Release made because the system took the pointer. It is no click, and a middle button lost soon after its press no longer latches autoscroll.
- **Event.Frame_Press**: a press on the window's frame or caption (Windows). What the window was doing ends with it: a latched autoscroll waits for the next click anywhere, and a click there came to nobody.
- **`font.atlas_end_frame`**: a draw context between frames holds no page (`draw.end_frame` calls it): a context that stopped drawing no longer keeps the atlas from reusing pages.
- **`devtools.stop(srv, s)`**: for a program that goes on after the server, the `ui.State` it served: the clients' edits, the highlight and the accessibility tree asked of it end too.
- **`Signal.pointer_pressed`**: the press was the button's, so the pointer is where it says and it is held. `pressed` stays true for Enter, Space and a screen reader too. `ui.slider` and the colour pickers read it: Enter on them no longer set the value from wherever the pointer was.

### Changed
- **`ui.Reorder`** holds the press that drags (`held`) in place of `active`: a release and a press read in one frame end the drag, as does the box held going away. Read `reorder_dragging`.
- **Escape in a dialog** goes to the dialog on top at the end of the build, and closes it at the next one: read in the frame a new dialog opens, it closed the one under it. `open` turns false one build later than it did.
- **`ui.Autoscroll`** says where a session is in one field, `phase` (`Autoscroll_Phase`: `Off`, `Holding`, `Latched`), in place of `active`, `held` and `latched`; every end zeroes it, with the box it scrolls (`box`). `State.auto_box` and `State.auto_pressed` are gone.
- **`draw.open_plane_frame`**: `ok = false` for a plane being recorded, which draws nothing (`Open_Plane.mode` replaces `hit`).
- **A capture of a frame WebGPU could not get** (a hidden window's surface) says `Failed`: it stayed `Pending`.
- **A box that goes lets go of what held it**: a press, the focus, a click on the way to a double one. A box of a vlist or a lazy column has only left the view: the focus waits for it there.
- **`devtools`: what a client started is its own.** A screencast, a recording and the tree of `DOM` have one client: another's `Page.startScreencast`, its `Toolkit.*Recording`, `DOM.undo` / `redo` / `requestChildNodes` and the like are refused, and its stop and acks change nothing. A recording ends with its client, typed text included; a highlight goes with its client; what a client held down, buttons and keys, goes up when it goes.
- **`instance.Owner_State`**: an `Owner` says where it is (`None`, `Claimed`, `Serving`, `Closing`) in `Owner.state`, which replaces `Owner.closing`. A second `owner_start` answers false and opens nothing, a file descriptor 0 is one like any other, and a window that could not be destroyed no longer points at its Owner.
- **`config` layers**: `Entry.locked` is gone, `is_locked` reads the layer, and an observer sees a policy value locked. `.Default` no longer goes over a layer, `reset` under a policy changes nothing, `load_file` wants the tag of the layer it reads (`POLICY_MAGIC` for `.Policy`), `register` answers how many waiting values it refused, a user's value that its definition refuses stays in the profile, and `dirty` counts a change under a higher layer and no longer a file just read. `restore` survives an observer that registers.
- **A dialog gives the focus back**: what had the focus when `ui.modal` opened has it again when it closes, unless something else took it meanwhile.

### Removed
- **`render.Pacer.latency`**: `Present_State.max_latency` says what the swap chain has, a new one included.

### Fixed
- **A press on a row of an open menu** leaves the keyboard focus where it was: choosing an item of a field's context menu with the mouse took the focus from the field.
- **`testkit/session`**: `advance` in a build ends the test (it hung to the test's limit), `draw_context` on an attached session says so, `Session.damage` is the next frame's only, and the guard against two tests at once is atomic.
- **`ui.a11y_tree`** is empty when no tree was made (it answered with the last one), and an active descendant not made in this build is not named.
- **Title bar regions** are forgotten with no caption or window too: buttons no build makes any more stayed in `chrome_regions`.
- **A box of the last build** looked up during a build has no text, name, accessibility or custom data: they pointed into memory the build had freed.
- **`ui.theme_destroy`** leaves an empty theme: a palette applied after it appended to freed memory, a second destroy freed it twice.
- **`ui.color_picker`**: the text left by the user is written as the picker writes it: a spelling of theirs (`#F00`) or what is no colour stayed. `Color_Pick.shown` is gone.
- **Find in page**: a sweep's wait is a timed wake, not a frame at each refresh, and a sweep during a glide reports the place in the content (the scroll had moved after the layout). Its clock is the build's.
- **Toasts** ask for frames only while they fade, and a wake between; `ui.set_toast_area` lasts one build, whether `toasts_build` ran or not.
- **Docks**: two requests in one frame are both done, and the stack's menu of a closed panel closes.
- **`vlist`**: `vlist_scroll_to` on a list with no box yet is kept for its first build, the wheel ends the wait for a row with the reveal, and a row of no height is not waited for over 600 builds.
- **`list` and `vlist`**: rows gone from under the active row say `changed`; no row is nothing to reveal (`reveal` stayed armed); a row selected before the first build comes into view with no other frame asked for.
- **`ui.text_edit_caret_rect`** says `false` once the editor is built no more.
- **`text_edit`**: the column of Up and Down ends with every other move and edit (undo, redo, select all, cut, paste, Ctrl+Backspace, a double click kept it).
- **The caret of a `line_edit`** is solid after an arrow key, as a `text_edit`'s is: it could stay in the off half of its blink.
- **Undo in `line_edit` and `text_edit`**: a move of the caret ends a step (type, arrow, type was one), and a field's steps go by the build's clock, as a text area's do.
- **Menus**: a press of a side button outside closes them; a Right or Enter on a submenu that turned disabled opens nothing later; a menu opened from the keyboard selects its first item once, so a pointer on a disabled row leaves nothing selected; a menu opened from inside a menu's block opens when the block ends, its rows not mixed with the old one's.
- **`ui.stepper`**: held with the pointer off its button it waits, as a scroll bar's arrow does.
- **A press with no pointer** (Enter, Space, a screen reader) no longer takes the place of a drag going on (`splitter`, `pane_split`, the edges of `modal_sized`), sets a `range_slider` from the pointer, or moves the caret of a `line_edit` or a `text_edit` to it.
- **`ui.pane_split`**: a strip pulled out and pushed back under the snap stays folded when let go, and a screen reader's value on a folded pane says `toggled`. What a press was on is one state (`Pane_Press`).
- **`ui.modal_sized`**: a press on an edge that does not move chooses no size (the size a small window clamped it to stayed for good), and a double click on an edge stays at the preferred size while the button is held.
- `platform` on Windows: a surrogate pairs only with the unit right after it, a pointer whose end the system no longer describes still ends, a resize made of inner frames has its burst.
- Clipboard on Linux: a selection another program cleared is not read back, X11 asks the server who owns what it took, a late answer is not the next read's, a paste leaves no property, an INCR reader that left is given up, `XdndSelection` is let go, a large drag goes by INCR, a reader that closes its pipe no longer ends the process on Wayland. Windows: a real window's `clipboard_changed` reads the system's clipboard with an offscreen window open.
- `platform` on Linux: a seat that loses its pointer or keyboard and gets it back works again, a scale change of the output or of Xft.dpi reaches the windows, the display is read again after a change of the output.
- `platform` on Linux: a window has one state (`Show_State`), read back from the server: nothing shown is not visible, a state asked before the map reaches the window manager. `set_placement` restores a maximized window on every backend and applies at once on a shown Windows window, an offscreen `set_fullscreen(false)` leaves another state alone, `toggle_maximize` leaves full screen on Windows.
- Accessibility on Linux: the bridge is read by the window's loop, it keeps the whole tree an update changes (**`platform.a11y_tree_merge`**), `a11y_state` is `Off` until a reader runs (org.a11y.Status), a bus that refuses is asked once.
- File dialogs on Linux: a bus without a portal falls back to zenity and kdialog, the portal's answer cannot be missed, its `filter` is the user's choice, a lost bus is `Failed` and not `Cancelled`. `idle_inhibit` ends with its window.
- Tray on Linux: each icon has its own object, a failed create leaves nothing exported, a panel that restarts gets the icons again (`Recreated`), a menu that changes is told (`LayoutUpdated`), a notification has a default action, so `Notify_Click` can come, and one that closed is not replaced by the next. Windows: an icon a restarting shell refused is added at its next change.
- Drag and drop on Linux: a drag says where it is (`Drag_Phase`). X11: only the button that began it ends it, Escape gives it up. Both: the limit is one of silence, a target that took a drop has five seconds, the target hears what the source allows and a Move is told, a source that dies ends its drag, a target disabled under a drag says `Drop_Leave`, no event of kind `None`. A drag script is used up however `drag_start` ends. `drop_inject` of anything but `Drop_Enter` needs a drag over the window.
- `platform` on Linux: `set_cursor` to the cursor the window had takes a custom cursor off the screen, releasing the shown custom cursor shows the window's own, Wayland sends a cursor only for the window under the pointer, `set_cursor_custom`'s `scale` is used.
- `platform`: a release comes once and only of a press made here, on every backend; a pointer taken with a button held makes its release on Wayland and when an X11 window is unmapped; X11 says no `Mouse_Leave` under a press, as a capture on Windows; a key held when the focus goes makes its `Key_Release`. `Activate` comes once for a change, and a window is neither `focused` nor `active` until the system says so.
- `platform.poll_events`: the batch stays whole while the app reads it. What runs from an event may pump the system (a paste on X11, `drag_start`), and `w.events` may then move.
- `platform`: `wait_event` sees all that ends it. On Linux the session bus and the accessibility bus (a tray click answered at once), injected events; on Wayland and Windows a repaint asked for; on Windows the events not handed out; after `input_pending`, what it kept.
- `platform` on Linux: a closed window's last notices go to nobody (the X11 window that polled read as minimized), a window closed under a drag or an input method leaves nothing that points at it, a compositor without xdg-shell fails every `open_window`, and a server that goes away closes its windows (`Display_Link`) instead of leaving a loop that never hears of it.
- `platform` on X11: typed text follows Shift, AltGr, Caps Lock and the layout (a key is read with the modifiers and the group of its event), a change of keymap is followed, a held key says `repeat`. On X11 and Wayland a key keeps its name whatever it types: Shift+1 is `N1`, Shift+Tab is `Tab`, the keypad without Num Lock is `Home`, `Left`...
- **Focus keys**: an arrow and a Tab read in one frame both move the focus, and `ui.focus_step` says its direction (`ui.tab_direction`): a rich paragraph entered backward that way starts at its last link.
- **`Signal.mods`** follows `Key_Release` and `Mouse_Release`: a modifier let go during a drag is no longer held.
- **`ui.rich_paragraph`**: Enter and Space choose the link that has the focus wherever the pointer is (they took the link under it, or nothing over plain text), and a screen reader's focus on a link of a paragraph without the focus stays.
- **The build lifecycle**: `ui.building()` stays true to the last line of `end_build`; `end_build` ends the build that is open, whatever `use` selected since, and asserts that there is one; `ui.destroy` in the middle of a build leaves none open on the thread. `end_build` also asserts the list and menu scopes.
- **Selected text** is one state (`Sel_Phase`): no drag goes on with its selection gone (the text cursor and the frames stayed), `select_box` ends a drag, and a press on a button between two presses on a text breaks their double click.
- **`ui.next` and `ui.a11y`** before what builds nothing (a closed `modal`, `modal_sized`, `ctx_menu` or `menu_nested`, a skipped `lazy_item`) no longer land on the next box.
- **An open menu** no longer gets the keys something else took first (Ctrl+zoom, autoscroll's Escape).
- **Autoscroll**: a move of the window ends a session, as its documentation said. A move read with the release counts against a tap. What ends a session no longer ends the frame's input: a middle press read with it starts the next one, and the Escape it took does not reach an open menu.
- **The window the user leaves** (`Event.Activate`, `Build_Params.inactive`): an open menu closes, a held button ends with no click, the modifiers are forgotten, a selection stops following the pointer, autoscroll ends. A dock drag cut that way drops nothing.
- **A box that goes takes what held it**: at the end of a build a press, the focus, the first click of a double click and the link of a rich paragraph let go of a box the build did not make. A key that comes back later is another box; a focus given ahead of its box stands. `splitter` and `pane_split` say `finished` when their box is back.
- **`ui.set_post_wake`**: the app's wake is called with a `nil` user too, and a `nil` wake goes back to the window's. Of two windows of a State, posts wake the one that stays when the other is destroyed. A post on a State that is gone is refused.
- **`ui.post_configure`** runs every call that waits, not a build's budget of them (the rest were lost), and a closed queue stays closed.
- **`draw.offscreen_end`**: closes the layers left open in the target (it answered 0 and left the target open).
- **`font`**: the emoji font comes back on the next emoji when whoever shared its id unloaded it.
- **`font`**: a word being shaped while the word cache is cleared is shaped again, and no thread keeps the width of a word cleared under it.
- **`font`**: a glyph the COLR interpreter was drawing when the settings changed is drawn again with them, and its outlines follow a new provider or tolerance.
- **`font`**: `glyph_outline` and `slug_glyphs` answer on a state never started (they read a nil backend). `Text_Backend.face_close`, which nothing called, is gone.
- **`draw.destroy`**: in the middle of a recording it no longer leaks the lists of the frame.
- **`draw`**: a layer or plane that replays a picture lacking a pending color glyph is not kept: the glyph comes when it is ready.
- **Frame statistics on WebGPU**: `frame_end(vsync = false)` on a Fifo surface counts the vblank it waits for, a reconfigured surface starts its run over, and `vblank_grid` says unknown once the compositor stops answering (Direct3D 11 too). `gpu_ms` starts over with a new device.
- **`draw`**: a mask layer with no target of its own draws nothing (its drawing landed in the content); `Open_Layer` says what it is and what a mask draws in with `Layer_Kind` and `Mask_Draw`.
- **`draw`**: a layer or a plane owns what is pushed in it: pops stop at where it started and at the root (they panicked there), what is left pushed ends with it, and layers and planes left open inside one another end in the order they were opened. A recording cannot close a plane of the frame.
- **`draw`**: a second `end_frame` does nothing (it drew the frame twice).
- **`render.canvas_read_ready` and `canvas_read_finish`** on a read begun before a device loss: ready at once, and the finish says it failed. They used the old device's objects on the new context.
- **2D canvas layers** nest. A filter pass inside an open layer leaves it open, what is drawn into a layer that could not be made or was freed goes nowhere instead of onto the canvas, and a layer replaced by a filter pass gives its texture back to the pool. `canvas_set_opaque` on a source texture no longer outlives it.
- **A texture a recovery could not make again**: `Texture_Kind.Failed`, it draws nothing, `texture_size` says `{0, 0}` and `destroy_texture` frees its slot. A frame crashed on one (Direct3D 11), and its slot was lost.
- **`render.set_fixed_surface`** survives a device loss: the chain made again had the window's size, and a window larger than it was clipped. A translucent window that fell back to opaque during a recovery tries DirectComposition again at the next one.
- **`render.readback_poll`** says `Failed` for a read-back whose frame did not run, which stayed `Pending` for good, and for an id of another renderer. A renderer destroyed takes its read-backs with it.
- **`font`**: a system fallback that goes character by character (fontconfig) no longer cuts a sequence: joiners, selectors and what follows a ZWJ stay with their base.
- **`font`**: the Slug store follows what its glyphs depend on: `color_glyphs` and `color_engine` reach the glyphs of color faces, a new provider is asked for what had no curves, no room is not kept, and keys hold the slot of a face, so what a face leaves goes with it at any generation.
- **Partial redraw**: a frame that stopped halfway (Direct3D 11), that had no surface texture (WebGPU) or whose region could not be cleared leaves nothing the next region starts from: the next frame is whole. Their rectangles were lost, or composed onto a blank target.
- **A window that cannot be remade** (Direct3D 11, WebGPU) counts as a device lost: the next `frame_begin` tries again, where it drew into nothing and the next clear crashed. A swap chain that `ResizeBuffers` finds gone is a loss too, and a size asked while there is no swap chain is kept.
- **`font`**: a page reused uploads whole to a context that had it: the old bitmaps no longer stay in its texture between the new ones.
- **`render.surface_destroy`** of the Surface in use gives the renderer back its own window first: it tore that window down.
- **Second windows on WebGPU**: a window set aside is made again after a recovery and follows `set_blend_space`, as on Direct3D 11. Its capture, its clear and its first frame are its own, and `surface_destroy` frees its frame statistics.
- **`font`**: a color glyph drawn on the color thread whose COLR layers cannot be read shows its outline, as on the drawing thread (it was kept as a bitmap at page 0, out of range when no page exists).
- **A device lost on WebGPU**: it is noticed (wgpu-native reports every loss with the reason `Destroyed`, which was taken for the renderer's own release), offscreen too. A recovery makes the new device first: with none to be had the old one stays and frames draw nothing, where they ended the process on a nil device. Calls that end the process on a device gone (`QueueSubmit`, `DevicePoll`, `SurfaceConfigure`, `SurfaceGetCurrentTexture`) wait for the recovery.
- **`font`**: the id of a font just unloaded, or of a cascade, no longer leaves blank glyphs for the next face in its slot (`Font.dead` and `State.generation` are gone: an unloaded slot is `Font_Kind.None`).
- **AT-SPI on Linux**: the bridge's connection is dispatched once a frame, so what a client asks of the exported object is answered and a lost bus is seen.
- **`native/a11y`**: an update that is refused or finds no assistive technology leaves the deferred focus as it was, and one that would give a subtree a second graft node is refused instead of ending the adapter.
- **`arena.Pool`**: a slot whose generations are spent is retired instead of wrapping, so a handle never comes back to life, even after 2^32 reuses.
- **`devtools` input and recordings**: two `Toolkit.click` of one batch are two clicks; a drag cut by `Toolkit.stopRecording` gets its `up`, a second button no longer breaks a recorded drag, and a right drag replays as one (`down` and `up` of `tools/cdp.mjs` take `--button right`). `CSS.setStyleTexts` does all of its edits or none, a `;` in a string or a comment no longer ends a declaration, and a frame of a screencast that ended no longer touches the one that took its place.
- **`devtools` connections**: a connection that sends no request is closed after 5 seconds, an upgrade needs `Upgrade: websocket` and version 13, and a frame RFC 6455 does not allow ends the connection instead of being glued to the message under way.
- **`instance` on Linux**: `acquire` and `send` never block past their timeout, with a large message or a full backlog, and an owner that wakes after a sender gave up no longer handles its message as well.
- **`config.save_user`** goes through `fsx.write_atomic`, flushed: a save that fails never removes the profile, and leaves no temporary file.
- **`fsx`**: `write_atomic` writes through a temporary file of its own, `<path>.<pid>.<thread>.tmp`, so two writers can no longer tear a file; `replace` with `durable` answers false when the directory could not be synced; `read_all` no longer returns a replaced file cut to the old size.
- **`dbus`: connecting cannot hang the window's thread.** `connect`, the SASL answer and `Hello` each have a limit of 5 seconds, and a signal no longer fails the authentication.
- **`dbus`: a lost bus closes its socket.** `conn_fd` answers -1 from then on, so the window loop no longer spins on a socket at EOF; nothing more is read after a stream that cannot be parsed, a failed send runs the `call_async` handlers that wait at the next `dispatch`, and `platform` falls back as with no bus. A handler of an expired call that calls no longer panics, serial 0 is never used, and `conn_close` from a handler asserts. `Call_Status.Unsupported`, never produced, is gone.
- **Read-backs on WebGPU**: a buffer is released outside the table's lock. Releasing one still being mapped may call its callback, which takes that lock.
- **`flate`**: an inflater that failed stays failed (`inflate_finish` said `Truncated`, and a later push went on from where it stopped), and nothing is written after `deflate_finish` (it wrote past the end of the stream).
- **`ui.find`**: a sweep left waiting when its page went away kept `needs_frame` true for good, and the loop never slept.
- **`ui.line_edit`, `ui.text_edit`**: the word a double click took collapsed to the pointer at the first frame made with the button down. The drag now goes on by words, as selectable text does.
- **`draw`**: an offscreen target left open is dropped at the end of the frame (it was composited, left its transform on the stack and cut the filters of the layers around it), and a plane left open in a recording ends with the recording (it took the frame's stacks down at `end_frame`).
- **Dock drags that lost what they held**: closing a floating panel while it was dragged ended in a bounds check (`docking.odin`), a panel closed while its tab was held came back at the drop, a drag whose button went up while the dock was not built dropped when the dock came back, and Enter on a held tab restarted the drag.
- **Dialogs on dialogs**: with two open, the one underneath took the focus away at every frame, so a field of the top one could not keep the keyboard, and Tab went through both. Each dialog now knows where it stands among those of the last build: the top one has the keyboard, the others wait.
- **D-Bus**: `r_skip` never returned from a message cut short inside a struct or a dict entry, or from an array of a type that takes no bytes; it ran on the window's thread.
- **DevTools**: `Page.startScreencast` on a window served with no `ui.State` is refused. It woke the window for good, and an ack dereferenced the missing state.

## [0.85.0] - 2026-11-06

### Added
- **`ui.toast_action`**: a toast that a click acts on, and dismisses, for one that says what can be done.

### Fixed
- **The corners of a floating panel**: its panels, drawn after its frame and square, covered the frame's round corners, whose border stopped short of them. They are clipped to the frame now, and its border goes over them.

## [0.84.0] - 2026-11-05

### Added
- **Text per colour stripe**: `font.Settings.subpixel_text` (`.Rgb`, `.Bgr`) gives text a coverage per stripe of the screen's pixels, sharper at few pixels per letter, on Direct3D 11 with the atlas (DirectWrite) and on WebGPU with Slug (three samples a third of a pixel apart). Blended per channel in the frame's own target; in a layer, or turned, the same text is grey. `font.system_subpixel_text` says what the system does, `render.text_subpixel_supported` what the renderer can.
- **The site says what it is when it is shared**: a card, Open Graph and Twitter tags on every page, an Atom feed of the versions, a sitemap and a manifest (`tools/site_meta.mjs`, at deployment).

### Fixed
- **Read-backs from several threads**: the process's table of read-backs was allocated with the allocator of whoever wrote in it first, and freed by whoever emptied it, through an allocator that could be gone. It is on the process's heap.

## [0.83.0] - 2026-11-05

### Added
- **The side buttons of the mouse**: `Mouse_Button.Back` and `.Forward` on Windows, X11 and Wayland, `ui.mouse_pressed(.Back)`, and `back` and `forward` over the DevTools protocol.

## [0.82.0] - 2026-11-05

### Changed
- **Middle-click autoscroll goes five times faster by default**: up to 15000 px/s, reached 300 px from the anchor, the speed doubling every 60 px (`DEFAULT_AUTOSCROLL`): the curve Wren settled on. It was 2800 px/s at 420 px.
- **A `target_hz` above the screen's rate is made**: 120 on a 60 Hz screen is up to 120 frames a second while something moves (none at rest), each on its slot, none waiting for the screen, shown at once (`Cadence_Plan.above`): it stayed at the screen's rate. The screen shows the newest: not smoother, but each refresh has fresher input.

## [0.81.0] - 2026-11-05

### Added
- **`ui.modal_sized`**: a dialog of a size of its own, centered and always within the window: it opens at what it prefers, the person resizes it by its edges and corners (the opposite side follows, it stays centered), a double click goes back; the size is the application's to keep. `ui.modal` stays in the window too: narrower if it must, higher when what is in it would pass the bottom.

## [0.80.0] - 2026-11-05

### Added
- **The output of frames is the application's to choose**: `Pacer.choices` (a ceiling, a rate; read at the next frame, `render.pace_frame` planned with none), and `Cadence.uncapped`: no slot, no wait for the screen, every frame shown at once, for a diagnostic or a benchmark. A window at rest stays at rest.

### Changed
- **`platform.wait_slot`**: `render.pace_frame` no longer sleeps through a frame's slot: input is taken as it arrives (time-stamped, kept for the next `poll_events`), a key or a button ends the wait, a pointer that moves and the wheel do not. `wait_handle` has `until_press`. An offscreen window does not wait.

## [0.79.0] - 2026-11-05

### Added
- **`ui.find_sweep`, `ui.find_all`, `ui.find_pending`, `ui.find_refresh`**: a find in page over a lazy column reads everything once for a needle (when it rests 80 ms, and again if what is built no longer answers), and stays lazy between: `lazy_begin(all = find_sweep())`. In opencode native, a frame while finding 40 -> 1.7 ms on a conversation of 150 answers.

### Changed
- **Text cut with an ellipsis**: where it is cut is kept (by text, font, size and width): it was measured rune by rune at every frame, through the shaper. A frame at rest in opencode native 1.65 -> 1.10 ms.

### Fixed
- **`render.pace_frame` waits for the frame's slot**, after the swap chain and only what is left of it: `Frame_Decision.wait_ns` was worked out and not made, so nothing capped the frames of a screen that does not hold the app back. `platform.precise_sleep`: a wait under the system's tick.

## [0.78.0] - 2026-11-04

### Added
- **`Dock_Options.strip_last`**: boxes after a stack's fold and menu buttons, the strip's last control (a window's close button stays at the far right; `strip_end` comes before them).
- **`ui.field_num_step`**: the number at the caret of a focused field stepped as browsers' style editors step it: Up / Down 1, Page Up / Page Down 10, Shift 10, Alt 0.1, Ctrl 100, and the wheel over the field with the same modifiers; its unit and the text around it stay (`margin: 10px 5px`, `rgba(10, 20, 30, 0.5)`, `calc(100% - 12px)`), a number inside a word or a hex colour is none, the number stepped is selected and the step is an edit of the field's history. `ui.num_step_text` and `ui.num_step_delta` do it on a string and a key press.
- **`ui.color_picker`**: a colour picker for a `ui.Color_Pick` the app owns (`color_pick_set`, `color_pick_rgba`, `color_pick_text`, `color_pick_destroy`; `color_picker_width`): a saturation / value square, a hue bar and an opacity bar beside the colour it was opened with (a click takes it back) and the new one, a switch of the text's format (hex, rgb, hsl, oklch) and the colour as text, applied as it is typed. Every part is a Tab stop, moved by the arrows (Shift: a tenth; the hue by degrees), and screen readers see sliders, a radio group and a field. No eyedropper: the platform layer reads no pixel of the screen.
  - `ui.color_parse` / `ui.color_text`: hex, `rgb()` / `rgba()`, `hsl()` / `hsla()` and `oklch()` read and written, in the style they were written in (`Color_Style`: the format, the legacy comma syntax or the short hex); `srgb_to_hsv`, `hsv_to_srgb`, `srgb_to_hsl`, `hsl_to_srgb`, `srgb_to_oklch`, `oklch_to_srgb`.
  - `ui.alpha_picker`, `ui.checker_draw`; `hue_picker` takes `horizontal`; `sat_val_picker`, `hue_picker` and `alpha_picker` take the keyboard and tell screen readers their values.

## [0.77.0] - 2026-11-04

### Fixed
- **A folded pane's strip in the theme, a fold button on the stacks that fold, tooltips the size of their text**: the strip of a folded side (`pane_split`, a dock's folded split) painted nothing at rest and the palette's raw hover colour (opaque white on a dark theme) under the pointer; it now has the theme's `pane_strip background` (by default the bars' surface) and the theme's `hover_fill` over it, and its chevron is larger (`PANE_CHEVRON_EM` 1.4, also `pane_toggle`'s). A dock's stacks on a side that folds have a chevron button at the end of their strip, as large as the menu's button (`pane_toggle`, which now takes the size `next` gives it; a Tab stop, Enter folds); a strip's tabs are in the room its end's buttons leave, so tabs too many for a narrow stack are cut and the fold and menu buttons stay in view (they were pushed out of the strip). A tooltip's content inherited the app's style, so under a style that fills it was as large as the window; a size relative to the window is now the content's own in it, `ui.tooltip_text(text)` is as wide as its text up to `TOOLTIP_MAX_WIDTH_EM` and wraps past it, and `tooltip` goes above the pointer when it does not fit below (`TOOLTIP_ABOVE_EM`); its first frame measures it unseen and asks for the next one, which places it (it was placed by the size of 10 x 3 em it was taken to have, and stayed past the window's edge when nothing else made a frame). Tests `docking a_folded_strip_takes_the_theme_colours`, `the_fold_button_folds_and_the_strip_brings_it_back`, `the_end_buttons_stay_in_view_past_too_many_tabs`, `a_tooltip_over_a_tall_strip_fits_its_text`; `ui_robust tooltip_places` (above the pointer at the bottom).

## [0.76.0] - 2026-11-04

### Added
- **`ui.menu_at(p)` and `ui.wheel_consumed()`: the wheel over an open menu is the menu's**: `menu_at` says whether a point is on a level of the open menu (a submenu, a nested menu, a drop-down's list) as the last build laid it out, so an app that routes the wheel to its own content before it builds the interface (a browser's page) gives it nothing there; `wheel_consumed` says whether this build's wheel went to the interface (a box that scrolls under the pointer, or a menu's level, one that fits included). A menu taller than the window scrolls under the wheel, one that fits takes it and does not move, down and across; the scroller under either gets nothing (test `keyboard menu_takes_the_wheel_over_it`).

## [0.75.0] - 2026-11-04

### Changed
- **Slug glyph data built in half the time**: `slug_build` sorts the curves of an axis once (one `u64` key each) and puts each curve in the bands it spans, found from its bounds against the bands' own; it sorted the curves of every band and tested every curve against every band of each of the ten band counts it tries. The same data (test `slug bands_are_their_definition`); 400 glyphs of a face, best of 5: Segoe UI 5.5 -> 2.8 ms, Times New Roman 8.3 -> 3.9 ms, Nirmala UI 10.0 -> 4.6 ms.

## [0.74.0] - 2026-11-04

### Changed
- **`font.color_prepare`, textures zeroed on the GPU**: `font.color_prepare` makes what color glyphs are drawn with (Direct2D on a WARP device, about 20 ms) for an application to call on a thread of its own while it starts; the first color glyph a frame looked up made it on the drawing thread. Textures are made render targets too and zeroed by a clear on the GPU (`ClearRenderTargetView`) where they were zeroed by uploads of zeros: a 2048 x 2048 glyph atlas page 6 ms (R8) and 3.5 ms (RGBA) of the CPU before, its first frame's.

## [0.73.0] - 2026-11-03

### Fixed
- **The ASCII case helpers are package `ascii`** (`ascii/ascii.odin`: `ascii.lower`, `upper`, `lower_byte` / `upper_byte`, `equal_fold`, `has_prefix_fold`, `contains_fold`), no longer `base`'s `ascii_*`: a package named `base`, which `font`, `devtools`, `platform` and `config` now import, clashed with an app's own package of that name (Odin wants one name per package in a program).

## [0.72.0] - 2026-11-03

### Fixed
- **ASCII case for names and protocols**: `strings.to_lower`, `to_upper` and `equal_fold` of Odin dev-2026-11 fold by Unicode (the Kelvin sign U+212A is `k` to them, the long s U+017F `s`), where names and protocols want ASCII. New in `base` (`base/text.odin`): `ascii_lower`, `ascii_upper`, `ascii_lower_byte` / `ascii_upper_byte`, `ascii_equal_fold`, `ascii_has_prefix_fold`, `ascii_contains_fold`. Switched to them: the DevTools server's header names and Host (`Ho\u017Ft:` is no Host, `localho\u017Ft` no localhost), CSS colour keywords, `nodeName`, the accessibility roles and actions; font family names as cache keys (Windows, Linux, macOS) and fontconfig's / Core Text's answer checked against the family asked for (`DejaVu San\u017F` no longer loads DejaVu Sans); preference booleans; the GTK theme name, file extensions for MIME types on Linux; the changelog tool's type and slugs, `tk`'s checksums and emoji version line, `run_tests`' groups, the examples' option names. Unicode stays for user text (find in page, fuzzy matching, type-ahead, the settings' and DevTools' searches, the test session's text lookups), display text and Windows paths. Lint `tests/unicode_case` (a step of `run_tests`): a call of `strings.to_lower` / `to_upper` / `equal_fold` or `unicode.to_lower` / `to_upper` in the toolkit's sources fails unless `tools/unicode_case_allowed.txt` lists its line with why; an entry that matches no line fails too.

## [0.71.0] - 2026-11-03

### Added
- **Docking** (`ui/dock_model.odin`, `ui/docking.odin`, `docs/docking.md`): the app's panels in stacks of tabs the user rearranges. The layout is the app's `ui.Dock`, flat data: a tree of nodes in one `#soa` array (leaves: a stack of panels and the one shown; splits: an axis, a ratio, the second side folded), floating roots at a place of their own, the panels (the app's `u32` ids) in tab order; `dock_add`, `dock_move` (into a stack at a tab, at a side of one, at an edge of the space, floating), `dock_move_node`, `dock_redock`, `dock_close`, `dock_activate`, `dock_set_split`, `dock_layout`, `dock_target_at`; one line of text (`dock_format` / `dock_parse`: unknown names dropped with the stacks they leave empty, the panels it does not name placed by the app, any other text refused with the dock left as it was). `dock_begin` / `dock_panel` / `dock_end` build it: a tab dragged out shows the drop targets (five squares over the stack under the pointer, four at the edges of the space, the strips between their tabs) and a translucent preview of where it lands; let go elsewhere it floats (an overlay of the window with a frame and a shadow, moved by its strip with the drop targets, resized by its corner, docked back by a double click); Escape cancels; the handles are `pane_split`'s (minimum sizes, fold); close buttons, a middle click; the stack's menu reaches every drop target from the keyboard; the arrows along a strip, Ctrl+Shift+arrows move a tab, Ctrl+Tab goes through a stack; roles tab list, tab (controls its panel), tab panel, separator. Theme entries `dock_preview` and `dock_marker`. Example `examples/docking`; tests `tests/docking` (the model and the text; the drags, the keyboard and the menu through the test session).

## [0.70.0] - 2026-11-03

### Changed
- **`ui.build_events`**: a copy of the last build's input, kept by the state until the next build (it was the caller's slice, valid until its next poll).
- **Built with Odin dev-2026-11** (pinned by SHA-256 in the CI, `docs/getting-started.md`): `core:image`'s pixels are a `[dynamic]u8`, nothing keeps a reference to a stack past its procedure (the compiler's new escape analysis: the tests' globals are cleared, `ui.use` keeps the caller's state on purpose), `core:compress/deflate` checks `flate`'s streams in the tests and `docs/flate.md` compares both (`flate` stays for streams and `deflate_runs`). wgpu-native stays 29.0.1.1.

## [0.69.0] - 2026-11-03

### Added
- **Menus taller than the window scroll**: a level (menu, submenu, nested menu, dropdown list) whose content is taller than the window is as tall as the window, placed again at each frame (a window made shorter while it is open), and scrolls: the wheel, its scroll bar (a press on it is not a press outside; the rows leave it room), the keyboard's selection brought into view (Up / Down / Home / End / Page Up / Page Down, type-ahead to a hidden row, a dropdown's current value from `menu_select`). A menu that fits is placed as before (flipped to the other side of its anchor, else shifted to stay whole). `ui.menu_item_rect(depth, idx)`: where an item was laid out. Tests `menu_taller_than_the_window_scrolls`, `menu_near_the_bottom_flips_or_shifts`

### Changed
- **Menus are dense**: `MENU_ITEM_EM` is 1.9 (was 2.2): rows of 29 px for 15 px text, as Windows 11's and Chrome's menus (times the density: 22 px at `DENSITY_COMPACT`, 34 px at `DENSITY_MAX`); the padding above the first item and below the last is 0.25 em (was 0.3), a separator's gaps 0.2 em (were 0.25); the icon cell is as tall as the row. Test `menu_rows_follow_the_density`

## [0.68.0] - 2026-11-03

### Added
- **`ui.pane_split`, `ui.pane_toggle`, `ui.Pane`**: panes the user resizes from a few em (`PANE_MIN_EM`) to all the room but a few em for the other side, folds (a drag under half the minimum, a double click, Enter, a chevron button) to a strip that brings them back (a click, Enter, a pull), and places at the side or below (`pane_axis`, `pane_place_menu`); the app owns a `Pane` per split (sizes per orientation, folded, place) and saves it through `Pane_Options.on_save`; `pane_format` / `pane_parse` make it a line of text; `menu_move_to` lists "Move to" items for a tab that may go to another strip. Keyboard (arrows, Home, End, Enter) and accessible (a separator with its value, `expanded`). `examples/panes` uses them. Tests `tests/panes/pane_split_test.odin`

## [0.67.0] - 2026-11-03

### Added
- **`ui.set_scrollbar_arrows`**: classic arrow buttons at both ends of the scroll bars of scroll boxes, off by default (the bars stay as they were): each as long as the bar is broad, taken from the track; a press scrolls a step (3 em, eased like the wheel), held it repeats after 250 ms every 50 ms while the pointer stays on it. `ui.scrollbar_arrow_rects` gives where they are; **`draw.triangle`** fills a triangle in one-pixel rows (the arrows' glyph). Test arrow_buttons_step_and_repeat

## [0.66.0] - 2026-11-03

### Added
- **`ui.menu_nested_open` / `ui.menu_nested_open_rect` / `ui.menu_nested`**: a menu opened from inside an open one, at a point or under a rect (a row's context menu in a drop-down panel), over it, the menu staying open behind it. It closes like a submenu: a press outside it closes only it, Escape closes it, choosing an item closes the menu.

## [0.65.0] - 2026-11-03

### Removed
- **Public procedures nobody called** (neither the toolkit, nor Wren, nor opencode_gui_toolkit): `draw.damage_padded`, `layer_cache_forget` (an idle result goes after its frames anyway), `picture_slot`, `picture_version`; `dbus.arg_variant_u32`, `read_variant_string` / `_bool` / `_u32`, `w_i16`, `w_i64`; `font.native_coverage` (and the text backend's `gt_face_coverage`), `native_table`; `platform.a11y_prop_ids`; `render.canvas_pool_bytes`, `canvas_texture_changed`, `canvas_texture_size`, `damage_rects`, `heaps_reset`, `video_gpu_bytes`; `ui.autoscroll_is_enabled`, `post_queue_capacity`.

## [0.64.0] - 2026-11-03

### Added
- **`tests/globals`**: every package-level variable of the toolkit's packages (those of `when` blocks and the procedures' `@(static)` ones too) is in `tools/globals_allowed.txt` with its class (`const`, `process`, `thread`, `test`) and why; the test fails on one not listed, one listed that is gone, and a class the code contradicts (`@(thread_local)` is `thread`). It reads the sources next to it, not from the working directory; `-define:GLOBALS_WRITE=true` rewrites the list keeping the classes known. `docs/getting-started.md`, "Where state lives", says the rule; `CONTRIBUTING.md`: a new global needs a class.
- **`tests/canvas`**: the asynchronous read-back (`canvas_read_begin` / `_ready` / `_finish`) gives the bytes drawn, the same as `canvas_read`; one cancelled gives nothing and keeps nothing (its staging texture and query released, a finish after it writes nothing); a block out of the canvas is refused at the start; a block read across the canvas's corner is transparent beyond it.
- **`render.present_call`**: what a Present is asked for (the sync interval, the tearing flag, the mode the frame is presented in) from the mode asked, the tearing support, the interval and `frame_end`'s `vsync`; both backends take it from there (wgpu's `Immediate` or `Fifo`). `render/present_test.odin`: tearing only where allowed and never with a wait, the interval clamped to DXGI's limit, `vsync = false` at once.
- **`platform.file_dialog_call`** (Windows): what the Common Item Dialog is told for a `File_Dialog` (options set and cleared, the type list and the line selected, file name, default extension, the GUID of `remember_id`, the folder and whether it is forced), computed apart from the dialog; `DIALOG_OPEN`, `DIALOG_SAVE`, `DIALOG_FOLDER` name the kinds of `dialog_test_hook`. `tests/dialogs` checks an open, a save and a folder dialog's call without opening one.
- **`font.glyph_images`, `font.slug_glyphs`**: the bitmaps / Slug data of a whole run of glyphs, the atlas lock taken once, shared, for those already made: threads that draw at once look up side by side (8 threads: 17 ns per glyph instead of 120; 1 thread: 7 instead of 11). `draw.glyph_run` uses them. Every lock of the toolkit, what it guards and what was measured: docs/locks.md; `tools/text_bench -threads` times the locked paths.

### Changed
- **`ui.set_window_button_names`** translates the caption buttons of the current State only (each window's `ui.State` has its own names, English by default): call it after each `ui.init`. The interfaces' clock starts once for the process from any thread (atomic).
- **platform: a thread's state is the thread's, the process's is locked or atomic.** On Linux each thread that opens windows has its own connection to the display server (Wayland or X11: its events, its seat's focus and serials, its selections and drags, the cursor libraries made on it) and its own session bus (the a11y bus address, the colour-scheme subscription, the idle inhibitions); the loose Wayland and X11 state is in the connection's struct, the XCB functions bound on first use are in the library's table, and the Wayland protocol tables are built once with the library. On Windows OLE is initialized once per thread (`dragdrop_thread_init`, `drop_target_enable` and `drag_start` no longer call `OleInitialize` each time), the system cursors and pointer settings are the thread's, and the window class is registered once (`sync.Once`). The virtual screen of the offscreen windows is locked; the build number, the tray's message and ids, the ABI check of the accessibility library are atomic.
- **A public `ui` proc on a thread with no State** (no `init`, `use` or `begin_build` there) stops at once with `ui.NO_STATE_MESSAGE`, "ui: no begin_build on this thread", instead of crashing further on a nil State: one branch where the thread's State is read.
- **GPU profile**: both backends fold a step's timestamp into the profile with one procedure (`profile_add`: summed by kind, the slowest kept longest first, a clock that went back counts 0). `render/gpu_profile_test.odin` checks it on made-up timestamps; `tests/gpufx` checks `set_gpu_timing`: off nothing is measured, on each submit is timed and `gpu_result` names one of them with a time above 0.
- **`tools/tk`**: the PowerShell scripts of tools/ (build_text, build_a11y, build_naga, fetch_emoji, fetch_wgpu and the Linux fetch_wgpu.sh, gen_emoji_data, make_icon, make_logo, ppm_diff, emoji_board) are one Odin program, a command each with the same flags in Odin's spelling (`odin run tools/tk -- fetch_wgpu "-dest:build"`, `fetch_emoji -unicode`, `build_text -force`, `ppm_diff a.ppm b.ppm -tolerance:2`...), the same outputs, pins and stamps; `tools/shaders` builds naga in process. The static libraries of native/ are built once more after the change (their stamp now covers tools/tk/native.odin). Only tools/release.ps1 stays a script.
- **Word cache**: a shard's lock is shared by the threads that find their word in its current generation (a page's threads shaping the same words: 190 ns per word with 8 threads instead of 440).

### Removed
- **Wayland: the primary-selection listeners**: the toolkit bound `zwp_primary_selection_device_manager_v1`, made a device and tracked its offers, but never read one nor offered a selection (no source was ever made): the protocol tables, the listeners and their state are gone. On X11 a copy still owns `PRIMARY`.

### Fixed
- **render, flate: no global raced on.** A second window's swap chain is sized by an argument of `create_swapchain` instead of a global flag two renderers on two threads shared; the sRGB tables of the capture are made once (`sync.Once`) instead of behind a plain flag; the environment switches (`TOOLKIT_RENDER_TRACE`, `TOOLKIT_DAMAGE_VERIFY`) are read once atomically; `qpc_to_tick` asks the system's counter frequency instead of keeping it. `flate.deflate_runs`' code tables are made at start-up (`@(init)`, as the fixed codes) instead of lazily.
- **`odin run tools/run_tests -- -backend:wgpu -group:ci1`** from PowerShell selected no step: PowerShell 7 hands a `-name:value` typed after `--` to the program as `-name:` and `value` (odin passes on what it gets; from cmd or bash the flag arrives whole). `tools/cmdline` joins them again, for `run_tests`, `changelog` and `tk`; the docs say `odin run` again where they said to build the runner first.
- **IME (Wayland)**: the preedit's caret and the text the input method replaces wait for the protocol's `done` like the rest (the caret moved at once, the Backspace presses went out before the `done`). The composition is `platform.Ime_Compose` (`ime_compose_preedit` / `_commit` / `_delete` / `_done` / `_reset`, pure), the caret's rectangle in the compositor's units `ime_cursor_rect_logical` (at least one unit high); `tests/ime` feeds them the protocol's events.
- **Tray menus** (Windows): the default item of a menu is shown in bold (`AppendMenuW` ignored `MF_DEFAULT`: it is set with `SetMenuDefaultItem`). `platform.tray_menu_build` makes the native menu of a model without showing it; `tests/tray` reads it back with `GetMenuItemInfoW` (separators, check and radio marks, the default item, a disabled one, a submenu, each command's id).

## [0.63.1] - 2026-11-02

### Changed
- **The interface state a build works on is the thread's**: `ui`'s current state (what `begin_build` selects and the public procs use) is thread-local, so several apps of one process build and draw their interfaces at once, each on a thread of its own; before, two threads building at once broke each other's parent stack.

## [0.63.0] - 2026-11-02

### Added
- **`render.preload_device`**: the graphics device made early, on a thread of its own, while the program does the rest of its start; the next `render.init` / `init_window` / `init_offscreen` that asks for that kind of device (hardware or WARP) takes it, waiting for the thread if it has not finished, and makes only the swap chain or the offscreen target. The first device of a process loads the graphics driver, the longest step of a renderer's start. Its state is explicit (`render.device_preload_state`: `Not_Started`, `Creating`, `Ready`, `Failed`); a device of the other kind, or one that failed, is released and init makes its own as before; `render.release_preloaded_device` lets an unused one go. On wgpu the instance, adapter and device are made without a surface: init makes the window's surface on that instance and makes its own device when the adapter cannot present to it. `TOOLKIT_RENDER_TRACE` says how long init waited for it.

## [0.62.0] - 2026-11-02

### Added
- **`devtools.start_local`, `devtools.Local_Client`**: the protocol with no socket, for a program or a test that drives itself; `Toolkit.state` says how many pictures are being encoded.
- **`ui.set_clock`**: a state's time goes by a clock its owner moves: every delay and wake of the interface follows it, `wake_in_ms` and `wake_due` included. `Build_Params.time_ms` stays for one build.
- **`testkit/session`**: an `@(test)` procedure makes an application with no window of the system on the offscreen renderer, sends input through `platform.inject_event`, runs frames, reads widgets and real pixels, with barriers on a state (`wait_until`, `wait_idle`, `wait_box`) and a clock of its own (`advance`); `attach` drives an application that makes its own frames.

### Changed
- **`tools/changelog`** is an Odin program, tested by `tests/changelog`, in place of `tools/changelog.ps1` and `tools/changelog_test.ps1`; `-Migrate` (for an "## Unreleased" this repository does not have) is gone.
- **The tests are Odin**: `odin run tools/run_tests` runs every package on Windows and Linux (on Windows on a desktop of its own, and nothing takes the focus of whoever is at the machine), in place of `tools/test_windowless.ps1`, `tools/test_backends.ps1` and the test part of `tools/linux_ci.sh`; ten packages that no CI ran now do (`window`, `cursors`, `tray`, `dialogs`, `clock`, `size_move`, `i18n`, `planes`, `video`, `textures`). `tests/e2e/run.mjs` is `tests/examples/whatsnew_test.odin`, in the test's process. Guide: `docs/testing.md`.
- **`tests/examples`**: `examples/fidget` and `examples/todo` are tested in the test's process with no window and no input of the machine (`tools/keyboard_test.ps1`, `tools/fidget_test.ps1`, `tools/ui_test.ps1` are gone, so is fidget's `--state_title`); the examples have `open` and `close`, and a settings folder of their own for a test. Esc in fidget's command palette closes it, as its foot says, instead of only leaving its field.
- **Offscreen windows have a machine of their own**: `platform.virtual_screen_set` gives the screen `monitor_size` and `display_info` answer for them (no more `{0, 0}`), `platform.set_offscreen_active` their activation, and their clipboard is the process's store on Windows as on Linux: a headless program no longer reads or writes the clipboard of the person at the machine.

### Fixed
- **The caret of `line_edit` and `text_edit` wakes the loop at its flips only**: the wake came at every half phase (265 ms), which drew each picture of the caret twice.
- **The plain text clipboard of an offscreen window on Linux**: `get_clipboard` gave nothing and `set_clipboard` did nothing, while `clipboard_set` kept to the process's store: a headless program could not copy and paste its own text.
- **One clock for the interface**: a scroll bar's reveal (`scrollbar_reveal`) and the merging of typing into one undo step in a line edit read the system's clock whatever `Build_Params.time_ms` said; a replay or a test with its own clock got other results.

## [0.61.0] - 2026-11-01

### Added
- **Color glyphs off Windows**: the COLR interpreter gets its tables from the native backend, and CBDT bitmaps (Noto Color Emoji on most Linux systems) are drawn from their PNG images (`font/cbdt.odin`). `font.glyph_is_color` and `font.color_glyph_rgba` work there.
- **Fractional scaling on Wayland**: `wp_fractional_scale_v1` with `wp_viewporter`, the buffer in physical pixels; a scale of 1.5 was drawn at 2 and scaled down by the compositor.
- **Cursors on Linux**: on X11 from the theme (libxcb-cursor) or the server's cursor font, custom images through RENDER; on Wayland custom images through wl_shm and the theme (libwayland-cursor) where `wp_cursor_shape_v1` is missing, and the cursor is sent again on each pointer enter. `platform.cursor_on_screen` says what shows.
- `tools/doc_check.mjs`, run by the CI: the files, flags, defines and package names the documentation cites must exist. `tools/release.ps1` retakes the About picture itself. The documentation no longer says Linux is missing where it exists, and says what it lacks (color glyphs, X11 cursors, Wayland fractional scaling).

## [0.60.2] - 2026-11-01

### Added
- `tools/theme_shots.mjs`: a picture of a page of `examples/whatsnew` in every palette, with no window; `--palette=<name>` on that example.

### Fixed
- **Command line arguments keep every character on Windows**: `os.args` came through the C runtime's ANSI code page ("Łódź" became "L\xf3dz", "Привет" "??????"), in paths and passwords too. Any program that imports `platform` now gets them from the system, in UTF-8.

## [0.60.1] - 2026-11-01

### Changed
- **The letters of a match are drawn dark**, in the theme's new `find_text`, on stronger `find_match` and `find_current` backgrounds: amber code and light text did not read on them (contrast 1.8 on the current match). At least 4.5 in every palette.

### Fixed
- **Find and selection show over inline code**: a rich paragraph painted its runs' backgrounds over them, leaving a pixel at each end of a match. They now lie between the backgrounds and the text.

## [0.60.0] - 2026-11-01

### Added
- **`Rich_Context.line_height`** and `rich_paragraph(line_height = ...)`: every line of a paragraph the same height, on a baseline from its base font, whatever other faces it holds (CSS `line-height`). Inline code no longer has to push a line apart.

## [0.59.0] - 2026-11-01

### Added
- **`draw.image_cover`** and `draw.cover_src`: an image that fills a box cropped rather than distorted (CSS `object-fit: cover`). `examples/effects` uses it: its photo was stretched into every thumbnail.
- **`ui.set_scrollbar_autohide`**: scroll bars show only while the pointer is over their box or one is held, and fade otherwise. `ui.scrollbar_reveal` shows one for a moment when something else scrolls it (the keyboard); `ui.scrollbar_opacity` says how much it shows. Off by default.

### Changed
- `tools/screenshots.mjs` replaces `tools/screenshots.ps1`: the pictures are the frames the examples render, over the DevTools protocol, with an empty settings folder; it no longer moves the mouse, raises windows or moves the user's settings aside. It also refreshes `site/img`. `fidget`, `todo`, `transforms` and `effects` answer to `TOOLKIT_DEVTOOLS`.

## [0.58.0] - 2026-10-31

### Added
- **`ui.scrollbar_rects`**: the track and the thumb a scroll box shows, for tests and tools.
- **`platform.window_on_destroy`**: a call when a window is destroyed, for what keeps a pointer to it and may outlive it.
- **`devtools`**: Ctrl+Z and Ctrl+Y in Chrome's DevTools: `DOM.undo` and `DOM.redo` go over the edits of styles, texts, removed boxes and `aria-label`, from mark to mark.
- **`devtools`**: `aria-label` can be edited from Chrome's DevTools (`DOM.setAttributeValue`, `DOM.setAttributesAsText`, `DOM.removeAttribute`): it changes what a reader gets. The other attributes are refused with a message that says why.

### Changed
- **`Text_Area.sb_drag`** and **`Text_Edit_Draw.bar_hot`** are a `ui.Text_Scrollbar`, not a number. `Field_Snapshot` and `Text_Snapshot` are one type, `ui.Edit_Snapshot`.
- **Double click**: widgets and selected text share one time, 450 ms (widgets counted 400 ms, selected text 450 ms).

### Removed
- **`ui.Picker_Draw.ring`**: never read.

### Fixed
- **A command to the DevTools server could wait until something else woke the window**: its wake could be taken by the frame already starting, and the window slept with the command in its inbox. The ticker now wakes it for as long as a command waits.
- **`examples/whatsnew`**: its title says the version it runs on, from `ui.VERSION`, and that its pages are the changes of 0.55 (it said "What's new in gui_toolkit 0.55" in every version).
- **Examples**: a live resize no longer stretches the last frame in any example (composition swap chain, `render.set_fixed_surface`, `render.pace_frame`; `--bench` of `effects` and `transforms` keeps the ordinary swap chain its published figures are of). `examples/hello`, which a new program copies, has the three lines and `docs/getting-started.md` explains them; `tests/resize_probe` checks a program from outside.
- **`font.colr_dump`**: every transform is listed with its matrix, read by the same decoder as the interpreter.
- **`font.colr_nests_glyph`**: a paint whose fields run past the COLR table now counts as unreadable (the interpreter already refused it), instead of being left to Direct2D.
- **`render.capture_poll_raw` and `render.capture_raw_finish`**: the two halves of `capture_poll`, so that a read-back only costs the copy of its rows on the thread of the frames; the devtools take the picture on the encoder thread. The table of an fp16 window is no longer built for an 8-bit one.
- **WebGPU: a backdrop or a blend mode in a frame of a region reads the frame being composed**, not the surface texture, which was still empty.
- **WebGPU: frames of an offscreen renderer wait for the device**: with no present to pace them they piled up on a slow device, and a read-back waited behind them for up to minutes.
- **`render.damage.verify` compares with the frame really drawn whole**, all its steps run again on the side, instead of a recomposition that sampled pooled textures already reused. `-define:TOOLKIT_DAMAGE_CHECK=true` runs that proof on a program that marks nothing.
- **`draw.destroy` leaves the context empty**: `draw.init` on the same struct appended to the lists it had freed, and frames drew garbage.
- **Partial redraw: a frame with a backdrop or a blend mode into the frame is drawn whole**: outside the region it would have read the last frame's finished pixels, and a kept backdrop kept them.
- **Partial redraw: a batch that reaches two rectangles of a region no longer draws what lies between them**, where translucent text and shapes piled up on the last frame; rectangles fused over the budget no longer overlap (drawn twice).
- **`rich_paragraph`**: a `version` given again for shorter runs, or two contents with one hash, lays the runs out again instead of indexing past them.
- **`ui.destroy` after `platform.destroy_window`** no longer writes to the freed window, and a post no longer wakes it: the State forgets a window when it is destroyed.
- **`.Hot_Within`** sees as far up the tree as `hot_within`: 64 ancestors (it stopped at 48).
- **Toolkit drawing at high DPI**: the tab underline, the rings of check boxes, radios and color pickers, the slider's ring and the shadows of sliders and switches, `hline`, what takes a press around a scrollbar and its least width follow the scale. At 100 % nothing changes.
- **Linux, Wayland**: a clipboard or drag source and a selection offer given up are destroyed on the compositor too (only the client side was freed).
- **Windows**: a drag of the app over another of its windows is taken as over the window it came from (the thread in `drag_start` cannot answer before the drop).
- **`wait_event`** (offscreen window, Linux): events already handed out by the last poll no longer end the wait at once.
- **Linux**: `open_url`, `open_path` and `reveal_in_folder` leave no zombie process.
- **Linux, Wayland**: only a window made a drop target with `drop_target_enable` takes a drop, as its answer in `drop_set_effect` says; `drag_start` shows its picture; the press that began a drag gets its release when it ends.
- **Linux, Wayland**: closing a window no longer ends the connection with a protocol error (a wrong request destroyed its decoration).
- **Linux, X11**: `get_placement`, `outer_rect` and `client_origin` read the window's position (they said 0,0); a placement saved and restored under a frame does not move the window.
- **Linux, X11**: a waiting poll no longer sleeps over events already read from the connection.
- **Linux, X11**: `clipboard_changed` sees any program taking the clipboard, through XFIXES.
- **Linux, X11**: `display_info` gives the rate of the monitor under the window, read from RandR, and follows it when the window moves or the mode changes; 60 Hz only without RandR.
- **Linux, X11**: `drag_start` shows its picture (`Drag_Image`), carries the formats of the app's own (`Drag_Data.custom`) and follows `XdndProxy`.
- **Linux, X11**: with several windows, each event goes to the window it names, not to the window that polls; drops report the pointer's position (it was always the corner of the screen).
- **Linux, X11**: copy and paste with other programs work: requests and answers were read at the wrong offsets of their events, and the transfer of large data never advanced.
- **`devtools`**: `frameMs` (`Toolkit.metrics`, `Toolkit.frames`, timelines) is taken before a capture is read back, and a capture's conversion to RGBA moved to the encoding thread: a frame that reads a picture back no longer reads as late, with the next one early, although no refresh was missed.
- **`devtools`**: the screencast takes one more capture after a change, so what the program does in answer to the frame just shown is not lost as its last frame.
- **`dbus`**: a bus that goes away with something of ours unread (ECONNRESET) is a lost connection: pending handlers run, as on an orderly end.
- **`dbus.call`**: a call in a handler while another call waits: each gets its reply, whatever their order, where the outer one timed out; what an outer call had read no longer waits for the inner call's timeout.
- **Recorder**: with `injected`, an action sent by `Toolkit.axAction` is recorded, as a `press` line that does it again.
- **Recorder**: the horizontal wheel is recorded, and `wheel <x> <y> <notches> [<across>]` plays it (`tools/cdp.mjs`).
- **`devtools`**: what Chrome's frontend asks as it goes is answered (`CSS.takeComputedStyleUpdates`, `Storage.getStorageKey`, `DOM.getNodesForSubtreeByStyle`, `DOM.getAttributes`, its check for form-associated elements) instead of filling its log with errors.
- **`devtools`**: `DOM.getDocument` and `DOM.requestChildNodes` respect the depth asked. Children the client has are no longer sent again (Chrome's frontend made new nodes of them, and what it was unfolding stayed empty), and a node not unfolded says when its number of children changes (`DOM.childNodeCountUpdated`).
- **`font`**: the native backend no longer takes quadratic time on a very long word without a space.
- **`flate.deflate_push`**: a stream past 2 GiB no longer stops finding matches.
- **`flate.inflate_push`**: a big block that arrives in many chunks is no longer decoded again from its start with each one (quadratic time): its output comes as its input arrives. Inflating and deflating no longer fill the temporary allocator.
- **`font.color_glyph_rgba`**: emptying the outline cache of the COLR interpreter freed heap memory with the allocator of the caller: a caller with its own allocator got bad frees.
- **`font`**: when Direct2D could not make its device for color glyphs, the locks held at that moment were zeroed under their owner: the failure now only gives back the Direct2D objects.
- **`font`**: a hostile COLR font can no longer hang the drawing thread with an outline of many crossing edges: the scan conversion of a glyph counts against its work allowance, and a glyph over it is refused.
- **`font`**: a hostile COLR font can no longer exhaust memory or hang through color lines: the stops of a gradient count against the work allowance of a glyph (a graph that reads too many is refused and shows its outline), and finding a stop no longer walks along them.
- **A device lost on one renderer no longer fails the read-backs of another** (`draw.offscreen_end`, `render.readback_poll`), and the table of read-backs is safe when renderers live on several threads.
- **A buffer refused or not mapped during a frame no longer writes through a null pointer** (Direct3D 11): the frame draws what it can and `frame_end` reports the lost device.
- **`render.kept_targets_bytes` counts as `render.targets_bytes` does**: a kept snapshot is 4 bytes a texel, and mip chains count.
- **`render.capture_cancel` on WebGPU no longer lets the map it cancelled write on the next capture**, and a capture being mapped survives `surface_use`.
- **`draw.destroy` gives back the context's glyph atlas texture**: a context made and destroyed on a renderer that stays left it behind.
- **A layer in a blend mode composited right after a filter pass replaces what it read, as any other** (Direct3D 11): with nothing drawn in between it blended over translucent pixels and changed their alpha.
- **`render.set_gpu_profile` no longer erases the frame's clear color on a window** (Direct3D 11): what no draw covered turned black while profiling.
- **2D canvas: a clip that lies off the canvas, or one made while a layer is open, no longer sends what is drawn next to the wrong target** (into the clip mask, or to the canvas instead of the layer).
- **Partial redraw (`draw.damage_begin`, `render.set_partial_redraw`) works as documented on both backends**: on Direct3D 11 it never took effect on a window and wiped what lay outside the region offscreen; on WebGPU a window crashed on it, the region was not cleared first, and a frame without a region left the next one showing stale pixels.
  - A frame with a region now composes into a kept target, copied whole to the swap chain (the swap chain cannot present rectangles). A region of nothing presents nothing. Frames without `damage_begin` are drawn as before.
  - `damage_scroll` redraws where the content was and is: no backend moves pixels by a block copy.
  - `render.damage_verify_differences` counts the frames `render.damage.verify` found different, and the check now runs on Direct3D 11 and draws Slug text and application shaders on WebGPU.
- **Wrapped text**: the lines kept between builds no longer live in the allocator of the context at the first wrap (a program that changes `context.allocator` around a build freed them from another one).
- **`ui.fuzzy_score`** no longer panics on a text with invalid UTF-8 that matches the needle, and its ranges stay in the text.
- **`rich_paragraph`**: `rich_set_faces` applies to paragraphs already laid out, and the layout cache no longer depends on the padding bytes of a run's style.
- **`ui.post` through a window**: after `ui.destroy` every window the State was built for returns false, not only the last one (the others used a queue that was gone).
- **`line_edit`, `text_edit`**: a value set by a screen reader can be undone, and a selection it asks for in the same build lands on the new text.
- **`line_edit`, `text_edit`**: Backspace at the start or Delete at the end of the text is no edit: it no longer empties the redo history nor adds an undo step.
- **Autoscroll**: the distances and the speed of `Autoscroll_Settings` are logical pixels as documented: at 200 % the dead zone was half as large and smaller than the marker.
- **Autoscroll**: a middle press on a box that scrolls itself (`text_edit`) no longer starts a session that scrolls nothing and swallows the press; the scroll region around it scrolls, if there is one.
- **Autoscroll**: the click that ends a latched session does nothing else (it moved the focus, jumped a scrollbar and reached the selection).
- **`ui.modal`**: Escape goes first to what is inside the dialog (a focused field gets `cancelled`), then to the dialog on top, not to the outermost one. The dialog closes at the end of its block.
- **`ui.list_select`** before a list's first build, or for a row added in this frame, is no longer lost: the row is checked against the rows actually built.
- **`ui.selected_text`** during a build no longer returns "" when the selected boxes are not built yet (a Copy button above the text): it answers with the text the last build showed.
- **Linux**: `clipboard_changed` tells a change once (it said true at every call while another program owned the clipboard), `clipboard_formats` says what the owner offers, `set_clipboard` offers its text under the text targets, and file lists are percent-encoded URIs.
- **Linux**: `wait_handle` with no limit called inside a frame callback waits for the handle (it returned at once).
- **`drag_image_fit`**: the colours stay right when a large picture is brought down to a few pixels (the sums overflowed).
- **Windows**: `get_placement` returns screen coordinates: with a taskbar on the left or top a saved window no longer moves at each restore.
- **Linux, X11**: `is_minimized`, `is_maximized` and `is_fullscreen` follow the window manager (a restored window stayed minimized).
- **Linux, X11**: a read of a selection returns the whole data or nothing, never a truncated part, and a slow owner's transfer goes on as long as chunks come.
- **Linux, X11**: a drag no longer makes the app take itself for the clipboard's owner, and losing PRIMARY is no longer taken for losing the clipboard: paste reads what another program copied.
- **Linux, X11**: `drag_start` talks XDND to the window under the pointer (it reached no window), reports the effect the target took, and no longer leaves the press stuck; drops report client positions and follow `drop_set_effect`.
- **Linux, Wayland**: a click before any motion lands where the pointer is on a scaled screen (the position on entering the window was not scaled).
- **Linux, Wayland**: `drag_start` returns no effect for a drag that was cancelled (it returned the effect of the one before or the action last hovered).
- **Linux, Wayland**: reading another client's selection gives up when the peer stays silent instead of freezing the interface, and dropping the app's own drag on its own window no longer hangs it.
- **Linux, Wayland**: a held key repeats, at the rate and delay of the compositor (`Event.repeat`).
- **Linux**: `wake` wakes a real window's loop on Wayland (it did nothing) and no longer writes on X11 the property a paste reads, which could corrupt the pasted data.
- **Linux, Wayland**: a loop that polls without waiting (an animation) now receives input and answers the compositor: `poll_events(w, false)` reads the socket; `wait_handle` no longer spins while input waits.
- **`tk_instance`** (Linux): a runtime directory that is not this user's alone (`/tmp/tk_instance-<uid>` made first by someone else) is not used: the start carries on by itself.
- **`dbus.call_async`**: the handler runs when the bus goes away whatever its deadline, as documented; a message that cannot be one ends the connection instead of stalling it while its buffer grows.
- **`dbus`**: a full socket is waited for instead of being taken for a lost connection, so a burst or a large message no longer ends it.
- **`dbus.call`**: a reply followed by another message in the same read (Hello and NameAcquired) is no longer wiped before the caller reads it, which could make `connect_bus` fail now and then. A handler that calls no longer meets its own message again.
- **`tk_config.restore`**: bringing back a value over a saved user one marks the preferences dirty: the next start no longer gets back what the restore took away.
- **`devtools`**: a connection ending at once can no longer be reaped before its thread is known, and `accept` failing for good no longer takes a core.
- **`devtools`**: `inf` and `nan` are no longer taken as a CSS length, opacity or colour channel of an edited style.
- **`devtools`**: two `Page.captureScreenshot` at once each get their own `clip`: the second used to get the picture of the first.
- **`devtools`**: what cannot be edited (`DOM.setAttributesAsText`, `DOM.setOuterHTML`, other `DOM.set*` and `CSS.set*`, `Page.setDocumentContent`, cookies, DOM storage) answers an error instead of a false success; what clients send on attaching is still accepted.
- **`devtools`**: an edit lasts as long as its client also when it never asked for the document, and a second client taking the tree undoes the edits of the first instead of inheriting them for good.
- **`devtools`**: a text replaced from Chrome's DevTools, or edits taken back when it leaves, no longer leave the boxes of the last build pointing at freed memory (`ui.Box_Edit`'s text is copied into each frame).
- **`devtools`**: `Page.stopScreencast` while a frame was being read back no longer leaves the renderer unable to capture: `Page.captureScreenshot` answered "the renderer cannot capture now" for good and a later screencast sent nothing.

## [0.57.1] - 2026-10-31

### Fixed
- **The screencast could miss its last frame**: input sent while a capture was coming back, or the last step of an animation, counted as nothing changed. Tests: the end-to-end run waits for the frames to stop instead of fixed delays, and what still depends on a machine's timing (a first frame, the last one) is said as FLAKY without failing it; frames that never stop still fail it.
- **Closing Chrome's DevTools could leave a window on freed memory**: the connection was freed while the DOM side still held it, so the edits could stay and the program could hang. They now go with the client, every time.

## [0.57.0] - 2026-10-31

### Added
- **Chrome's DevTools on a window**: the Elements panel shows the box tree and follows it, Styles, Computed and Layout a box's rect and colours in sRGB, Styles and the text editable live for as long as DevTools is attached, the Accessibility tab what a reader gets, hovering a node lights its box. `tools/cdp.mjs inspect` prints the address; the `devtools://devtools` Origin is taken on the WebSocket only.

## [0.56.2] - 2026-10-31

### Fixed
- **`examples/whatsnew` no longer stretches while it is resized**: a composition swap chain with a fixed surface, as opencode native, and `inner = true` for the frames of a live resize. The other examples keep the ordinary swap chain, which stretches.
- **A lazy column's height changed at every frame** when an item showed nothing: its height of 0 counted as not known yet, so it stood for the mean of the others as a space and for nothing when built. A scroll box following its bottom had its scroll bar jump, without end.

## [0.56.1] - 2026-10-30

### Added
- **`flate.deflate_runs`**: compression at a high rate for what repeats in known ways, such as the rows of a picture: runs and matches a row above, in one block of the fixed Huffman codes.

### Fixed
- **A screenshot of a real window took two seconds and froze it**: the wake asked for its next frame was consumed by the frame already starting, so the window slept until its next timer (about 1.2 s); reading a translucent window's fp16 target back ran `pow` on every channel (now a table); the PNG was encoded on the UI thread (now `flate.deflate_runs`, made for rate, on a thread of its own). A timeline keeps its pictures in memory and compresses, compares and writes them when it ends. An offscreen window keeps its wakes, so the end-to-end run never saw the first one.

## [0.56.0] - 2026-10-30

### Added
- **Timelines**: `tools/cdp.mjs record --timeline <dir>` keeps a run whole (each action with when it happened, a picture after it, every frame's time), as a page that stands alone, a `timeline.json` and a Chrome trace; `play <timeline.json> --timeline <dir>` runs it again, `--realtime` with its pauses, and fails if a picture differs. `tools/timeline.mjs` for scripts. `Toolkit.frames` and `Toolkit.pollRecording` feed it.
- **`Page.startScreencast`**: the window's frames as events, one at a time, limited in rate, none at rest; `tools/cdp.mjs cast <dir>`.

## [0.55.0] - 2026-10-30

### Added
- **`tests/e2e`, in the CI**: `examples/whatsnew --headless` driven over the protocol: no layout warning, nothing a reader cannot name and the reference image on every page, the scenarios that broke before, exit code 0.
- **`Toolkit.waitFor` and `Toolkit.waitIdle`**: a script says what it waits for (a box there or gone, nothing moving) instead of sleeping a guess; `wait-for` and `idle` in `tools/cdp.mjs`.
- **A recorder**: `Toolkit.startRecording` / `stopRecording` (`tools/cdp.mjs record`, `play`) write what a person does as a script, clicks by what they hit rather than where.
- **`Toolkit.metrics`**: build, layout and frame times (p50, p95, max) of the last 240 frames, boxes, lazy items built, the accessibility tree's cost, and the latency input to screen in a `RENDER_PROBE` build. `ui.build_metrics` reads the last build's from the program.
- **Accessibility actions and audit over devtools**: `Toolkit.axAction` asks an action of a node by role and name as a screen reader does, `Toolkit.axAudit` (`ui.a11y_unnamed`) lists the controls a reader cannot name, which are not even nodes of the tree.
- **`devtools`: a window driven over the Chrome DevTools Protocol**: `devtools.start_from_env(win)` (TOOLKIT_DEVTOOLS=<port>, 127.0.0.1 only) and `devtools.service` each frame. Input.dispatchMouseEvent / dispatchKeyEvent / insertText go into the window's queue (no mouse or keyboard of the machine, no focus needed), Page.captureScreenshot returns the presented frame as PNG, Accessibility.getFullAXTree and queryAXTree the tree a screen reader gets, and the Toolkit domain reads the box tree (getTree, find, click by name or text). A request from a browser's page (an `Origin` header), for another `Host` or without the target's random id is refused. Puppeteer and Playwright attach (docs/devtools.md says what works). `tools/cdp.mjs` drives it from the command line; docs/devtools.md. `ui.box_text` and `ui.box_current` read a box from outside a build.
- **`examples/whatsnew`**: a page per change of this version, each shown live (frames presented at once, items a lazy column built, build times, the layout warning, the emboss, next_merge, find in page, box_at).
- **`ui.box_at(ids..)`**: the box of the last build at a path of ids from the root, for a test, a tool or an overlay working from outside a build.
- **`ui.next_merge(m)`**: adds to the pending `next` instead of replacing it, so a helper styles its box while its caller's width or position stay. `ui.merge_mod` is public and merges every field (flags added).
- **A lazy column, `ui.lazy_begin` / `ui.lazy_item`**: inside a scroll box only the items near the view are built, the others stand as one space of the height they had when last built (5000 wrapped paragraphs: 3 ms a frame instead of 100, a first frame of 12 ms instead of 1.4 s). An item never built stands as the mean height; one built at another width keeps its old height until it comes near the view; the view stays on the item it showed when heights change (after the layout, in the same frame); it also builds around where the view is heading (a wheel's burst), and asks for one more frame when the view still shows spaces. `lazy_begin(all = true)` builds every item (find in page). Like `row()`, the item is the block of the `if`: a column whose items all close empty (`if !lazy_item(...) { continue }`) is warned of.
- **`rich_paragraph(..., version = v)`**: with a version the layout cache finds the paragraph by its box and version instead of hashing all of its text at every frame; the caller changes the version when the text changes.
- **Layout warnings**: a percentage inside a box sized by its children (it resolves against a distant ancestor, often the window) is said once per box on stderr when it grows past half the window. On in debug builds; `ui.set_layout_warnings(s, on)`, and `ui.layout_warnings()` returns the messages for a tool or a test.
- **`platform.input_pending(w)`, `platform.event_is_input(kind)`**: whether input waits in the window's queue, read without taking it (the events stay for the next `poll_events`).
- **`render.Pacer`, `render.pace_frame`, `render.paced_present`**: the cadence model executed for a window, as applications wrote it by hand: the screen's plan adopted when the display changes, the swap chain's slot waited for, its latency set. It does not show input after a rest at once: measured, that one frame left the swap chain a frame deeper for the rest of the session. `examples/hello` uses it; docs/pacing.md.

### Changed
- **docs**: font-backend.md shows how a program with a Rust crate of its own builds the text backend into it (one Rust standard library per program) and why the prebuilt wgpu-native cannot join it on Windows; text.md documents find in page and its limits.
- **Tests that drive the global UI state refuse to run on several threads**: keyboard, status, states, ui_robust and a11y fail to compile without `-define:ODIN_TEST_THREADS=1`, with a message that says why (they failed with bad frees or never ended). `tools/test_backends.ps1` passes the define to a11y too.
- **A frame less between input and screen** (Direct3D 11): the renderer takes one of the swap chain latency object's counts for good, so a frame starts when the last one is on screen instead of queueing behind it. Measured in opencode native (RENDER_PROBE, a fast hand over a list, six runs each): 49 ms from input to screen before, 34 after, still 60 frames a second. The price: a frame that takes longer than a refresh waits for the next one.

### Fixed
- **Find in page no longer reads freed memory** when its scope is not built any more (a page left while the needle stays): such a scope finds nothing. It crashed the next layout.
- **WebGPU: no white window while the first frame compiles**: on Direct3D 12 with FXC the first frame's pipelines take seconds; the renderer presents the theme's background first, and says on stderr to put `dxcompiler.dll` and `dxil.dll` next to the program when that first frame took over a second.
- **The wheel moves the hover**: rolling the wheel without moving the mouse makes the pointer's position valid again, so the highlight follows the row that came under it instead of staying on one scrolled away.
- **Embossed text by contrast** (Gradient finish): the groove or the light edge comes from the text against what is under it (the box's own background or the nearest opaque one up), not from the text alone: grey text on a dark button no longer takes a light edge under it.

## [0.54.0] - 2026-10-30

### Added
- **`Build_Params.smooth_scroll`** (`Follow`, `On`, `Off`): whether scrolling glides, as the interface's animations say (the default) or always / never. An application can keep the wheel's glide when the system turns animations off (Windows' "Animation effects"), where every notch used to jump.

## [0.53.0] - 2026-10-30

### Added
- **Find in page** (`ui.find`, `ui.find_matches`, `ui.find_count`, `ui.find_set_current`): the occurrences of a needle in the text the interface shows (labels, wrapped paragraphs, rich text, a match across the runs of a paragraph), found after each layout in reading order with their rectangles whether on screen or scrolled away, painted behind the text (theme entries "find_match background", "find_current background"); case ignored. The application owns the field and the navigation.

## [0.52.0] - 2026-10-30

### Added
- **`tools/slugsmall`**: DirectWrite's bitmaps against Slug with each combination of its small-text settings, stacked in one PNG per scene and scale with a 3x enlargement (`odin run tools/slugsmall -define:FONT_BACKEND=native`).
- **Slug: four coverage samples per pixel** (`font.Settings.slug_supersample_ppem`) for glyphs at that size or less, on a rotated grid, each over its own half-pixel box. Off by default.
- **Slug: stem darkening** (`font.Settings.slug_darken`): every edge of small glyphs moves outwards by that many pixels at 12 px per em and less, fading out by 36, on the side the glyph's winding says (`Slug_Glyph.orient`). Off by default.
- **Slug: hinted outlines for small text** (`font.Settings.slug_hint_ppem`): screen-aligned glyphs at that size or less use an outline hinted for their size by the native backend's light auto-hinter (skrifa: vertical only, the baseline and x-height on whole pixels), cached per quarter pixel; `gt_glyph_outline_hinted`, `Text_Backend.outline_hinted`. Off by default.

### Fixed
- **Segmented controls**: the labels are no longer engraved (`button segment sheen` 0): lit below on the pill and shadowed above on the track, the selected and the other labels looked a pixel apart.

## [0.51.0] - 2026-10-29

### Added
- **A site** on GitHub Pages ([sachahjkl.github.io/gui_toolkit](https://sachahjkl.github.io/gui_toolkit/)): `site/`, published by
`.github/workflows/pages.yml`; the README tells about Linux.
- **A Linux job in the CI** (`tools/linux_ci.sh`, also for a local check in WSL): `odin check -vet` of every package for
Linux, the examples built with the native text backend and Vulkan, the tests that need no window. `examples/smoke`
printed the window's HWND, a field Windows only has.
- **`tools/fetch_wgpu.sh`**: wgpu-native's Linux static library, pinned by SHA-256, into Odin's `vendor/wgpu/lib` (Odin's
Linux release does not ship it).
- **`ui.fuzzy_score`**: subsequence matching for pickers and palettes ("cs5" finds "claude-sonnet-5"), the tightest window,
a score that ranks runs and word starts first, and the matched runs to highlight. **`ui.mouse_pressed`**: whether a
press happened in this frame, wherever it landed (a popover closed by a press outside it).
- **`ui.line_edit(..., secret = true)`**: a password field. Bullets are shown in place of the characters (the caret, the
selection and the clicks follow them character by character), a double click selects all of it, Ctrl+C / Ctrl+X do
nothing, and screen readers are told it is a password.

### Changed
- **Middle-click autoscroll** (`ui.autoscroll_axis_speed`): the speed grows geometrically with the distance from the anchor, `V * (2^(x/D) - 1) / (2^(F/D) - 1)` (`x` past the dead zone, `D` = the new `Autoscroll_Settings.doubling`, `F` = `full_dist`, `V` = `max_speed`): it doubles every `D` px and reaches `max_speed` at `full_dist`. `exponent` (a power curve) is gone.

### Fixed
- **`-vet` failed on the Linux code**: dbus casts, unused loop variables in the X11 backend, imports used on Windows only.
- **`-define:FONT_NATIVE_LINK=false` linked `kernel32.lib`** as its stand-in on every system: libc off Windows.
- **Linux: the text renderer defaulted to the atlas**, which nothing fills off Windows (no bitmap rasterizer): Slug there
(`FONT_TEXT_RENDERER`).
- **Linux: a translucent window asked for a half-float surface** that Vulkan on X11 / Wayland does not offer (BGRA8 only):
the surface's formats are checked, 8 bits a channel otherwise.
- **Linux: the WebGPU backend defaulted to Direct3D 12** on every system: Vulkan off Windows (`TOOLKIT_WGPU_BACKEND`). Found
by building opencode native for Linux, like the fixes below.
- **`ui.text_edit(wrap = true)`** could show a horizontal scrollbar: a wrapped text's width is the one of the last layout,
and when the box became half a pixel narrower the bar appeared, though wrapped text never scrolls sideways.
- **`ui.row` / `ui.column`** keep a cross alignment given by `next`: `next({cross = .Center}); if row() { ... }` centred
nothing, the scope's default (`.Start`) replaced it. An explicit `cross` argument other than `.Start` still wins.
- **`ui.checkbox`, `ui.radio`, `ui.toggle`** given no width are as wide as their mark (or switch) and their label: the row took
the text size of its own text, which is empty, so the clickable part was a sliver at the left of the mark (a click on the
label did nothing). A width given by `next` is kept, the label filling it as before.

## [0.50.0] - 2026-10-28

### Added
- **`font.glyph_outline` and a neutral `font.color_renderable`**: `glyph_outline(state, face, gid, tolerance, out)` hands a 2D canvas (or any glyph-path consumer) a glyph outline through the active backend (DirectWrite or the native Fontations backend) rather than a DirectWrite-only entry point, and `color_renderable` now answers on every system (off Windows the built-in COLR / CPAL interpreter draws colour faces). Both let an application draw glyph paths and build colour-font cascades the same way on every platform.
- **`platform.raise_window(window)` and `platform.is_window_visible(window)`**: bring an already-shown window to the front (Win32 `SetForegroundWindow`; X11 `_NET_ACTIVE_WINDOW`; a no-op on Wayland, where the compositor owns focus), and whether a window is on screen (mapped and not minimized). An application no longer calls Win32 for the "switch to this window" and "is this window visible" it needs around multi-window and capture flows.
- **Linux accessibility, IME and smaller desktop services** (`platform`): a minimal AT-SPI 2 accessibility bridge over D-Bus (`a11y_send` / `a11y_state` / `a11y_take_request` expose the toolkit's neutral tree — roles, names, states, bounds, Invoke / Focus — to screen readers when one connects); input-method composition through Wayland `zwp_text_input_v3` (`ime_set_enabled`, `ime_set_cursor_rect`, `ime_preedit`; committed text arrives as `.Text` events, and X11 composes dead keys through libxkbcommon); keeping the screen awake (`idle_inhibit` / `idle_uninhibit` through `org.freedesktop.ScreenSaver`); the recent-files list (`add_recent_file` to the freedesktop `recently-used.xbel`); and Wayland cursor shapes drawn by the compositor through `wp_cursor_shape_v1`.
- **Linux file dialogs, open-URL and live theme through the XDG portals** (`platform`): `open_file_dialog` / `save_file_dialog` / `pick_folder_dialog` now use `org.freedesktop.portal.FileChooser` first (filters, multiple selection, a suggested name; it works under a sandbox), falling back to zenity / kdialog; `open_url` / `open_path` use `org.freedesktop.portal.OpenURI`; `dark_mode_preferred` reads the appearance portal's `color-scheme` and the new `watch_color_scheme(cb)` reports a live light / dark switch (the `SettingChanged` signal).
- **Linux tray icon and notifications** (`platform`): `tray_create` / `tray_notify` and the rest of the tray API now work on Linux through the StatusNotifierItem specification over D-Bus, with its menu as a `com.canonical.dbusmenu` tree and notifications through `org.freedesktop.Notifications` (clicks, chosen menu items and notification results come back as `Tray_Event`s). Same public API as the Windows backend; `tray_create` returns nil when there is no status-notifier host, as Windows does when the shell refuses an icon.
- **Linux cross-process clipboard and drag-and-drop** (`platform`): the clipboard owner is now complete on both backends — a full Wayland `wl_data_source` offering text / HTML / PNG / `text/uri-list` (and reading a foreign owner over `wl_data_offer.receive`), the `zwp_primary_selection_v1` primary selection, and an X11 `SelectionRequest` server with `TARGETS` / `TIMESTAMP` / `MULTIPLE` and INCR for large images; `clipboard_get_image` / `_get_html` / `_get_files` read whatever another process owns. Drag and drop works both ways with the same API as Windows (`drop_target_enable`, `drop_data`, `drag_start`, `drop_inject`): Wayland `wl_data_device` and X11 XDND version 5.
- **D-Bus client** (`dbus` package): a small, pure-Odin D-Bus client for the toolkit's Linux desktop services, with no libdbus link (a binary starts on a machine without it and reports the bus unreachable). It connects to the session or system bus (`connect_bus` / `connect_bus_address`), authenticates with SASL EXTERNAL, does the Hello handshake, marshals and unmarshals the whole type system (basic types, strings, object paths, signatures, arrays, structs, dicts, variants, with the spec's alignment and byte order), calls methods synchronously (`call`) or asynchronously (`call_async`), subscribes to signals (`subscribe`), exports objects (`export_object`, `request_name`) and folds its socket into a program's own `poll(2)` loop (`conn_fd`, `dispatch`). `dbus/*.odin`, docs/dbus.md.
- **Test building blocks** (`testkit.Ports`, `testkit.process_state`): a new package with the parts of a test harness that are pure Odin and not tied to any one application. `Ports` gives each test run its own block of test-server ports (an application sets a base-port environment variable, a default base and a span): the tests write the default ports and `url` / `port` move every address to the run's block so several worktrees test side by side, interning the results. `process_state` reads the process's resident and private memory, its open handle count and (on Windows) its GDI and USER object counts for endurance and leak tests, and `memory_split` (Windows) shows where the private bytes are — the heaps' allocated against committed, and the private committed pages outside the heaps split read-write vs executable. `testkit/ports.odin`, `testkit/process_<os>.odin`, `tests/testkit`, docs/testkit.md.
- **Single-instance mechanism** (`instance.acquire`): a new package so an application can keep one running copy per named resource. The first process to start with a name owns it; a second start hands an opaque message to the first and comes forward instead of opening a second copy on the same state. The interface is platform-neutral — a name (`key(prefix, path)`), an optional identity token the owner checks so only a copy it trusts hands over, an opaque `[]byte` message the package never reads, and a handler the owner runs while it pumps messages — with no window handle, executable semantics or OS type crossing it. Under it: a named mutex and a message-only window (WM_COPYDATA) on Windows, a `flock` lock file and a Unix socket in `$XDG_RUNTIME_DIR` on POSIX (`instance_windows.odin`, `instance_linux.odin`, `instance_other.odin`). An owner that is starting or closing is waited for; a silent one does not hold the second start. `acquire`, `send`, `owner_start` / `owner_closing` / `owner_stop`, `pump_messages`, `raise_window`, `is_elevated`. `tests/instance`, docs/instance.md.
- **Lifetime and ownership primitives** (`arena.Scope`, `arena.Pool`): a new pure-Odin package with the two primitives an application builds its object graph on. A `Scope` owns a growing virtual-memory arena plus a reverse-order cleanup list and may have child scopes, so closing a scope closes its children, runs its cleanups and frees the arena in one go — an application is a tree of scopes and "close the view" frees everything without any subsystem keeping a list of what it owns (`scope_make`, `scope_allocator`, `on_close`, `forget_cleanup`, `rebind_cleanup`, `run_cleanup`, `scope_close`). A generational `Pool` gives fixed-address slots addressed by a `Handle` (a `distinct u64`, generation + index) that can never dangle: removing an object bumps the slot's generation so an old handle fails to resolve instead of reaching whatever reused the slot (`pool_insert`, `pool_get`, `pool_valid`, `pool_remove`, `pool_handle_at`, `pool_next`, `pool_destroy`). `arena/scope.odin`, `arena/pool.odin`, in-package tests, docs/arena.md.
- **Typed preference registry** (`config.Prefs`): a new pure-Odin package — an about:config for any application. Every tunable is a named, typed, documented preference with a default, optional bounds or a choices list, a unit, and a layered source (default < user file < command line < policy, where a policy value also locks it). The registry validates every change, resolves a name to a `Ref` once so hot-path reads never hash a string, notifies observers by name prefix (`config.watch`, apply without a restart), persists only the user's changes atomically (`save_user` / `load_file`, values read before their definition applied later and surviving a round trip), snapshots and restores the whole set (`snapshot` / `restore`), and derives readable titles, a first-sentence summary and a word search for a settings UI (`title_of`, `summary_of`, `matches`). `config/config.odin`, `config/snapshot.odin`, `config/titles.odin`, in-package tests, docs/config.md.
- **`platform.monitor_size(window)`**: the pixel size of the monitor a window is on, neutral across systems (Win32 `MonitorFromWindow` + `GetMonitorInfoW`, the Wayland `wl_output` mode, or the X11 root screen). An application that wants a fixed surface the size of the screen (`render.set_fixed_surface`) no longer needs its own Win32 call.
- **Linux desktop services (`platform`)**: file dialogs (`open_file_dialog` / `save_file_dialog` / `pick_folder_dialog`) through zenity or kdialog; `open_url` / `open_path` / `reveal_in_folder` through xdg-open; `known_folder_path` from the XDG user directories; light / dark (`dark_mode_preferred`) and reduce-motion (`os_animations_enabled`) from the GTK settings; the rich clipboard (`clipboard_set` / `clipboard_get_*`) with text carried over the X11 CLIPBOARD selection and the Wayland `wl_data_device`, and HTML / image / files kept by the owner. `render/wgpu_surface_linux.odin` builds the wgpu surface from `Surface_Handles` (Wayland / XCB) for the renderer's Linux path.
- **wgpu is the renderer's Linux backend**: on a non-Windows target `render` builds the WebGPU backend only (`TOOLKIT_RENDER` is ignored there and `USE_WGPU` is forced on). The Direct3D 11 backend (`render_d3d.odin`, `frame.odin`, the canvas, slug, video, app-shader and damage files) is now built only for the Direct3D backend (`when !USE_WGPU`, Windows); the shared types (`Renderer`, `Texture_Data`, the frame description) and the backend-agnostic procedures build on every system. The wgpu surface comes from `platform.Surface_Handles` (Wayland `wl_display` + `wl_surface`, or XCB connection + window); present pacing on Linux is the FIFO vblank (there is no DWM timing or waitable-timer latency object). wgpu-native must be built for Linux (`libwgpu_native.a`).
- **Linux window backend (`platform`)**: `platform.open_window` and the whole window / input API now run on Linux, over **Wayland** (xdg-shell, `wl_seat` with an xkbcommon keymap, `wl_output` scale for DPI, zxdg-decoration or a client-side title bar) and **X11** (XCB, xkbcommon, `Xft.dpi`, `_NET_WM_STATE`, Motif hints), chosen at open from `WAYLAND_DISPLAY` / `DISPLAY`. Every window library is loaded with `dlopen` (libwayland-client, libxcb, libxkbcommon), so a binary starts on a system missing one and names it; nothing is hard-linked. The same `Window`, `Event`, `Key`, `Cursor`, `Placement` types as the Win32 backend — an application written against `platform` does not change.
- **Text catalogue** (`i18n.tr`): a new pure-Odin package so an application can be translated without going through its code again. `tr` is a procedure group with three forms — `tr(text)`, `tr(context, text)` (a translator's context for two meanings of one English word) and `tr(count, one, other)` (count-dependent forms, the choice left to the language). The English literal is the key; today each call returns its argument (same bytes, no lookup, no allocation), so a call in an interface drawn every frame is free, and a language can later swap in one flat pointer-keyed table without any other change. `i18n/i18n.odin`, `tests/i18n`, docs/i18n.md.
- **Partial redraw (damage regions)** (`render.set_partial_redraw`, `draw.damage`): the renderer can now repaint and present only the part of the window that changed since the last frame (a caret, a hover, a progress bar, a video, a local animation) instead of the whole window. The application opens a region with `damage_begin` and marks changed boxes with `damage_add` / `damage` (and `damage_scroll` for a scrolled view); the region is the bounded union of the boxes (near ones merged). The renderer clips every frame-target batch to the region, clears only the region, and presents it: Direct3D 11 with `Present1` dirty rectangles and a buffer-age redraw for the flip swap chain's un-kept back buffers; WebGPU composes into a persistent target and copies it to the surface (wgpu-native has no present-with-damage yet, a documented limit). A frame that marks nothing draws and presents nothing. `render.damage.verify` (`set_damage_verify`, or `TOOLKIT_DAMAGE_VERIFY=1`) renders every frame in full too and reports the first pixel that differs. Off by default (the whole window every frame, as before). `render/damage.odin`, `render/damage_d3d.odin`, `render/damage_wgpu.odin`, `render/damage_verify.odin`, `draw/damage.odin`; docs/draw.md, docs/webgpu.md.
- **`font.color_glyph_rgba`, `font.glyph_is_color`, `font.Color_Glyph`**: rasterize one color glyph (COLR / CPAL, sbix, CBDT, SVG) to a straight-alpha RGBA bitmap at an exact em size, with the offset from the pen to the bitmap, outside the glyph atlas and the draw layer, for a caller that composites it itself (a 2D canvas drawing emoji in `fillText`). It reuses the COLR interpreter for the glyphs it owns and Direct2D otherwise; `fg` colors foreground / text-color layers. The signature is platform-neutral; off Windows the functions compile and report no color glyph until a portable rasterizer lands. See docs/text.md.
- **`font.cascade` `language`**: a cascade now carries the content's BCP 47 language (`cascade(s, entries, features, no_system_fallback, language)`), and the shaper passes it to the backend as the shaping locale (DirectWrite's `GetGlyphs` / `GetGlyphPlacements` locale name, HarfRust's buffer language). Faces then apply their language-specific forms (`locl`): Serbian and Macedonian Cyrillic, Han unification of CJK ideographs, Romanian ș/ț, and so on. Empty keeps the previous default (no locale), and two cascades differing only in language are distinct `Font_Id`s, so the word cache tells them apart. See docs/text.md.
- **Frame capture on WebGPU** (`render.capture_request` / `render.capture_poll`): reading a frame back without the screen now works with the WebGPU backend, not only Direct3D 11. Before the present, `frame_end` copies the frame target (surface or offscreen, in whole or in part) into a mappable buffer; `capture_poll` maps it without waiting (`Pending` until the GPU is done) and returns straight RGBA8 with sRGB values and alpha forced to 255, the same picture the Direct3D path gives. It costs nothing until a capture is asked for, and works with the window covered, off the screen, hidden or minimized (`render/capture.odin`).
- **`render.surface_*` on WebGPU**: a second window drawn by the same renderer now works with the WebGPU backend, not only Direct3D 11. `surface_init` / `surface_use` / `surface_destroy` create a per-window WebGPU surface (with its own present and latency state, and the DirectComposition visual for a translucent window) and swap it with the renderer's window state, mirroring the Direct3D path. The device, queue and pipelines stay shared (`wgpu_surface.odin`).

### Changed
- **`platform` API made system-neutral**: `platform.wake_handle` now returns an opaque `rawptr` (paired with the new `platform.wake_signal`) instead of a Win32 `HANDLE`, and the new `platform.native_surface_handles` hands a renderer the window's native handles through a neutral `Surface_Handles` (Windows HWND, Wayland `wl_display` + `wl_surface`, or X11 connection + window) so `render` can make a surface on any system without a Win32 type in the signature.
- **`render.init` takes a neutral surface, not an `HWND`**: `render.init(&r, surface: platform.Surface_Handles, size, transparent, space)` opens the renderer on the native handles the platform package fills (`platform.native_surface_handles(window)`), the HWND on Windows and the Wayland or XCB handles on Linux; `render.init_window(&r, window, size, ...)` is the convenience form. `surface_init` / `surface_create` (second windows) take the same neutral handles. No Direct3D, DXGI or Win32 type appears in the renderer's public signatures.

## [0.49.0] - 2026-10-27

### Added
- **`ui.text_edit` syntax colouring** (`ui.Text_Highlight`, `ui.Text_Span`): a `highlight` parameter draws coloured runs the caller classifies per visible paragraph (`spans`), underlines paragraphs a caller's validator rejects (`error_line`), and reports the paragraph under the pointer (`Edit_Result.hover_line`) for a per-line tooltip. The editor knows no language; the cost is only the visible lines'.
- **Middle-click autoscroll** (`ui.set_autoscroll_enabled`, `ui.Autoscroll`): a press of the wheel on a scroll region drops an anchor and the pointer's distance from it scrolls, the farther the faster, along a tunable acceleration curve (dead zone, power shape, speed cap), as Chrome and Firefox do it on Windows. Hold mode (keep the button down) and toggle mode (a quick tap latches it until the next click) are both live; a direction cursor and an anchor marker show while it runs. Off by default; `scroll_y`, `list` and `vlist` get it once an app opts in. The curve and state machine are a pure, frame-rate-independent core (`ui.autoscroll_axis_speed`, `ui.autoscroll_velocity`) an application can reuse for its own view; see docs/autoscroll.md.
- **`ui.reorder_visible`**: the half-open range of items a scrolling reorderable list shows (scroll, view and pitch, with a margin on either side), so a long list builds only the rows in view and a frame's cost stays flat whatever the list's length.
- **`fsx`**: a platform-neutral package of file helpers with the guarantees a persistent store relies on, on every system (`fsx_windows.odin`, `fsx_unix.odin`): `write_atomic` (write through a `.tmp` renamed over the file, a reader sees old or new), `read_all` / `write_parts` / `replace` / `read_at` / `stat` / `delete_file`, `make_dirs` / `list_files`, `path_kind` (links never followed), `remove_tree` (one entry at a time, not through the Windows shell) and `temp_dir`. No Windows or POSIX type crosses the boundary. See docs/fsx.md.

## [0.48.1] - 2026-10-27

### Fixed
- **`ui.NAMED_PALETTES`**: the text of the One Dark and Solarized palettes is lighter (One Dark's bright white `#c8ccd4`, a step between Solarized's `base1` and `base2`): their schemes' own foregrounds stood too close to the lit tab of a tab bar in Wren.

## [0.48.0] - 2026-10-27

### Added
- **`ui.NAMED_PALETTES`**: eleven more palettes from well-known editor schemes, each with its own accent: Gruvbox and Gruvbox Light, Naysayer, Solarized and Solarized Light, Monokai, Tokyo Night, Catppuccin (Mocha) and Catppuccin Latte, One Dark and Everforest. `palette_named` finds them by name; a test checks that every named palette keeps its text legible on its background and panels and its `dark` flag in line with its background.

## [0.47.2] - 2026-10-27

### Changed
- **The native libraries are built without fat LTO again** (`tools/build_text.ps1`, `tools/build_a11y.ps1`): with it (`gt_text.lib` 6.4 MB instead of 33 MB) the `text` tests crashed on the CI runner at their first test (`atlas_stress`, a signal) while they pass on a development machine; the cause is not found, and the size is not worth a crashing test run. Wren builds these crates into its own library and is not affected.

### Fixed
- **The text tests no longer fail now and then on a CI runner** (`text_test.atlas_stress`, "Signal caught: Unknown", sometimes a runner that never ended): DirectWrite throws C++ exceptions and catches them itself when an entry of its process-wide cache does not fit, and the Windows test runner of `core:testing` takes any exception on a test's thread for a crash and kills that thread. The tests of `tests/text`, `tests/color_glyphs` and `tests/text_backends` now run their body on a thread of their own (`tests/unwatched`), where a caught C++ exception is ignored and any other exception still fails the test. The `text` package runs on several threads again in `tools/test_windowless.ps1`. Outside the test runner nothing changes: DirectWrite catches these exceptions itself.
- **A test package that does not end names itself** (	ools/test_windowless.ps1): each package is killed after 300 s, with its log (the state changes of its tests) in the CI's, instead of the CI cutting the whole step off after twelve minutes with nothing to read.
- **The CI's cold build of the Rust libraries has room to end** (.github/workflows/ci.yml): with fat LTO it is slower than the step's 12 minutes, so the cache was never saved and every run was cold; the build is a step of its own with a 30 minute limit, and the cache fills at the first success.

## [0.47.1] - 2026-10-27

### Fixed
- **The native text backend and the accessibility adapter are built with fat LTO** (`native/text`, `native/a11y`, `tools/build_text.ps1`, `tools/build_a11y.ps1`): their crate types listed `rlib` next to `staticlib`, and rustc skips LTO whenever an `rlib` is among them: every dependency stayed a separate unoptimized object (`gt_text.lib` 33.2 MB, now 6.4 MB; `gt_a11y.lib` 16.9 MB, now 4.8 MB). The crates are now plain libraries (an application's Rust library still depends on them) and the scripts ask for the static library alone (`cargo rustc --crate-type staticlib`); they fail if an object of another crate is left in the archive.

## [0.47.0] - 2026-10-27

### Fixed
- **A drag inside the window is shown at the top rate of a variable refresh screen** (`platform.frame_decision`, `Cadence.variable`, `platform.cadence_adopt`): on a variable refresh screen (G-Sync, FreeSync, Windows' dynamic refresh rate, which reports 60 Hz at rest), a `Drag` frame (a splitter, a panel's handle, a tab) is presented at once with two frames queued, still one frame per slot of the top rate, instead of waiting for a refresh at the rate the screen rests at: a splitter dragged at 1 kHz went from 62 to 183 frames a second on a 180 Hz screen reported at 60 Hz. Fixed refresh screens and every other state are unchanged. `cadence_adopt(&c, plan)` takes the plan's slots and screen (instead of `c.slots = plan.slots`).

## [0.46.0] - 2026-10-27

### Added
- **`platform.Event.injected`**: an event made by `inject_event` (a test, a remote control, a macro) says so; an application that reads the pointer's position from the system (a window dragged across the screen) uses the event's own position for these, as the real pointer is elsewhere.
- **`Build_Params.inactive`, `ui.inactive`**: a window that is not the one the user is in is built with `inactive = true`: its focused line and text edits keep the focus but draw no caret and ask for no wake to blink it (an application with several windows no longer blinks a caret in each).

## [0.45.1] - 2026-10-27

### Added
- **Text and bounds in the UI Automation test client** (`uia.document_text`, `uia.text_selection`, `uia.select_text`, `uia.bounds`; `uia_probe text`, `uia_probe select-text --start A --end B`, `uia_probe bounds`): what a text pattern holds, its selection or caret, a selection made as a screen reader does, and where an element is, for end-to-end tests.

## [0.45.0] - 2026-10-27

### Added
- **Accessibility, node by node and several windows**: `platform.a11y_diff_patch` sends a tree's changes from only the nodes that changed (a document that knows its mutations no longer makes its whole tree again); the children a node lost are forgotten with their subtrees, so a node put back goes whole. `ui.a11y_cost(s)` gives the nodes and the milliseconds of the last tree. A `ui.State` built for another window than its last one sends that window a whole tree. `tests/a11y` reads two windows apart through UI Automation and checks that a window a reader has read stays quiet at rest (no wake, no update). docs/accessibility.md lists the known limits (Linux and macOS, the toolkit's tree made again in each build, what grafted documents such as Wren's pages lack: iframes, caret and selection, text bounds, a second window).
- **docs/getting-started.md** and **`examples/hello`**: a new project with the toolkit as a submodule (prerequisites with the pinned Odin, MSVC, the optional Rust libraries; a window in a few lines built with `-collection:gt=...`; the render and text backends, accessibility, tests, versions) and the pitfalls met so far (the output folder, `odin test` deleting its exe, a `render.Surface` in a local, nested builds, keys, `expect_assert` on Windows). `hello --frames=N` runs without showing its window. Checked on a clean clone; `tools/window_shot.ps1` accepts an absolute `-Out`.
- **`flate`**: DEFLATE, zlib and gzip as streams (`Inflater` / `Deflater`: input in chunks of any size, each push gives the output it allows; `inflate` / `deflate` for whole buffers), pure Odin for any platform. Checksums and sizes checked, a bound on the output (`limit`, `Too_Large`). The deflater writes each block in the cheapest of stored, fixed and dynamic Huffman codes (about 17 % smaller than fixed codes on text). Ported from Wren's `src/flate` (same API); docs/flate.md, `tests/flate`.
- **Offscreen readback on the WebGPU backend**: `draw.offscreen_end` gives a `render.Readback_Id` and `render.readback_poll` the picture (straight RGBA8, sRGB values, alpha kept) as under Direct3D 11: the frame copies the target into a buffer, the poll maps it without waiting (`Pending` until the GPU is done). `tests/layers` checks the pixels on both backends.
- **`ui.Build_Params.time_ms`**: the build's clock (caret blink, double and triple clicks, hover delays, timers, toasts), `now_ms()` when 0. A test or a replay passes its own to be deterministic; double clicks and the text selection's clicks now read the build's clock instead of the wall clock.

### Fixed
- **CI**: two tests that failed now and then are deterministic. `tests/ui_robust` (`nested_build_is_refused`) checked an assertion through `testing.expect_assert_message`, whose exception handler on Windows races the system's end of the process: the whole test program ended without a message. The assertion is now caught on a thread of the test's own. `tests/keyboard` (`caret_rect_is_where_the_caret_is_drawn`) depended on the caret's blink phase, i.e. on how long the program had run (a slow WebGPU start blinked it off); it and the double-click tests (`selection`, `panes`) now pass `time_ms`. `tools/test_windowless.ps1` and `tools/test_backends.ps1` print the exit code of a failed package (an access violation, a trap nothing caught).

## [0.44.0] - 2026-10-27

### Added
- **`platform.frame_decision`: the cadence model** (`platform/pacing.odin`, [docs/pacing.md](docs/pacing.md)): a plan from the screen and the application's choices (`cadence_plan`: the top useful rate of a variable refresh screen, `Frame_Slots` strict or loose), a state per frame (`Rest`, `Continuous`, `Drag`, `Input_Answer`, `Resize_Step`, `Resize_Burst`) and one pure decision (`Frame_Decision`: the wait for its slot, whether it waits for the swap chain, whether it is presented at once, the swap chain's latency), plus `cadence_inner_frame`, `cadence_echo` and the frame clock (`frame_clock_advance`, `vblank_at_or_before`). Test: `tests/pacing` (states, transitions, and simulated runs on fixed and variable refresh screens, tearing, a 1 kHz mouse, a resize, a panel dragged, AltSnap); `tests/frame_slots` and `tests/pacing` join the windowless tests of the CI.

## [0.43.0] - 2026-10-26

### Added
- **`platform.Frame_Gate`: the frames of a thread as one state machine** (`platform/frame_gate.odin`, [docs/frame_gate.md](docs/frame_gate.md)): `Idle -> Polling -> Work -> Building -> Drawing -> Presenting`, Full and Light frames, `frame_gate_begin` / `frame_gate_stage` / `frame_gate_end`; a frame asked for where none may begin is deferred, never nested, and a move the machine does not have is counted (a panic with `strict`). The window procedure defers a `WM_PAINT` where no frame may begin; `drag_script` pumps the thread's messages between its steps as the system's drag loop does. Test: `tests/frame_gate`.

## [0.42.3] - 2026-10-26

### Fixed
- **CI**: green again and about 6 minutes instead of 30 to 37. The CHANGELOG step failed on every push (`tools/changelog_test.ps1` ended with the exit code of a command it made fail on purpose; it now exits 0); a test package of a single test counted as failed (`text_backends` printed "The test was successful", not "All tests were successful"; both are accepted now). The jobs run in parallel: build (changelog, examples, shaders), the windowless tests (`tools/test_windowless.ps1`, the step's script moved there) and the WebGPU tests in four groups (`tools/test_backends.ps1 -Group ci1`..`ci4`, checked to hold every package once; `-Group sample` on pull requests) with DXC, a third of the time of FXC on WARP (FXC still runs two packages, `-Define TOOLKIT_WGPU_DX12_COMPILER=fxc`); each job and slow step has a timeout; the Rust libraries, naga's translator, the emoji font and DXC are cached; Odin is set up by `.github/actions/setup-odin`, its archive hashed with .NET rather than `Get-FileHash`. Every push to master keeps its own run (only pull requests cancel the previous one).
- **WebGPU: `render.video_convert`** converts pictures in memory (I420, NV12; P010 and 10-bit I420 when the adapter has `TextureFormat16bitNorm`) with `video.wgsl`, crop, rotation, matrix and range included, as on Direct3D 11: it returned `false` for every picture (`render/wgpu_video.odin`). A decoder's Direct3D 11 texture (`gpu_texture`) is still refused on WebGPU (wgpu-native cannot import it); `tests/video` checks that refusal there instead of calling a Direct3D 11 device the backend does not have (it crashed).
- **WebGPU: Slug text when the device refuses its shaders** draws nothing instead of passing a missing shader module to the pipeline: `r.slug.failed` is honoured by both backends (it was Direct3D 11 only), a refused `slug.wgsl` sets it, a recreated device asks again.

## [0.42.2] - 2026-10-26

### Fixed
- **`tools/fetch_emoji.ps1`, `build_naga.ps1` and `fetch_wgpu.ps1` hash their files the .NET way**, not with `Get-FileHash`: the build step of a CI run (cmd, after the MSVC environment was set) failed with "Get-FileHash is not recognized" as soon as the emoji font had to be fetched again.

## [0.42.1] - 2026-10-26

### Added
- **`render.surface_init(r, &s, hwnd, size, ...) -> ok`** makes a `Surface` in the one the program points to. `surface_create` (which returns it by value) is kept and calls it. A `Surface` is several kilobytes (`Present_State`'s ring of 256 frames): held in a local and copied into a record, `-o:speed -debug` split it into 12 612 values with a debug record each, and LLVM spent more than ten minutes on that module (Wren's development build and its CI did, until it called `surface_init`). The doc of `surface_create` says so.

## [0.42.0] - 2026-10-26

### Added
- **Accessibility: screen readers read the toolkit's windows** (`ui/a11y.odin`, `platform/a11y.odin`, `platform/a11y_diff.odin`, `platform/a11y_accesskit.odin` (Windows), `platform/a11y_stub.odin`, `native/a11y`, `docs/accessibility.md`). Each build turns the boxes into an accessibility tree (boxes with a role or text; layout boxes left out; ids are the boxes' keys; bounds, focus, states, values, actions) and [AccessKit](https://github.com/AccessKit/accesskit) 0.25 exposes it through UI Automation (`WM_GETOBJECT`). Built only once an assistive technology asked for the window; only the nodes that changed are sent (`platform.A11y_Diff`). Every widget gives its role, name and states (buttons, check boxes, radios, switches, sliders, steppers, progress, segmented, chips, dropdowns, tabs, fields and text editors with text runs and caret, lists and virtual lists, menus and menu bars, tooltips, toasts as live regions, modals, splitters, accordions, cards, form rows, title bar and caption buttons, status bar, labels, paragraphs, rich paragraphs with their links). The app names its own boxes with `ui.a11y(info)` (next box) or `ui.a11y_set(box, info)`; `ui.a11y_wanted()`, `ui.a11y_active`, `ui.a11y_tree`, `ui.a11y_find`, `ui.a11y_stats`. Requests of assistive technologies (invoke, toggle, select, expand / collapse, focus, set value, increment / decrement, text selection, scrolling, context menu) arrive as the same signals as input; the others in `ui.a11y_requests()`; `ui.a11y_request(key, action)`, `ui.a11y_numeric_request`, `ui.a11y_inject` (tests). Trees of the app's own (documents) are grafted under a node (`A11y_Info.graft`) and sent with `platform.a11y_send`. `ui.set_window_button_names` (translated caption buttons). Platform: `a11y_state`, `a11y_send`, `a11y_take_request`, `a11y_available`, the update writer (`a11y_node`, `a11y_children`, `a11y_str`...); `Event_Kind.Accessibility`. Compiled in with `-define:A11Y_ACCESSKIT=true` (`tools\build_a11y.ps1` builds `build\a11y\gt_a11y.lib`; `A11Y_NATIVE_LINK=false` when the program's own Rust library carries it). Every update is checked against a mirror of the tree before AccessKit sees it (a broken update is refused, not a crash); text runs and text selections are made safe for AccessKit's text code. `ui.a11y_box_text` (the text a box shows to a reader). `ui.a11y_focus_on(key)`: the readers' focus on a graft node while the app's view has the keyboard (a focus on a graft whose tree is not there yet waits for it in the adapter).
- **`tools/uia`**: a small UI Automation client (COM `IUIAutomation`): elements, control types, names, states, values, invoke / toggle / select / expand / set value / focus. **`tools/uia_probe`**: the same as a command, for end-to-end tests of applications (a hidden window works).
- Tests: `tests/a11y` (the tree, incremental updates, requests; with `-define:A11Y_ACCESSKIT=true`, a hidden window read and driven through UI Automation). CI runs both.

## [0.41.1] - 2026-10-26

### Added
- **`platform.Chrome_Regions.overlays`**: what the app shows over everything (the ui fills it with the open menus' panels). `hit_test_chrome` answers `Client` there before anything else, the resize bands included.

### Fixed
- **An open menu that covers the integrated title bar's resize band takes the pointer there** (`ui` `chrome_collect`): a menu taller than the window starts at its top, and over the band the system showed the resize cursor (diagonal at the top right corner) and resized the window on a press.
- **The open menus are above whatever the app builds at the root after them** (`menus_raise`, in `end_build` before layout): a menu is built where its button is, and a notice, panel or dialog built later at the root was drawn over it and took its pointer. Test: `tests/chrome` open_menu_over_resize_bands_and_later_boxes.
- **`font.glyph` gives the ink box where the ink is with the native text backend** (`native/text` `gt_glyph_box`): read-fonts 0.46 counts a glyph's extents height downward and never negative, and the bottom of the box was put a glyph's height above its top, so the box was twice as high and a glyph centred by it (Wren's tab icons, a chip's icon) was drawn a glyph lower than meant. Test: `tests/text_backends` native_glyph_box_matches_dwrite (`-define:FONT_BACKEND=native`).

## [0.41.0] - 2026-10-26

### Added
- **`ui.post`: calls posted from any thread** (`ui/post.odin`, `ui/post_queue.odin`, `docs/post.md`): `post(state or window, fn, data, word)` runs `fn(data, word)` on the interface's thread at the start of the next `begin_build` (or `drain_posts`), and wakes the window once per drain. `ui.Post_Queue` is a bounded lock-free ring (Vyukov's MPMC queue, no allocation per message); a full ring blocks (default, nothing lost), drops the oldest (`on_drop`), grows into a spill list or fails (`Post_Overflow`); each producer's order holds in every mode. `post_configure` (capacity, overflow, calls per build, `on_drop`), `drain_posts` (bounded; `needs_frame` while calls wait), `post_close`, `post_stats`, `set_post_wake`. Example: `examples/stream` (a thread posting simulated server-sent events). Test: `tests/post`.
- **Notification area icon** (`platform/tray.odin`, Windows `tray_win32.odin` on `Shell_NotifyIconW` version 4, stub elsewhere, `docs/tray.md`): `tray_create`, `tray_set_icon` (PNG) / `tray_set_icon_rgba`, `tray_set_tooltip`, `tray_set_menu` (items, separators, check and radio marks, disabled and default items, submenus; opened by a right click or the menu key), `tray_show_menu`, `tray_notify` (title, body, icon, silent, quiet time), `tray_poll` (clicks, double clicks, right and middle clicks, menu items, notification shown / clicked / timed out / hidden, hover, `Recreated` after the shell restarted: the icons are added again on `TaskbarCreated`), `tray_destroy`; `destroy_window` removes the window's icons. `tray_test_hook` and `tray_inject` for tests. Test: `tests/tray`.
- **Rich clipboard** (`platform/clipboard.odin`, Windows `clipboard_win32.odin`, stub elsewhere, `docs/clipboard.md`): `clipboard_set` (text, HTML with its source URL, image, files in one write), `clipboard_get_image` (PNG, CF_DIBV5, CF_DIB, CF_BITMAP), `clipboard_get_html` (fragment and source URL), `clipboard_get_files` (CF_HDROP), `clipboard_formats`, `clipboard_format_names`, `clipboard_sequence`, `clipboard_watch` / `clipboard_changed`; images are written as PNG + CF_DIBV5 (alpha) + CF_DIB (over white). Pure conversions: `dib_to_rgba` (every DIB header and depth), `rgba_to_dib`, `hdrop_encode` / `hdrop_decode`, `html_format_source_url`; `png_encode` / `png_decode`. Test: `tests/clipboard`.
- **`ui.splitter`** (`ui/split.odin`, `docs/panes.md`): a handle that resizes one pane (logical pixels, or any unit through `unit`) within its limits and the room the other pane keeps, the pane before or after the handle, double click / Enter back to the default, arrow keys and Home / End with the keyboard focus (optional), the resize cursor, a rule drawn in the accent colour while hot or held; `finished` says when to persist; nothing drawn or animated at rest.
- **`ui.accordion`**: a header with a turning chevron that folds the content built in its block, with an animated height (no frame at rest), Enter / Space; the content is not built once folded.
- **`ui/reorder.odin`**: a list reordered by dragging along X or Y, from Wren's tab strip: `reorder_item_size`, `reorder_offset`, `reorder_slot`, `list_move`, `reorder_edge_scroll`, `reorder_moved`, and the drag's state `Reorder` (`reorder_frame`, `reorder_begin`, `reorder_dragging`, `reorder_item_pos`: items slide to their slots, the dragged one follows the pointer).
- Example `examples/panes`; tests `tests/panes`.

## [0.40.1] - 2026-10-26

### Added
- **`ui.building()`**: true between `begin_build` and `end_build` (on this thread, whatever the state). An app whose window procedure makes frames (`on_frame`, inside a loop of the system) asks it before building one.

### Fixed
- **A build begun inside another one is refused with a clear assertion** (`ui: begin_build inside another build`) instead of breaking the one in progress: `begin_build` emptied its parent stack, freed its frame arena and selected another state under it, and the outer build failed later at an unrelated place (Wren's crash of 2026-10-26: a bounds check in `ui.spacer`, after a `TrackPopupMenu` opened during the build painted the window from `WM_PAINT`). Test: `tests/ui_robust` nested_build_test.

## [0.40.0] - 2026-10-26

### Added
- **`ui.rich_paragraph`** (`ui/rich_text.odin`): runs with their face, size, bold / italic, inline code, colour, background, underline, strike and links in one paragraph; lines break at the backend's opportunities on the whole text, "\n" breaks, long words are cut between clusters, `max_lines` ends with "…", `text_align` aligns; links answer hover, click and the keyboard (Tab through them, Enter); layouts are cached by content (thousands of runs laid out once). Geometry: `rich_layout`, `rich_text`, `rich_index_at`, `rich_caret`, `rich_range_rects`, `rich_link_at`; `rich_set_faces`. `Box.measure_y` (a .Text height that follows the width). Theme entries `link`, `code_bg`. Tests: `tests/keyboard` rich_text_test. Example: `examples/markdown`.
- **Selecting text outside fields** (`ui/selection.odin`): `.Selectable` labels, paragraphs and rich paragraphs share one selection across boxes (drag, Shift+click, double / triple click, Shift+arrows, Ctrl+C, Ctrl+A); text cursor, the theme's selection colour; `selected_text`, `has_selection`, `selection_serial`, `selection_changed`, `clear_selection`, `select_box`. Test: `tests/keyboard` selection_test.
- **`font.styled_face`**: the family's own bold / italic face of a system font, else simulated.

### Fixed
- Bold runs of a system font were the regular face with simulated bold (0.02 em: hardly bolder at 24 px): they take the family's bold face now.

## [0.39.0] - 2026-10-26

### Added
- **Simulated bold and oblique in the native backend** (`font/simulate.odin`): as DirectWrite draws them (bold: +upem/50 per inked glyph and emboldened outlines; oblique: 0.33985 shear). `Font.sims` on every platform; `with_simulations` off Windows. Test: `tests/text_backends` simulations_test (widths to 0.01 px, Slug outline boxes).
- **System fonts on Linux (fontconfig) and macOS (CoreText)** (`font/font_system_linux.odin`, `font/font_system_darwin.odin`): `load_system`, `has_system_family`, the per-character fallback and `system_families`; collection faces by PostScript name (`gt_face_postscript_name`, `gt_file_face_count`). Checked with `odin check`, not run on those systems yet.
- `FONT_NATIVE_LINK=false`: a program that builds `native/text` into its own Rust library links no `gt_text.lib` (two Rust static libraries collide).
- `native/text/examples/shape_dump`: HarfRust's shaping of a text, like `hb-shape`.
- `tests/keyboard` text_edit_draw_test: `text_edit_caret_rect` against the drawn caret.

### Changed
- The Hebrew difference between the backends is explained (`docs/font-backend.md`): DirectWrite drops the XPlacement of right-to-left kerning pairs; the native backend applies it, as HarfBuzz does.

## [0.38.3] - 2026-10-26

### Added
- **File dialogs** (`platform/dialogs.odin`, Windows `dialogs_win32.odin`, stub elsewhere): `open_file_dialog`, `save_file_dialog` and `pick_folder_dialog` with a title, filters (`File_Filter`), an "All files" line, the starting folder (`start_dir`, or a `Known_Folder` default), a remembered folder per `remember_id`, the suggested name and default extension, several files, the overwrite question; `Dialog_Result` gives the paths and the type line chosen. Pure helpers: `filter_patterns`, `filter_matches`, `filters_from_accept` (a web page's accept list); `dialog_test_hook` stands for the real dialogs in tests. Doc: `docs/dialogs.md`. Test: `tests/dialogs`.
- **Shell actions**: `open_url`, `open_path`, `reveal_in_folder` (`ShellExecuteExW`; the file manager with the file selected), `known_folder_path`.

## [0.38.2] - 2026-10-26

### Added
- **`ui.text_edit` wraps and grows** (`wrap`, `auto_height`, `min_lines`, `max_lines`): long lines break at the box's width at the font backend's line break opportunities (a word wider than the box between grapheme clusters); Up / Down / Home / End, clicks and drags follow the visual lines, the caret at the end of a wrapped line stays there (`Text_Area.upstream`); the box is as tall as its lines within the limits, then scrolls. `ui.text_visual_lines`, `ui.visual_line_of`, `ui.Visual_Line` (`ui/text_lines.odin`). Tests: `tests/keyboard` (text_edit_wrap_test.odin). Example: the composer of `examples/fidget`.
- **Caret rectangle**: `Edit_Result.caret` (box coordinates, this build) and `ui.text_edit_caret_rect(a)` (the caret and the selection's other end, window coordinates, as last drawn) for completion popovers and input method windows.

## [0.38.0] - 2026-10-26

### Added
- **Native text backend** (`-define:FONT_BACKEND=native`, `font/backend_native.odin`, `native/text`, `tools/build_text.ps1`): Fontations (read-fonts' font model), HarfRust and ICU4X (line breaks with dictionaries, bidi through unicode-bidi) in a static Rust library behind a C ABI, built and pinned like Wren's image decoders. Shapes 2.6 times faster than DirectWrite on the corpus (2.0 µs a word against 5.2, without the word cache). Faces are still opened by the platform; `Settings.backend` picks either backend for one State. `font.native_table`, `font.native_coverage`, `font.native_outline_provider`. See `docs/font-backend.md`.
- **`tools/text_bench`** and **`tests/text_backends`**: the two backends compared on the corpus (equivalence report and timings; logic checks in the tests).

### Changed
- **The `font` package compiles on Linux and macOS** (`odin check font -target:linux_amd64` / `darwin_arm64`): DirectWrite and Direct2D are behind `font_windows.odin`, `raster_windows.odin` and the color files; `font_other.odin` loads faces from files and memory through the native backend (no system fonts yet: TODO fontconfig / CoreText). `load_memory` takes `font.Simulations` (`{.Bold, .Oblique}`) instead of DirectWrite's flags.

### Fixed
- **Kerning under letter-spacing and font-feature-settings** (dwrite backend): an explicit feature list replaced DirectWrite's default features (kern, liga, clig, calt, rclt); they are now kept unless the list sets them.
- `tests/retained` passes with `FONT_TEXT_RENDERER=slug` too (its atlas page assertions follow the renderer).

## [0.37.0] - 2026-10-25

### Added
- **Text backends** (`font/backend.odin`, `docs/font-backend.md`): the `font` package shapes, analyses (scripts, bidi, line breaks) and reads faces (coverage, metrics, glyph boxes, Slug outlines) through `Text_Backend`, a table of procedures, and finds the system's fonts (fallback, `font.system_families`) through `System_Fonts`, the platform's. DirectWrite is the `dwrite` backend (`font/backend_dwrite.odin`, the code moved, not changed: the corpus dump of `tools/text_dump` is byte-identical before and after); other platforms get an "unsupported" system stub (`font/system_other.odin`, TODO fontconfig / CoreText). `Settings.backend` (init only), `font.backend`, `font.backend_available`, `font.face_metrics`.
- **`tools/text_corpus`, `tools/text_dump`**: a multilingual corpus (Latin with ligatures and kerning, Cyrillic, Greek, Arabic, Hebrew, Devanagari, Thai, Lao, Khmer, Myanmar, Chinese, Japanese, Korean, emoji sequences, a variable font, fallback) and a dump of everything the package says about it (glyphs, clusters, widths, metrics, bidi levels, line breaks), to diff two builds.

### Changed
- `Font.features` (cascade features) are `[]Feature` instead of DirectWrite's structure; the system fallback and the script analysis of ASCII text go through the backend.

## [0.36.2] - 2026-10-25

### Added
- **`platform.Frame_Slots` / `frame_slot_wait`** (`platform/frame_slots.odin`, pure): the app's own cap on the cadence of its frames, a grid of slots one period apart that no frame starts before. The swap chain's latency object paces an app only where the system holds frames back until a refresh; on a variable or dynamic refresh display (G-Sync, FreeSync, Windows 11's dynamic refresh rate) it is released at once, and an app woken by a mouse at 1 kHz makes and presents a frame per move (270 to 915 a second measured on a 180 Hz G-Sync monitor). `strict` makes the grid the period itself; a loose one (0.9 of it) is a net a screen that paces the app never reaches, and tightens by itself after 8 delayed frames in a row. A frame that starts an answer to input (`immediate`) is not delayed. Test: `tests/frame_slots` (a loop woken every millisecond on a screen that paces nothing: at most one frame per period).
- **`Display_Info.max_hz`**: the highest rate of the monitor's modes at the current size and orientation. With a dynamic refresh rate the mode and the display path say 60 Hz all the time while the screen is at 180 Hz when something moves; `platform.refresh_is_variable(hz, max_hz)` tells when to aim above `hz`.
- **`platform.display_live_hz(w)`**: the refresh rate the compositor says it runs at right now (`DwmGetCompositionTimingInfo`, `rateRefresh`): with a dynamic refresh rate the one reading that moves with the screen. DWM answers for the primary monitor only and only to a NULL window handle (a handle gives `E_INVALIDARG`), so a window on another monitor has no answer (`ok` false). Its refresh count is no use (it counts the calls of the process).

## [0.36.1] - 2026-10-25

### Added
- **`Box_Flag.Scrollbar_Left`** (`ui/scrollbar.odin`, `ui/events.odin`): the overlay scrollbar of a `.View_Scroll_Y` box sits at its left edge instead of its right one (drawn, hit and dragged there; its grab margin widens toward the content). A panel docked on the left whose right edge joins the content (a tab sidebar whose current tab flows into the page) keeps its scrollbar on the outside. Test: `tests/ui_robust` scrollbar_on_the_left.

## [0.36.0] - 2026-10-25

### Added
- **Window placement, for apps with several windows or a saved layout** (`platform/placement.odin`, `placement_win32.odin`): `platform.get_placement(w)` / `set_placement(w, p)` (`Placement{rect, maximized}`: the outer rectangle in screen pixels where the window is restored to, and whether it is maximized; `set_placement` moves and sizes the window without showing it, on the monitor nearest to the rectangle and inside its work area, and `show_window` then shows it maximized if asked), the pure `fit_rect_to_work(rect, work)`, `outer_rect(w)`, `client_origin(w)` (where the client area starts on the screen: turns a pointer position of a window, captured outside it, into a screen position) and `move_window(w, x, y)`. `tests/placement`. A browser that moves tabs between windows used all of them.

### Fixed
- **`set_placement` asks twice when the window changed monitor**: a window that crosses to a monitor of another DPI is resized by the system for it (640 x 480 became 896 x 672); asked again, now that it is on that monitor, the rectangle is the one wanted. Windows now open on the monitor the user is on (0.35.3), so this is the common case.
- **`ui.init` no longer restarts the toolkit's clock** (`ui/state.odin`): the origin of `ui.now_ms()` was reset by every `init`, so opening a second window (one `ui.State` each) made the time of the first one jump back. It is set by the first `init` only.

## [0.35.3] - 2026-10-25

### Fixed
- **A menu row that the pointer left for a disabled row stayed selected** (`ui/popups.odin`): a disabled row gets no signal, so the selection followed the pointer over enabled rows only and kept the last one while the pointer crossed disabled ones (the burger menu, the dropdown lists). A pointer that moves onto a disabled row now leaves nothing selected. Test: `tests/keyboard` menu_pointer_over_a_disabled_row_selects_nothing.
- **A new window opened on the primary monitor** (`platform/platform_win32.odin`): `CW_USEDEFAULT` puts it there whatever program launched it, so a window started from a program on another monitor had that monitor's refresh rate and DPI wrong until it was dragged. It is now made on the monitor of the foreground window, else the one under the pointer.
- `ui.VERSION` said 0.35.1 in the 0.35.2 release; it follows the changelog again.

## [0.35.2] - 2026-10-25

### Added
- **Offscreen drawing and readback** (`draw/offscreen.odin`, `render/readback.odin`, `docs/draw.md`): `draw.offscreen_begin` / `offscreen_end` draw into a transparent target of their own, never shown and not cut by the window; `render.readback_poll` gives its pixels after the frame (straight RGBA8, sRGB, alpha kept; an `Op_Kind.Read` copies the target where it was recorded). `render.straight_srgb`. Test: `tests/layers` offscreen_draw_and_read_back (both blend spaces, WARP).
- `ui.wake_in_ms` (the timed wake the last build asked for, measured from now) and `ui.wake_due`. `wake_ms` counts from the build: a loop that used it as its wait timeout and as "a frame is wanted" made a frame at every early wake of any message. Measured with Wren's `tools\altdrag_sim.ps1` (AltSnap sends `WM_SIZING` before each step): the extra frame of each step was made for a caret blink not yet due (`Ui_Timer` 882 of 1544 frames of the run); with `wake_due` / `wake_in_ms`, 494 presents for 500 steps.

## [0.35.1] - 2026-10-25

### Added
- **Drag images**: `Drag_Image` is now in `platform/dragdrop.odin` (independent of the system), with `drag_image_valid`, `drag_image_fade` (the translucent ghost of a dragged element) and `drag_image_fit` (scaled down to a size, its hot spot following). `drag_image_held` says what the system's drag image helper holds after `drag_start` (Windows: read back from the data object's `DragImageBits`).
- **The app's own drag back over its window** (`drop_sync_set`, `Drop_Sync`): while `drag_start` blocks, the window asks the app at once for each `Drop_*` instead of queueing them, so the app can handle the drop before `drag_start` returns (a browser fires `drop` before `dragend`).
- **Scripted drags** (`drag_script`, `Drag_Step`, `drag_script_calls`): the next `drag_start` follows given points through the window's own drop target, with the same data object and drag image, never the real mouse (tests, remote control).
- `dragdrop_thread_init`: OLE in a single-threaded apartment on the interface thread, before any library puts it in the multithreaded one (which made `drop_target_enable` and `drag_start` fail).
- **Pointing devices** (`platform/input_devices.odin`): `input_devices` (mouse, pen, touch points; Windows: `GetSystemMetrics`), `touch_max_points`, and the rules of the primary pointer / every pointer (`primary_pointer`, `any_pointer`) as the CSS media features `pointer`, `any-pointer`, `hover`, `any-hover` see them.
- **Touch gestures** (`platform/touch_gesture.odin`, pure): `Touch_Gesture` turns the fingers' positions and times into tap, pan, pinch (scale about the fingers' middle), long press and fling (release speed); `touch_fling` gives the glide's distance and time under exponential friction.
- `Event.pointer.kind` of an emulated `Mouse_*` event says which device the system emulates (touch or pen).
- `render.capture_cancel`: forgets a capture asked for and not read.
- `tests/dragdrop`: drag images, the scripted drag back over the window with `drop_sync_set` (enter, over, drop answered at once, the image held by the system), gestures, device rules.

## [0.35.0] - 2026-10-25

### Added
- **Drag and drop between applications** (`platform/dragdrop.odin`, `dragdrop_win32.odin`, `dragdrop_stub.odin`, `docs/dragdrop.md`): the API is independent of the system; Windows implements it with OLE, other systems answer "not supported". A window becomes a drop target with `drop_target_enable`; a drag over it queues `Drop_Enter` / `Drop_Over` / `Drop_Leave` / `Drop` (position, modifiers, `Event.drop_allowed`) with the data in `drop_data` (`Drag_Data`: files, text, HTML fragment, URL and its title, PNG image, the app's own MIME types); the app answers with `drop_set_effect` (the system is given the last answer). `drag_start` runs a drag of the system with a `Drag_Data` and an optional `Drag_Image`, and returns the effect the target chose. `drop_effect_for` (the Ctrl / Shift / Alt convention), `drag_data_types`, `drag_threshold`, `drop_inject` (tests, remote control), `drop_self_test` (the round trip through the window's own drop target, no mouse). Pure helpers: `drag_custom_encode` / `decode`, `uri_list_first`, `html_format_wrap` / `html_format_fragment` (CF_HTML).
- **Fingers and pens** (`platform/pointer.odin`, `pointer_win32.odin`): `Pointer_Down` / `Pointer_Move` / `Pointer_Up` / `Pointer_Cancel` events with `Event.pointer` (`Pointer_Info`: identifier, touch or pen, primary, pressure, tilt, twist, barrel, eraser, contact size) from `WM_POINTER`. The system's mouse emulation still comes, marked `Event.emulated`. `pointer_buttons`, `pointer_pressure`, `Pointer_State`.
- `Mouse_*` events carry `Event.buttons` (`Mouse_Buttons`: the buttons held after the event), so a move during a drag says which button is held.
- `tests/dragdrop`: the pure helpers, the pointer details, the round trip of every format through the system (hidden window), injected drops.

## [0.34.0] - 2026-10-25

### Fixed
- **Raising then lowering `set_max_frame_latency` no longer leaves the swap chain with two frames in flight for good** (`render/present.odin`, `render/render.odin`, D3D11): the swap chain's frame latency object is a semaphore that the system raises when `MaximumFrameLatency` goes up and does not take back when it goes down. After a 1 -> 2 -> 1 (an app that allows a second frame for a resize step or an input frame, as Wren does) the object held one count more than a slot per round trip: every wait on `frame_waitable` returned at once, `Present` blocked for a whole refresh instead, and the frame on screen was one more frame behind the input, until the program restarted. The surplus is now remembered when the latency is lowered (`Present_State.latency_debt`) and consumed, without waiting, by `frame_waitable` / `wait_for_frame` as soon as the object has the counts to give. Measured on a 60 Hz window (a tab dragged at 1 kHz of pointer moves): wait for the slot 0.1 ms and `Present` 16 ms before, 16 ms and 0.6 ms after, and the time from input to the refresh that showed it, as the frame statistics give it, from 118 ms to 56 ms.

### Added
- `render/latency_object_test.odin`: the surplus of the latency object against a semaphore that stands for it (lowering, raising, taking without waiting, counts that come later).

## [0.33.0] - 2026-10-25

### Fixed
- **A window moved by another program's drag tool is no longer taken for a window in the system's move / size loop** (`platform/size_move.odin`, `platform_win32.odin`): AltSnap (Alt + right button drag) and similar tools resize a window with `SetWindowPos` calls from their own process and POST it `WM_ENTERSIZEMOVE` / `WM_EXITSIZEMOVE`. The window took them for a loop of the system: it painted from `WM_PAINT` inside its own `poll_events` (a frame within the app's frame, two presents per turn) every 16 ms, while the tool waited at every step for its thread. Now the two messages open and close the modal mode only when they arrive inside the window procedure's `DefWindowProc` call, where the system's real loop runs (`size_move_step`, pure); from outside they are ignored and the size change arrives as `WM_SIZE`, drawn by the app's own loop like any other. `WM_ENTERMENULOOP` / `WM_EXITMENULOOP` are unchanged. A move that ended with `WM_EXITSIZEMOVE` from outside still refreshes the display information (another monitor's refresh rate).

### Added
- **`platform.pump_stats(window)`** (`Pump_Stats`): how many frames were made from the window procedure (`paint_frames`, a loop of the system), how many loops of the system were entered (`modal_loops`), how many `WM_ENTERSIZEMOVE` / `WM_EXITSIZEMOVE` from outside were ignored (`ignored_size_moves`). For tests and diagnostics of the message loop.
- `tests/size_move`: the decision `size_move_step` (messages inside / outside `DefWindowProc`, nesting, an exit with no loop open); `tests/window` checks that posted and sent `WM_ENTERSIZEMOVE` from outside open no modal mode (the frames-in-a-loop test now uses the menu loop, which a test can enter without the mouse).

## [0.32.1] - 2026-10-25

### Changed
- **The selected row of a menu is a filled, rounded row with no outline** (`ui/theme_default.odin`: `menu_item selected background` accent at 0.30, `menu_item selected border` transparent): it was the generic "selected" look, an opaque accent ring around a row with a 22 % fill, which read as a focus box more than as a highlight (the fill was too faint to see beside the ring). Lists, fields and every other selected item keep their look.

## [0.32.0] - 2026-10-25

### Added
- **Input -> screen latency, stage by stage** (`render/latency.odin`, off by default): `render.set_latency_probe(r, true)` records, for each frame that reached the screen and was built from input, the time waiting for the frame (`wait`: event received -> frame began), building and drawing (`work`), `Present` (`present`) and scan-out (`scan`: Present returned -> the refresh that showed it), then `latency_summary(r)` gives p50 / p95 / max / mean of each, the total in refreshes of the monitor, the share of frames built from input and how many presents the swap chain's statistics count as not yet shown. `latency_reset`, `latency_summarize` (pure), `latency_sample_of`. The application tells when the frame read its input with `render.set_frame_read`. `Displayed_Frame` gained `read`, `drawn` and `call` (when `frame_end` and `Present` were called). Both backends feed it; nothing is recorded or allocated while the probe is off (`render/latency_test.odin`: arithmetic and ring, no clocks).

## [0.31.0] - 2026-10-25

### Fixed
- Menus: the row under the pointer is drawn selected in the frame that sees the pointer on it, and the row it left is released in that same frame. The selection was decided while a row was built, so rows built before the hovered one (and the hovered row itself) showed the previous selection until the next frame: a pointer crossing a menu left two rows lit for a frame, and the new one a frame late (a refresh or two more once the frame had to wait for the screen). `Menu_Item_Info` gained `key` (the row's box): a level reads the hovered row from the previous frame's items when it begins (`tests/states`: `menu_hover_selects_in_the_same_frame`).

## [0.30.1] - 2026-10-25

### Changed
- Timing checks in the tests (durations, CPU and GPU times, frames in a time window) are opt-in: `base.perf_skip` (package `base`, `base/perf.odin`) runs them only with `GUI_PERF=1` or `true`, and never when `CI` is defined. The results are still checked in CI (`tests/colr`, `tests/gpufx`).

## [0.30.0] - 2026-10-25

Fixes from the review of `font`, `ui` and `platform` (0.26.0). 0.29.0 is the version of another branch (render and draw).

### Added
- **Grapheme clusters** (`font/grapheme.odin`): `font.grapheme_next`, `grapheme_prev`, `is_grapheme_boundary`, `grapheme_count` (UAX #29: ZWJ and modifier sequences, flags, tags, keycaps, Hangul, Indic conjuncts, CR LF), a boundary after or before any byte index.
- `font.selection_spans` / `x_spans_of_range`: the stretches of a line that a range of characters occupies on screen (several in bidirectional text).
- `font.raster_size_limit(s)`: the largest size glyphs are rasterized at (half an atlas page).
- `Colr_Params.surface_limit` and `work_limit`, `COLR_MAX_COMPOSITES`, `COLR_SURFACE_LIMIT`, `COLR_WORK_*`: the bounds of the COLR interpreter's memory and work. `gsub_ligate` is bounded by `GSUB_BUDGET`.
- `ui.wake_within(s, ms)`: asks for a wake within `ms`, keeping the soonest of all the requests. `ui.TIMER_KEEP_BUILDS`.
- `tests/window` (windows and messages; needs a desktop, not in CI), `tests/ui_robust` (in CI), `tests/colr/hostile_test.odin` (COLR and GSUB tables built by hand), `tests/text/grapheme_test.odin`.

### Changed
- **`Font_Id` carries a generation** (slot index in the low 20 bits): the slot of an unloaded font is reused by the next one, so loading and unloading no longer runs out of ids at 65 536; the id of an unloaded font reaches nothing, even once its slot is taken. Ids of the first font in a slot are the same numbers as before. Code that stores `Font_Id` as an opaque number is not affected; code that computes with it (index into a table by id) must mask with `1 << 20 - 1`.
- **Caret, arrows, Backspace, Delete, clicks (`hit_index`), the cut of a toast and the line breaks of `wrap_lines` work on grapheme clusters**, not on code points. Word movement keeps its code point steps.
- `platform.poll_events` / `wait_handle` drop only the events they returned before (they used to clear the whole list, losing what a poll of another window had queued for its window).
- `platform`: the mouse stays captured until the last button is up; a lost capture makes the missing `Mouse_Release`. A repaint of a window that is not itself polled, arriving while another window of the thread polls, no longer runs `on_frame` inside that poll: it sets `paint_requested` (`take_paint_request`). A move and a menu now get frames (a 16 ms timer, `WM_ENTERSIZEMOVE` .. `WM_EXITSIZEMOVE`) as the documentation said.
- `platform.open_window` returns nil when the system cannot make the window; `inject_event` of a `Close` sets `is_closed`.
- COLR: a glyph over a bound of memory or work is refused (drawn as its outline); `PaintComposite` nests at most 8 levels; the interpreter draws without the atlas lock. `colr_nests_glyph` answers "nested" for a graph it cannot read to its end (so that it goes to the interpreter, not to Direct2D), `colr_find` keeps a base glyph record whose offset is outside the table as an unreadable graph, `colr_open` accepts any offsets in a v0 header with no records and refuses a table whose base glyph list does not fit; a face with such a table is not drawn in color by Direct2D.
- Atlas: a bitmap bigger than a page makes no page and evicts none; `draw.glyph_run` caps the rasterization size and stretches the bitmap (text over 1024 px per em was invisible). The Direct2D canvas over 1M pixels is given back after use. `Settings.page_size` is documented as read by `init` only.
- `ui.menu_item` closes the menu when its block ends, not in the middle (the items after the chosen one were built as buttons for a frame). `ui.apply_palette` keeps the entries an application added to the theme first (`Theme.palette_at`); `theme_add` copies its tags. `ui.focus_step` keeps to the open modal; `focused_name` is empty for a box not built yet in this build.
- `ui.fuzzy_find` returns positions in the text it was given (a dotted capital I made them one byte off).
- Timers, scrollbar owners and a virtual list's measured heights of rows that are gone no longer grow without end.

### Fixed
- `ui.dropdown` with an empty list or a selection outside it, `ui.tabs` with fewer icons than labels, and `ui.segmented` with no label panicked or drew an infinite rectangle.
- `platform.config_dir` with `%APPDATA%` over 259 characters panicked; the clipboard is read up to the size of its block, freed when it cannot be given to the system, and `GlobalLock` is checked.
- The wake-ups of the caret blink and of a tooltip delay no longer replace each other.

## [0.29.0] - 2026-10-25

Fixes found by the review of `render` and `draw` (branch `fix/render-draw`). 0.30.0 is the font / ui / platform review branch. Each fix has a test that failed before it (`tests/lifecycle` is new).

### Changed

- `docs/webgpu.md` lists the functions the WebGPU backend does not have; `docs/draw.md` no longer says 3D is unsupported (planes are); `docs/shaders.md`: `app_shader` and `app_shader_ready`.
- Not fixed (reported): `bsp` still splits the whole context when one pair crosses, with no limit on the number of pieces, and `Plane_Item.geom` is the texel-aligned rectangle (faces that touch look crossing; Wren works around it); a backdrop of a cut plane is captured once per piece; the hash of an app shader does not cover `APP_BINDINGS` (changing it makes every precompiled blob stale: to be done with the applications' blobs); `Surface` release on a thread, the DirectComposition `Panel` lifetime, canvas source textures never zeroed (to check).

### Fixed

- **Plane pieces with more than 6 cuts** (`draw/bsp.odin`): a piece bounded by more than `MAX_PLANE_CUTS` cuts had the extra ones thrown away, so it was drawn over its siblings' region at its own rank and covered planes that had to be in front. It is now divided by a chord between two of its corners into convex halves (the chord is one more cut for each), as often as needed: no cut is lost, no limit. Hidden (`skip`) items no longer take part in the crossing tests.
- **`draw.app_shader`** keeps `AppIn.pos`, `size` and `px` in local units under a uniform scale plus translation (DPI, zoom) as `docs/shaders.md` says (they were pixels: a scale was baked into the rectangle); any scale now goes through a transform entry. It returns false for a shader that is not `render.app_shader_ready`.
- **Device loss with several windows** (Direct3D 11): a `Surface` set aside by `surface_use` kept its swap chain, views and capture copy from the old device (undefined behaviour, then a loop of recoveries); and `set_blend_space` gave the new view format to the current window only. The window state carries the device generation and the blend space it was made in, and `surface_use` remakes a stale one (`render.Renderer.swap_gen`, `swap_space`, `space_epoch`; `Surface.gen`, `space_epoch`). `d3d_recover` flushes the old context after releasing its objects (the old HWND swap chain used to keep the window, and `CreateSwapChainForHwnd` crashed). An offscreen renderer notices a device loss at `frame_end`.
- **Captures** belong to their window (`Capture_State` is exchanged with the `Surface`: the next `frame_end` of that window takes it, not whichever window ends a frame first); the staging copy of an old device is released at recovery (a pending copy becomes `Failed`) instead of being used on the new device.
- **`wgpu_destroy`** read the texture table after freeing it. **`wgpu_recover`** without a device (adapter gone) returns false at once instead of creating textures on a null device and dropping the textures and shaders for good. A refused app pipeline on wgpu (the module passed, the pipeline did not) gives the shader up instead of invalidating every frame.
- **App shaders that cannot be remade** after a device loss keep their handle (and name) until `destroy_app_shader`; the handle used to be given to the next shader. `render.app_shader_ready(r, s)` says whether one can be drawn.
- **Kept layers and planes** (`cache_id`) follow `set_text_rendering`, `set_corner_smoothing` and the font atlas settings (they are in the key now), and a result drawn while a color glyph was still pending (`Settings.color_async`) is not kept (the glyph never came in). A masked layer that lost a target is not kept as the masked result.
- `push_plane` inside a recorded picture records nothing (it recorded the content flat, unprojected); `current_clip` is not empty while recording.
- Slug text, when the device refuses the Slug shaders, is not drawn (it was one solid rounded rect per glyph); `d3d_update_texture_r8` checks the handle, the block and the pixels like the other uploads.

## [0.28.0] - 2026-10-25

0.27.0 is reserved for the fixes of the review branch.

### Added
- **Boxes with leaning sides** (`ui.Box.slant`, `platform.Slant`): a clickable box can say that its left and right edges lean (how far each is moved inwards at its top and at its bottom). Only that trapezoid is hit (`ui.box_contains`; the topmost box under the pointer still wins), and over an integrated title bar it is a *slanted hole* (`platform.Chrome_Regions.slanted`, `platform.Slanted_Region`, `platform.slanted_contains`; `hit_test_chrome` answers `.Client` inside it), so that the corners a trapezoid tab does not cover keep dragging the window. For tab strips drawn with sloped sides. Tests in `tests/chrome`.

## [0.26.0] - 2026-10-24

Merge of three branches: the GPU 2D canvas engine, faster image uploads, the window border color. 0.20.0 and 0.21.0 (reserved below for the canvas engine and the uploads) were never released: their content is here.

### Added
- **A 2D canvas engine on the GPU** (`render/canvas.odin`, `canvas_types.odin`, `canvas.wgsl`, module `Canvas` of `tools/shaders`, [docs/canvas.md](docs/canvas.md)), Direct3D 11: `render.canvas_texture_create(r, w, h, target, mips)` makes a canvas (a render target of premultiplied sRGB-encoded RGBA8, kept) or a source of pixels (`canvas_upload`); the owner records its drawing in a `render.Canvas_List` (instances with a geometry, a paint and an operator; commands for clip masks, layers, snapshots, `putImageData`) and `canvas_submit(r, target, &list)` replays it in runs of one draw call per operator / source / clip / scissor. Rectangles, rounded rectangles and ellipses have analytic coverage (exact box filter when axis-aligned), polygons 16 N-rook samples on boundary pixels only with the fill rule per sample (the pieces of a stroke never count twice); solid, linear / radial / conic gradients and images (four filters, wrap modes) as paints; the 11 Porter-Duff operators as blend states and the 15 blend modes from a copy of the backdrop; clip masks, layers with color-matrix and gaussian-blur passes (large blurs on reduced images). `canvas_read` (waits), `canvas_read_begin` / `canvas_read_ready` / `canvas_read_finish` / `canvas_read_cancel` (polled), `canvas_read_mask`, `canvas_clear`, `canvas_set_opaque`, `canvas_supported` (false on WebGPU), `canvas_stats`, `canvas_pool_bytes`. `tests/canvas` (12 pixel tests), in `tools\test_backends.ps1`.
- `platform.set_border_color(w, rgb)`: the color of the 1-pixel border Windows 11 draws around the window (`DWMWA_BORDER_COLOR`), or `nil` for the system's. With an integrated title bar the system's border is half transparent along the top edge: a line of whatever lies behind the window showed above the app's tab strip.
- `tests/textures` (both backends): an unwritten texture is transparent, an opaque upload with a wider stride shows exactly, a translucent one is premultiplied in both spaces, a partial update zeroes the rest, mips follow an opaque upload; `render/premultiply_test.odin` checks the word-at-a-time premultiplication against `(c * a + 127) / 255` for every value. Both in `tools\test_backends.ps1`.

### Changed
- **Faster image textures**: `create_texture_rgba` no longer zeroes a new texture with one `UpdateSubresource` per row (551 driver calls, 1 to 4 ms, for a 735 x 551 photo). The texture is marked unfilled; an update that covers it whole clears the mark, and one still unfilled when the frame is submitted (or hit by a partial update first) is zeroed with a few band-sized calls from one zero buffer (`Renderer.zeros`). Observable behavior is the same: a new texture is transparent. Data textures (`create_texture_data`) and video targets keep their own paths.
- **Faster uploads**: `update_texture_rgba` checks whether the block is opaque (a vectorized AND of the words) and uploads opaque pixels, which is every JPEG and most PNG / WebP / AVIF, straight from the caller's buffer with its own pitch: no conversion pass and no scratch copy. Translucent blocks in the sRGB blend space are premultiplied a word at a time without branches or tables; the linear space keeps its table version. Both backends.

### Fixed
- Windows 11, integrated title bar: a line of what lay behind the window showed above the tab strip, because the system's border is half transparent there. An app now paints it opaque with `platform.set_border_color` (nothing changes until it does).

## [0.25.0] - 2026-10-24

### Added
- **Application shaders** (`render/app_shader.odin`, `app.wgsl`, `wgpu_app.odin`, `draw/app_shader.odin`, [docs/shaders.md](docs/shaders.md)): `render.create_app_shader(r, {name, wgsl, dxbc, hash})` registers a fragment function the application wrote in WGSL (`fn app_shade(a: AppIn) -> vec4<f32>`, linear light, straight alpha; it reads `app_param(k)` and `app_tex0..3`), and `draw.app_shader(dc, shader, rect, params, textures, blend, radii, tint)` fills a rounded rectangle with it, in order with everything else, under the transform stack, clips, alpha stack, layers and planes (the vertex stage, corner shape and clip coverage are the renderer's). Up to 64 vec4 parameters and 4 textures per draw; blend modes `Normal`, `Add`, `Screen`, `Multiply`. Refuses (returns false, draws nothing) for shader 0, while a picture is recorded, and over the limits. Both backends: WebGPU compiles the module `rect.wgsl` + `app.wgsl` + the application's WGSL; Direct3D 11 embeds the pixel shader precompiled by `odin run tools/shaders -- app <name> <file.wgsl> <dir>` (naga + D3DCompile, `<name>.dxbc` and `<name>.sha256`; the hash of the module is checked when the shader is created, a stale blob is refused with a message).
- **Data textures**: `render.create_texture_data(r, w, h, format = .RGBA8 | .R8, mips = true)` and `update_texture_data` make textures of raw 8-bit values (a normal map, a height map, a mask): no sRGB decoding, no premultiplication, in either blend space; mip chain by `GenerateMips` / `mip.wgsl`; recreated (empty) after a device loss like images.
- `render.renderer_id(r)`: a number no other renderer of the process has had (a renderer destroyed and made again at the same address is another one), for caches of GPU objects keyed by renderer (with `device_generation`).
- `tests/appshaders` (both backends), added to `tools\test_backends.ps1` and CI.

0.24.0 is reserved for another branch; 0.25.0 follows 0.23.0 on purpose.

## [0.23.0] - 2026-10-24

### Changed
- `render.surface_create(r, hwnd, size, transparent = false, fixed_size = {})`: a second window can have a composition swap chain (`transparent`, with the window opened with `platform.open_window(..., transparent = true)`) and a fixed surface (`fixed_size`, as `set_fixed_surface` does for the renderer's own window): resized, it shows its buffers 1:1 clipped by the client area, never stretched. The default stays an opaque HWND swap chain, which stretches the last frame while the window is resized. `surface_destroy` also releases a translucent surface's DirectComposition objects (and goes through `set_teardown_wait`).

## [0.22.1] - 2026-10-24

### Added
- `render.set_teardown_wait(r, ms)`: `destroy` waits at most that long for the swap chain (and a translucent window's DirectComposition objects) to be released, which happens on a thread of its own; past it the release goes on by itself. Releasing a swap chain waits for the system's compositor to let go of the window's surface, and on a machine whose cores are all busy that took seconds in a program that was closing. 0 (the default): `destroy` waits as long as it takes, as before.

## [0.22.0] - 2026-10-23

### Added
- **Synthetic input**: `platform.inject_event(w, event)` queues an event that the next `poll_events` returns after the system's own, through the same path (hover, focus, shortcuts, text input behave as for a real device). For tests, remote control and macros.
- **Reading a frame back without the screen** (`render/capture.odin`): `render.capture_request(r, rect)` marks the next frame, `frame_end` copies that frame's render target (or a part of it) into a staging texture just before presenting, and `render.capture_poll(r)` returns RGBA8 pixels once the GPU is done (it never waits: `Pending` until then). The picture is what the renderer drew: it works with the window covered, off the screen or hidden, and does not depend on the monitor's scale. Nothing is paid until a capture is asked for. Direct3D 11 (swap chain and offscreen); the wgpu backend answers false.

0.20.0 and 0.21.0 were reserved (feat/canvas-gpu and feat/gpu-accel); they were merged into 0.26.0 instead, and those two numbers stay unused.

## [0.19.0] - 2026-10-23

### Added
- `ui.menu_item(..., keep_open = true)`: choosing the item does not close the menu, for the switches of a settings menu (the check mark changes, the menu stays for the next one).
- `ui.set_menu_item_height(em)`: the height of the items of the menus built from then on, in em (default `MENU_ITEM_EM`, 2.2; 0 puts it back). A dense tool panel sets it while it builds its menus.
- `ui.menu_heading(text)`: a small weak title above a group of items of a menu (not an item: the keyboard skips it).
- Fixed: `platform.open_window` kept the window class name in the caller's allocator, so a window opened later (once that memory was reused) failed with "cannot find window class"; the name is a literal now.
- `ui.use(state)`: selects the state the public procedures operate on, for programs that draw several windows with a state each.
- `render.surface_create / surface_use / surface_destroy`: a second window drawn by the same renderer (same device, textures, fonts), as a surface swapped in for the frames drawn to it (Direct3D 11).
- `ui.tooltip_beside()`: `tooltip` placed beside the pointer (its right, or its left when there is no room), centered on it, for the rows of a list or a table, where a tooltip below the pointer hides the rows under it.

## [0.18.0] - 2026-10-23

### Added
- **Video pictures as textures** (`render/video.odin`, `video.wgsl`, `shaders/video.hlsl`): `render.create_video_target(r, w, h)` makes an RGBA texture for a decoded picture and `render.video_convert(r, target, picture)` fills it. A `Video_Picture` is what a decoder hands over: NV12 and P010 surfaces of the device itself (the hardware decoders of Media Foundation / DXVA write into textures of the renderer's device, shared with no copy when the surface allows it), or I420 and 10-bit I420 planes in memory. It carries the crop rectangle, the rotation (0, 90, 180, 270), the matrix (BT.709, BT.601, BT.2020), the range, and the transfer function (SDR, PQ, HLG, tone-mapped to the display's white with `hdr_peak_nits` and `sdr_white_nits`). The result is an ordinary texture to draw with `draw` as any image.
- D3D11 creates its device with `VIDEO_SUPPORT` (dropped again when the software rasterizer refuses it: there is no hardware decoding there anyway); the wgpu backend has the same entry points (`wgpu_video.odin`, `video.wgsl`).
- `tests/video`: the conversion of each format against reference values (colour matrices, ranges, crops, rotations, 10 bits), on D3D11 and wgpu; `tools\test_backends.ps1` runs it.
- `render.set_max_frame_latency(r, n)`: the most frames the swap chain may queue (`IDXGISwapChain2::SetMaximumFrameLatency`); 1 by default, more while a window is resized so a present does not wait behind the previous frame. The wgpu backend has no equivalent (returns false).
- `render.set_fixed_surface(r, max_size)`: one surface size while the window resizes, shown 1:1 and clipped by the client area (composition swap chains only): a window being resized cuts the last frame instead of stretching it, and the newly shown strip stays the background until the next frame paints it. The blend-space change keeps the whole surface presented (`d3d_resize` skips the source region then).

## [0.17.1] - 2026-10-24

### Fixed
- **Direct2D crash on nested PaintGlyph**: Direct2D of Windows 11 24H2 as first released (`d2d1.dll` 10.0.26100.1, the image of GitHub's `windows-2025` runners; a patched 24H2 such as 10.0.26100.8875 draws them) dies with a null read inside `d2d1.dll`, an access violation nothing can catch, when it draws a COLR v1 glyph whose paint graph has a PaintGlyph inside the paint of another PaintGlyph (a clip inside a clip, directly or through transforms, layers, compositions and PaintColrGlyph). With `Color_Engine.System` such glyphs are now drawn by the COLR interpreter (`font.colr_nests_glyph` finds them in the font's own tables, once per glyph and face); every other glyph still goes to Direct2D. `font.colr_avoids_system(state, face, gid)` tells which. Found by the CI of Wren: `tests/colr` interpreter_agrees_with_direct2d died on U+F1400 .. U+F140F of the test font, 16 glyphs, and the process with it.
- `tests/colr`: the comparison with Direct2D leaves out the glyphs Direct2D is no longer given; `nested_glyphs_stay_off_direct2d` checks, without depending on the machine's `d2d1.dll`, that exactly those 16 glyphs are kept off it and are drawn in color by the interpreter.

## [0.17.0] - 2026-10-22

### Added
- **Planes that cut through each other** (`draw/bsp.odin`): `draw.draw_planes(dc, items)` draws the planes of one 3D rendering context in the order they hide each other, and when planes cut through each other (or hide each other in a cycle) splits them along each other's planes by a BSP (as Chromium's `BspTree` / `DrawPolygon`), the pieces ordered back to front for a viewer in front. A piece is the plane's layer drawn again under `Plane_Draw.cuts` (`Plane_Cut`: half-spaces of the space after the perspective divide, at most `MAX_PLANE_CUTS`, tested per pixel on the interpolated plane position in `rect.wgsl`: no seams between pieces). `Plane_Item.parts`: several layers on one plane (a plane and what rides on it) are cut and ordered together.
- **Effects on the composite of a plane**: `Plane_Draw.blend` (mix-blend-mode of the projected quad), `backdrop` + `shape` (backdrop-filter filtered in screen space, shown through the alpha of a layer projected like the plane).
- **Sharp planes**: `Plane_Fx.mips` gives a plane's layer a mip chain (`render.acquire_target_mips`, `render.target_mips_supported`, `Op_Kind.Mips` on D3D11 and wgpu); the projected quad's filter is anisotropic along the long axis of the footprint at the mip level of the short axis (`proj_texel`). `FLAG_PROJECT` instances take a frame rect (the antialiased edge, for a quad that is one piece of a larger plane) and the valid texel range of the layer (`colors[2]`, `colors[3]`). `draw.open_plane_frame` (map a pointer back through a plane exactly).
- `tests/planes`: planes crossing in an X (both orders of drawing give the same picture, with and without perspective), a star of three, blend on a flat and a turned plane, backdrop-filter through a silhouette, mip levels against aliasing; D3D11 and wgpu.
- **A COLR / CPAL interpreter** (`font/colr.odin`, `colr_raster.odin`, `colr_glyph.odin`): `Settings.color_engine = .Builtin` draws COLR v0 and v1 color glyphs (gradients, transforms, the 28 composite modes, clip boxes, text-color paints) on the CPU from the face's own tables, the same on every platform, into the Color atlas pages (so also async, per text color, in pictures). Default `.System` (Direct2D), unchanged. `colr_samples`, `colr_cache_kb`, `colr_counts`, `colr_of`, `colr_dump`; `Colr` / `colr_open` / `colr_render` for the portable core. A graph it refuses (cycle, bad offset) shows the glyph's outline.
- **Built-in emoji**: `font.set_emoji_source(s, path | data)`: an emoji font loaded on first need, used for emoji characters before the system fallback (`font/emoji.odin`, `emoji_data.odin` generated from Unicode 18 `emoji-data.txt` by `tools\gen_emoji_data.ps1`). Tag sequences are formed from the face's GSUB `ccmp` ligatures (`colr_gsub.odin`).
- `tools\fetch_emoji.ps1` (Noto Color Emoji COLR v1, pinned by commit and SHA-256, OT-SVG table dropped: 4.9 MiB), `font/data/NotoColorEmoji-OFL.txt`, `tools/colrcompare` (interpreter against Direct2D), `tools/colrboard` + `tools\emoji_board.ps1` (against Chrome / Edge), `tools/emojiperf`, `tests/colr` (also `tests/color_glyphs -define:COLR_ENGINE=builtin`).

### Changed
- `rect.wgsl`: two more flat varyings (the cuts of a projected quad); HLSL regenerated. `ui.VERSION` and the version constants agree again (they said 0.16.0 and 0.15.0).

## [0.16.0] - 2026-10-22

### Added
- **Planes**: layers drawn through a projective 4x4 transform (CSS Transforms 2: `perspective()`, `rotateX/Y`, `translateZ`, `preserve-3d`). `draw.push_plane` / `pop_plane` / `draw_plane` (`draw/plane.odin`): the content of a rectangle is drawn offscreen in its own frame at a chosen raster scale, then composited as a quad through a column-major 4x4 matrix (`draw.Mat4`, the order of CSS `matrix3d()`), with perspective-correct interpolation, antialiased edges, anisotropic filtering along the long axis of the pixel's footprint (`Plane_Draw.max_taps`), the clips and alpha stack of the moment, and `backface-visibility` (`Plane_Draw.cull_back`, `plane_faces_away`). `pop_plane` hands the layer back so several planes can be sorted before `draw_plane` (preserve-3d). A plane whose content did not change is kept between frames (`Plane_Fx.cache_id` / `cache_key`, the layer cache of `layer_cache.odin`): `push_plane` returns false and only the matrix changes.
- Shader: `FLAG_PROJECT` in `rect.wgsl` (a `KIND_IMAGE` instance whose homography is in two entries of the transform table): the vertex shader writes homogeneous clip positions, so the rasterizer clips against w > 0 and interpolates with perspective. No new pipeline: D3D11 (naga's HLSL, regenerated) and wgpu share it. `tests/planes` (flat plane equals the plain rect, perspective correctness, backface, a plane crossing the eye, kept planes, nested planes), on both backends.

## [0.15.0] - 2026-10-22

### Added
- A WebGPU render backend (experimental), behind the same interface as the Direct3D 11 one: `-define:TOOLKIT_RENDER=wgpu` (default `d3d11`). wgpu-native over Direct3D 12 (or Vulkan with `-define:TOOLKIT_WGPU_BACKEND=vulkan`); the shaders ported to WGSL; translucent windows through a DirectComposition visual; GPU time per step. The pixel tests pass on both backends (`tools\test_backends.ps1`). See `docs/webgpu.md`.
- `tools\fetch_wgpu.ps1` (wgpu-native and DXC pinned by SHA-256), `tools\render_probe`, `tools\ppm_diff.ps1`, `tools\window_shot.ps1`.
- **Shaders written once, in WGSL**: `render/rect.wgsl`, `filter.wgsl`, `slug.wgsl` (the Slug text shaders, ported), `mip.wgsl`. The HLSL of the Direct3D 11 backend is generated from them by naga (`tools/wgsl2hlsl`, naga pinned exactly, Cargo.lock pinned by SHA-256 in `tools\build_naga.ps1`), compiled to DXBC and embedded as before; `odin run tools/shaders` writes both; `tests/shaders` checks the SHA-256 of the sources in the header of each HLSL and the blobs; CI runs `tools/shaders -- -check`. `render/rect.hlsl`, `filter.hlsl`, `slug.hlsl` are gone (generated copies live in `render/shaders/`). D3D11 pixel tests unchanged, GPU time at a held clock and CPU per frame unchanged, first present +0 to +10 ms.`n- `render.backend_name()`, `render.adapter_description()`; `TOOLKIT_RENDER_TRACE=1` prints the time of the first present.

## [0.14.0] - 2026-10-22

### Added
- Slug text: `font.Settings.text_renderer = .Slug` (default `.Atlas`, unchanged) draws glyphs on the GPU from their quadratic Bézier outlines (Eric Lengyel's Slug algorithm, MIT, patent in the public domain; shaders pinned in `font/slug_ref`, credit in NOTICE.md): sharp at any scale, rotation, skew or page zoom, exact subpixel positions, no bitmaps, nothing to re-rasterize when the scale changes (a picture of Slug text is never stale for its scale). Color glyphs (emoji) stay on the atlas path.
  - `font`: outlines come from a provider (`font.Outline_Provider`, `slug_set_provider`; DirectWrite's `GetGlyphRunOutline` on Windows, cubics turned into quadratics within `Settings.slug_tolerance`), `slug_build` makes the curve texels (RGBA16F) and band texels (RG16UI), `slug_glyph` caches them per (face, glyph) in pages of the two textures (`Settings.slug_pages`, least recently used page reused, pictures that drew from it go stale), `slug_sync_page` / `slug_stats`.
  - `render`: `slug.hlsl` (compiled after `rect.hlsl`, which it reuses for transforms, clips and the text correction), `KIND_SLUG` instances in the ordinary instance list drawn by their own pipeline (`Frame_Data.slug_runs`, `Replay.slug_runs`: a batch is drawn in pieces, in order), `create_slug_textures`, `update_slug_page`.
  - `draw`: `glyph_run` uses it when the setting says so; pictures remember their Slug pages.
  - `tools/textcompare`: atlas | Slug | difference images and measurements; `tests/slug`.

## [0.13.1] - 2026-10-21

### Added
- GPU profile steps `Upload`, `Acquire`, `Present` and `Idle` (only while `set_gpu_profile` is on): where a frame's GPU time goes, the swap chain's wait and the present included.

## [0.13.0] - 2026-10-21

### Changed
- Interaction states show at once: hover, press, focus, selection and disabled no longer fade in or out (`hot_t`, `active_t`, `focus_t`, `disabled_t` go from 0 to 1 in the frame that sees the change), and box colours jump to their targets (a selected row, the hovered menu item). A hover change asks for no further frame. A change of palette still cross-fades every colour for `ui.PALETTE_FADE_MS` (160 ms).
- Hover and press fills are visible: the theme's new state entries `hover_fill` / `press_fill` are fractions of the way to the palette's tint (white on dark palettes, black on light ones) in sRGB values, drawn over the surface actually under the box (`ui.box_under`) with the alpha that gives that step in either blend space (`draw.alpha_like_srgb`). Per role: buttons 7 % / 13 %, ghost and icon buttons 8 % / 14 %, accent and danger buttons 10 % / 18 %, list rows 5 % / 9 %, tabs 6 % / 10 %, segments 7 % / 12 %, anything else with `.Draw_Hot_Effects` 7 % / 12 %; menu items show their selection under the pointer (8 % more while pressed). The old tiny overlay (1.4 % / 2 % in linear light) is gone. The tint entry `hover` itself is unchanged.
- Fields: the border of a `line_edit` under the pointer moves 22 % toward the tint (`input hover_border`).
- No press "squish" by default; `Theme.press_squish` (e.g. 0.04) brings it back, at once and without animation.

### Added
- `Theme.transition_ms`: > 0 brings back short cross-fades of the interaction states (default 0); `Theme.serial`, bumped by `theme_add`, `theme_set` and `apply_palette` when a colour changes.
- Selectable `list_row`s have `.Draw_Hot_Effects` (tag `list_row`, built under it only); `segmented` items light up under the pointer (tag `segment`); `tabs` items have the tag `tab`.
- `"<tags> hot text"`: the text colour of a clickable box under the pointer (falls back to the normal one). `remove_button hot text` is the palette's red, `remove_button hover_fill` / `press_fill` a light red step: push the tag `remove_button` around an `icon_button` for a delete cross.
- `Box_Flag.Hot_Within`: a box stays hot (and lit) while the pointer is on a clickable box inside it; selectable `list_row`s have it (a row and its delete button). `ui.hot_within(key)`: the same question while building (last frame's tree), e.g. to show a row's buttons only while the pointer is on it.
- `list_row` keeps a cursor given with `next({cursor = .Hand})` (rows that open something).
- `ui.state_fill(box, name, under)`, `ui.box_under(box)`, `ui.srgb_step(a, b, t)`: the theme's state steps for custom draw procs.
- `draw.alpha_like_srgb`: the inverse of `alpha_like_linear` (the alpha that looks in a blend space as a given alpha blended in sRGB values).
- `tests/states`: instant states, transitions on demand, palette cross-fade, the size of the steps in both blend spaces.

## [0.12.0] - 2026-10-21

### Added
- **Every CSS cursor**: `platform.Cursor` has all the values of CSS Basic User Interface 4 (`none`, `context-menu`, `help`,
  `progress`, `wait`, `cell`, `crosshair`, `vertical-text`, `alias`, `copy`, `no-drop`, `grab`, `grabbing`,
  `all-scroll`, `col-resize`, `row-resize`, the eight one-way resizes, `nesw-resize`, `nwse-resize`, `zoom-in`,
  `zoom-out`) next to the seven it had, which keep their names (`Arrow` = default, `Hand` = pointer, `Resize_H` =
  ew-resize, `Resize_V` = ns-resize). `cursor_from_css` / `cursor_css_name` (`CURSOR_CSS_NAMES`) convert from / to the
  keyword (`-webkit-grab` and the other legacy names too).
- On Windows a cursor is the system's (`IDC_*`: the user's scheme and size) when Windows has it (`cursor_system_id`,
  `cursor_source`); the twelve it lacks (`grab`, `grabbing`, `zoom-in`, `zoom-out`, `cell`, `copy`, `alias`,
  `context-menu`, `no-drop`, `vertical-text`, `col-resize`, `row-resize`) are **drawn by the toolkit**
  (`platform/cursor_shapes.odin`: shapes on a 32-unit grid, signed distances sampled 4 x 4 per pixel, `cursor_draw`) at
  the size of the system's cursors on the window's monitor (`SM_CXCURSOR` at its dpi, `cursor_size_px`), in the colours
  of the user's scheme (white or black pointer, read from the system's arrow: `cursor_scheme`), with the hotspot where
  Windows puts it (an arrow's tip, a hand's palm, a magnifier's lens); made once per size and scheme, again when the
  dpi or the cursor settings change (`WM_SETTINGCHANGE` `SPI_SETCURSORS`), destroyed with the window. `None` hides the
  pointer over the client area.
- **Custom cursors** from an image: `custom_cursor_create(w, rgba, size, hotspot, density, key, max_css)` (hotspot
  clamped into the image; larger than `CUSTOM_CURSOR_MAX_CSS` = 128 CSS pixels, Chromium's limit: `.Too_Large`, the
  caller shows its fallback), shared by `key` with counted references, `custom_cursor_release`,
  `set_cursor_custom(w, cc, fallback, scale)` (the image resized to its CSS size times the scale, `cursor_resample`:
  premultiplied, a tent filter as wide as the reduction; at most four sizes kept per image), `custom_cursor_valid`,
  `custom_cursor_stats`, `custom_cursor_info`.
- `destroy_window`: destroys the window and what it holds (its cursors, events, title bar regions).
- `cursor_info`, `cursor_handle_of`, `shown_cursor`, `cursor_render` (a cursor as the system draws it, for previews and
  tests).
- `examples/cursors`: every cursor in a grid (light and dark tiles, its CSS name, system or drawn), hover a cell to get
  it; the last cell has a custom cursor. `--preview N` draws the previews at N pixels.
- `tests/cursors`: CSS names, system or drawn for each value, the drawn shapes at several sizes and both schemes
  (colours, bounds, hotspots), resampling, and on a hidden window every cursor made at the system's size, custom
  cursors' references, sizes, hotspots, limits and release.

### Changed
- The cursor is shown **at once** when `set_cursor` / `set_cursor_custom` changes it while the pointer is over the
  client area or captured by the window (a drag: no `WM_SETCURSOR` comes during a capture; a page scrolled or changed
  under a pointer that does not move), and `WM_SETCURSOR` over the client area sets the one resolved last (no frame
  needed while the pointer moves over the same thing). The system keeps its own over the frame, the resize bands and
  the caption of an integrated title bar.
- `Native_Window.cursors` is no longer an array of handles (the cursor state of cursors_win32.odin).

## [0.11.1] - 2026-10-20

### Fixed
- `ui.init` makes the state current: getters (`scale`, `font_size`, `focus_key`...) called before the first `begin_build` read a nil state and crashed (Wren crashed at start-up when the pointer was over its window).

## [0.11.0] - 2026-10-20

### Changed
- **Shaders compiled ahead of time**: `render/rect.hlsl` and `render/filter.hlsl` are embedded as DXBC
  (`render/shaders/*.dxbc`, `render.SHADERS`) instead of being compiled by `D3DCompile` when the renderer starts
  (280 ms to 1.5 s of every launch, `rect.hlsl`'s pixel shader dominating). `odin run tools/shaders` writes the blobs
  after an edit of the HLSL; `tests/shaders` fails while one is stale. `-define:RENDER_COMPILE_SHADERS=true` compiles
  at start-up as before. `render.shader_compile(id)`.
- **Resizing without `ResizeBuffers` at every step**: `render.resize` keeps the swap chain's buffers larger than the
  window (rounded up to `set_resize_slack` pixels, default `DEFAULT_RESIZE_SLACK` = 256) and only changes the presented
  region (`IDXGISwapChain2::SetSourceSize`, microseconds) while the window fits in them; they are reallocated once per
  slack crossed, and made smaller when they hold more than twice the pixels shown. `ResizeBuffers` cost 1.6 to 3.5 ms
  a step. `render.buffer_size`. The window's swap chain is created with `DXGI_SCALING_STRETCH` (with `NONE`, DWM showed
  a smaller source region magnified).

## [0.10.1] - 2026-10-20

### Added
- `font.Metrics.line_gap`: the face's line gap, unrounded (a layout rounds ascent, descent and gap one by one, as Blink does).

## [0.10.0] - 2026-10-19

### Added

- **Kept filter results** (`draw/layer_cache.odin`): `Layer_Effects.cache_id`, `cache_key`, `cache_anchor` keep a
  layer's filtered texture from frame to frame (stored once the same key came two frames in a row); while the caller's
  key, the filters run by passes, the transform's linear part, the anchor's fraction and the bounds relative to the
  anchor hold, `push_effects` returns **false** (the content need not be drawn; what is drawn is discarded) and
  `pop_layer` composites the kept result, moved by whole-pixel moves of the anchor. Opacity, blend mode and trailing
  color matrices stay live. A layer up to `max_layer_px` is drawn whole when it is to be kept (scrolling it into view
  keeps it good). `Layer_Effects.cache_under` (blend modes into the opaque frame) keeps the blended pixels: no layer,
  copy or blend while what lies under is the same. `backdrop_capture` / `backdrop` take `cache_id`, `cache_key`
  (what lies under), `cache_anchor`. `set_layer_cache(dc, budget, max_layer_px, idle_frames)`, `layer_cache_stats`,
  `layer_cache_forget`, `layer_cache_clear`.
- **Masked layers are kept too**: `push_mask` takes the same `cache_*` fields and returns false like `push_effects`
  when the kept result stands (the mask is in the kept result: neither the content nor the mask layers are drawn, and
  `mask_layer` does nothing). The caller's `cache_key` must cover the mask layers; the toolkit salts it so that a masked
  and an unmasked layer never share a result. Trailing color matrices stay live only when they commute with the mask
  (no alpha column in the color rows, an alpha row that only scales alpha by [0, 1], as every CSS filter function);
  others run as passes before the mask, as CSS orders them.
- `render.keep_target` / `unkeep_target` (a pooled texture held across frames), `targets_generation`,
  `kept_targets_bytes`, `texture_bpp`, `acquire_target_format`, `Target_Format`.
- **Per-step GPU profile** (`render/gpu_profile.odin`): `set_gpu_profile(r, on, detail)`, `gpu_profile(r)`:
  time, count, pixels and estimated traffic of each kind of step (`Gpu_Step`: draw runs into the frame or a layer,
  clears, copies, color / blur / reduction / shadow / mask passes), render targets bound, the slowest steps; `detail`
  times every draw call (batch, instances, kinds, flags, scissor).
- `render.set_filter_precision(r, .Unorm8 | .Half)`: filter results in sRGB-encoded 8 bits or fp16.
- `render.FLAG_SCALED`, `render.FLAG_MATRIX` for layer composites and backdrops; `Pass.factor`.
- `examples/effects`: `--nocache`, `--half`; `--bench` prints the GPU time by kind of step; the thumbnails and the
  stress cards keep their results. `tests/gpufx`: reduced blurs against the exact gaussian, kept layers / blended
  pixels / backdrops against drawn ones (hits, whole-pixel moves, invalidation), stale texels never read, the profile,
  masked layers kept (against drawn ones, a new mask key redraws, a blur under a mask).
- **Integrated title bar** (`platform`, `ui/window_chrome.odin`): the app's own boxes are the window's title bar, as in
  Edge and Chrome (tabs in the title bar).
  - `platform.open_window(..., integrated_title = true)` or `platform.set_integrated_title(w, on)` at any time: the client
    area covers the title bar (`WM_NCCALCSIZE`); the system's frame stays on the left, right and bottom (invisible resize
    borders, the shadow, Windows 11's rounded corners and border). Maximized, the client area stops at the monitor's
    edge and leaves 2 px along an auto-hidden taskbar so that it still comes up.
  - The app reports its title bar every frame (`platform.set_chrome_regions(w, &Chrome_Regions)`: caption areas, the
    interactive holes in them, the caption buttons); `WM_NCHITTEST` answers from it (`platform.hit_test_chrome`, pure and
    unit-tested): `HTCAPTION` where nothing is interactive (drag, Aero Snap, double-click to maximize, right click for the
    system menu), `HTMINBUTTON` / `HTMAXBUTTON` (Snap Layouts on Windows 11) / `HTCLOSE`, `HTTOP*` along the top edge
    (a band of the frame's thickness, corners at both ends), the system's own answer on the other borders.
  - Over the caption and its buttons, mouse moves come as `Mouse_Move` events (hover follows); a press on a caption button
    is captured and comes as `Mouse_Press` / `Mouse_Release` (the system never draws its own buttons over the app's).
    `Mouse_Leave` only when the pointer leaves the window, not when it goes from the client area to the title bar.
  - `Event_Kind.Activate` and `Window.active`: the window became active or inactive (dimmed caption glyphs).
  - `platform.minimize`, `toggle_maximize`, `request_close`, `is_maximized`, `is_minimized`, `show_system_menu(w, pos)`,
    `set_fullscreen(w, on)` / `is_fullscreen` (the window covers its monitor without frame; back to its placement),
    `needs_top_border` (Windows 10 draws no top edge: the toolkit draws it), `resize_border`, `is_windows_11`,
    `app_icon_rgba(size)` (the exe's icon as RGBA, to draw it in the title bar). Alt+Space opens the system menu.
  - `ui.Build_Params.window`: after each build the toolkit sends the window its title bar: every box with the new
    `.Window_Caption` flag is a caption, every clickable box over it a hole (popups included), `window_buttons` are the
    caption buttons. `ui.title_bar(id)` (a row with `.Window_Caption`), `ui.window_buttons()` (minimize, maximize /
    restore, close: 46 px wide, as tall as the row, glyphs from Segoe Fluent Icons or Segoe MDL2 Assets, else drawn;
    the system's fills: hover / pressed tints, close in red `#c42b1c`, dimmed glyphs while the window is inactive; clicks
    act on the window), `ui.chrome_regions(s)`.
  - fidget: `--integrated` makes its menu bar the title bar.
- **Virtualized list** `ui.vlist(id, &Virtual_List, ids, labels, selectable)` (`ui/vlist.odin`): only the rows in view
  (and a margin) are built, whatever their number. Rows of any height: measured when laid out, kept per row identity and
  per width / scale / font size, the average for rows never seen; the view stays on the row it shows when heights above
  it change. The keyboard of `list` over every row (Up / Down, Page Up / Down, Home / End, type-ahead on `labels`,
  Enter, Escape), the active row scrolled into view at once. `vlist_destroy`, `vlist_invalidate`, `vlist_scroll_to`,
  `vlist_row_extent`.
- **Wrapped text cache**: a paragraph's lines are kept per (text, font, size, width) between builds
  (`wrap_lines_cached`, `wrap_cache_len`); layout and drawing no longer wrap every paragraph twice per frame.
- **Smooth scrolling along a curve** for the toolkit's scroll regions (`ui/scroll_anim.odin`): impulse (default, as
  Edge) or ease-out, a duration per move, sampled at the frame's time (`Build_Params.frame_ms`: a display clock, e.g. the
  vblank the frame is shown at); a new target while moving keeps the speed. `ui.set_scroll_settings(s, {curve, impulse,
  duration_ms})`; `.Exponential` is the former easing. Apps that scroll their own document the same way feel alike.
- `tests/chrome`: hit test (zones, edges, maximized), title bar regions and caption button clicks from a ui tree,
  virtualized list (rows built, measured heights, keyboard over unbuilt rows, view anchoring), wrap cache, scroll curve.

### Changed

- `list`: the keyboard handling and type-ahead are shared with `vlist` (`List_State.virtual`); no change for `list`.
- Wrapped text is drawn at the width layout wrapped it at (`Box.size`), not the rounded rect's.
- Color matrices ending a filter chain are applied by the composite (one pass and one target fewer; a layer with only
  color filters runs no pass).
- Large blurs: the reduction by 2, 4 or 8 is one pass; the result stays reduced and is sampled back by the next pass or
  the composite (no upsampling pass); the variance of the bilinear resampling is taken off the gaussian's.
- Filter passes no longer clear their target: they write a transparent ring of one texel past their region and read no
  further (the mask pass included). Filter chains end in sRGB-encoded values (no conversion pass back to linear).
- `push_effects` and `push_mask` return a bool (see above); existing calls that ignore it are unchanged.
- `Backdrop` holds the chain's trailing matrices and whether its texture is kept.
- A masked layer whose filters end with a large blur applies its mask at scale 1 over the reduced result (sampled back
  bilinearly, as the composite would).
- `tests/chrome` and `tests/keyboard` take a lock around each test (they drive the global UI state): they no longer need `-define:ODIN_TEST_THREADS=1`, without which `tests/chrome` used to hang the test runner.

## [0.9.3] - 2026-10-19

### Added

- **Direct2D draws color glyphs** (`font/color.odin`, bindings in `font/d2d.odin`): COLR v1 paint trees (linear,
  radial and sweep gradients with their extend modes, transforms, PaintComposite modes, clip boxes, PaintColrGlyph),
  COLR v0 layers, sbix / CBDT / PNG bitmaps and OT-SVG (plain or gzip) are drawn on a private WARP device into a
  bitmap read back into the atlas' Color pages. Windows 11 22H2 and later: `ID2D1DeviceContext7::DrawGlyphRunWithColorSupport`;
  Windows 10 1607 and later: the runs of `TranslateColorGlyphRun` drawn by the call of their format (no paint trees:
  v0 layers or the outline); without Direct2D: COLR v0 layers composited on the CPU as before. Whether a glyph is a
  color glyph comes from `IDWriteFactory8::TranslateColorGlyphRun` (paint trees) or `IDWriteFactory4`'s.
- **Text-color layers** (palette entry 0xFFFF, COLR v1 foreground paints, SVG `currentColor`) take the text color: a
  color glyph is drawn in two colors once to find whether it depends on it; such glyphs are kept once per text color.
  `font.glyph_image` gains an `fg` parameter (sRGB, default black); `draw.glyph_run` passes the run's color.
  `Glyph_Image.uses_fg`.
- `font.color_renderable(s, id)`: false for a face whose only color format the system cannot draw (COLR v1 before
  Windows 11 22H2): a cascade should take those characters elsewhere rather than show outlines.
- Faces with only COLR v1 (`DWRITE_GLYPH_IMAGE_FORMATS_COLR_PAINT_TREE`) count as color faces. Whether a COLR v1 glyph
  uses the text color comes from its paint attributes (`IDWriteFontFace7::CreatePaintReader`), of a COLR v0 glyph from
  its layers; only SVG glyphs are drawn twice to find out.
- **Off the drawing thread** (`Settings.color_async`, off by default): a complex color glyph costs milliseconds (a
  Segoe UI Emoji COLR v1 emoji: about 4 ms on WARP). The first lookup queues it and returns a pending image
  (`Glyph_Image.pending`); one thread draws the queue, puts the bitmaps in the atlas and calls
  `font.set_color_ready_callback`'s callback (ask for a frame there). `font.color_ready_generation`,
  `font.color_pending`, `font.color_wait`. A picture recorded while one of its glyphs was pending is stale once the
  ready generation moves (`Picture.glyphs_pending`, `pending_ready`; checked before the empty-picture cull).
  `unload` drops a face's queued requests and waits for the one in flight; `destroy` stops the thread.
- `tests/color_glyphs`: Google's COLR v1 test glyphs (gradient ends and middle, sweep quadrants, radial, composite,
  rotate / skew / transform, foreground paints in two text colors), Twemoji sbix / OT-SVG / OT-SVGZ smileys, the
  ChromaCheck CBDT glyph, color glyphs off, and the same glyphs drawn through the draw layer (WARP).
- `draw.push_mask(dc, bounds, fx)`, `draw.mask_layer(dc, mode, op)`, `draw.pop_mask(dc)` (`draw/mask.odin`): content
  drawn into a layer, multiplied by the coverage of mask layers drawn after it, each by its alpha or its luminance
  (`Mask_Mode`), composited with the layers below it by `Mask_Op` (add, subtract, intersect, exclude: CSS
  mask-composite); then filters, opacity and blend mode as `push_effects`. Mask layers draw in sRGB. Without a render
  target (or in a picture) the content is drawn unmasked and the mask layers are cut away. CSS mask-image and
  background-clip: text are drawn with it.
- `render.Pass_Mode.Mask` (`render/filter.hlsl`), `PASS_MASK_LUMINANCE`, `PASS_MASK_DEST`, `PASS_MASK_APPLY`,
  `MASK_OP_SHIFT`, `render.Mask_Op`. `pop_layer` closes a mask too.
- `tests/masks` (both blend spaces): alpha and luminance coverage, the four operators, a gradient mask under opacity
  and a clip, no mask layer, text as a mask (background-clip: text), the fallback inside a picture.

## [0.9.2] - 2026-10-19

### Added
- **Frame pacing at the monitor's rate** (`platform/display_win32.odin`, `render/present.odin`):
  - `platform.display_info(w)`: the refresh rate of the monitor the window is on, exact (`Display_Info.hz` 59.94,
    143.998, 180: the rational rate of the display path from `QueryDisplayConfig`, else the current mode, else DWM's
    composition rate, else 60), its `source`, the monitor and a `serial` that changes with any of them. Cached; read again
    after `WM_DISPLAYCHANGE`, `WM_DPICHANGED`, a move or size loop, or when the window is on another monitor.
    `display_invalidate(w)`.
  - `platform.wait_handle(w, handle, timeout_ms)`: waits for a handle (the swap chain's latency object, a timer) while
    taking the window's keyboard and mouse messages as they arrive; they are kept for the next `poll_events`.
  - `Event.stamp`: when the window procedure received the event (input latency).
  - `platform.take_paint_request(w)`: a `WM_PAINT` that came during the app's own `poll_events` (see Changed).
  - `render.set_present_mode(r, .Vsync | .Tearing)` (tearing: for variable refresh displays, the app paces its frames;
    the swap chain is created with `ALLOW_TEARING` when `tearing_supported(r)`), `present_mode`, `set_sync_interval(r, n)`
    (every n-th refresh), `set_expected_refreshes(r, x)` (app-timed frames), `frame_waitable(r)`.
  - Frame statistics after every present: `take_displayed(r)` returns each frame once it reached the screen
    (`Displayed_Frame`: present number, the input it was built from (`set_frame_input`, or `mark_input`), when Present
    returned, the vblank it was shown at, refreshes since the previous one and refreshes it came late for in a run of
    continuous frames (`set_frame_continuous`)). `present_totals`, `measured_refresh_hz` (vblank interval measured from
    the statistics), `vblank_grid` (the last vblank and the period: the grid frames land on), `qpc_to_tick`.
  - `Renderer.swap_buffers` (set before `init`): back buffers of the swap chain (default 2).
  - `-define:D3D_DEBUG=false` turns the Direct3D debug layer off in a `-debug` build (profiling with true GPU times).
- `render.wait_for_frame(r, timeout_ms)` takes a timeout and says whether the swap chain was ready.

### Changed
- `WM_PAINT` during the app's own `poll_events` no longer runs a nested frame (it presented twice in one turn of the
  loop and waited twice for the swap chain, breaking the cadence): the frame being built repaints, and
  `take_paint_request` says one was asked for. Inside a loop of the system (live resize, move, menus:
  `WM_ENTERSIZEMOVE` / `WM_ENTERMENULOOP`) `on_frame` is still called from `WM_PAINT`.
- `RENDER_PROBE` prints frames presented / shown / missed, input-to-screen latency and the measured rate from the new
  statistics.
- `stepper`: holding a button wakes the loop at the next repeat instead of drawing a frame at every refresh.

## [0.9.1] - 2026-10-19

### Changed

- Merge of 0.9.0 (DirectWrite text, retained glyph runs) with 0.8.1 (status bar, frame graph) and 0.8.2 (named palettes).

## [0.9.0] - 2026-10-19

Text on DirectWrite (shaping, fallback, bidi, color glyphs, atlas pages) merged with retained drawing (0.7.0).

### Added

- **Glyph runs record into pictures**: `draw.glyph_run` (and `text` / `text_ex` on top of it) records shaped glyphs
  (positions from the shaper, subpixel positions, color glyphs) like direct drawing; text is rasterized for the
  picture's `raster_scale` times the slot's scale (within `TEXT_RASTER_TOLERANCE` the bitmap is stretched), baked only
  at the picture's own scale. Batches switch between gray and color pages inside a picture as in a frame.
- **Staleness per atlas page**: a picture remembers the pages its glyphs are on and their epoch (`font.Page_Ref`,
  `Picture.pages`); it is `.Stale` when one of them was reused for other glyphs, or when the rendering settings changed
  (`font.atlas_settings_generation`), not on every eviction. A replayed picture marks its pages as used by the current
  frame (`font.atlas_pages_hold`): they are not reused under it. `Batch_Bounds.gray` / `.color`: the pages a picture
  batch samples, bound to the replaying context's textures (a picture can be replayed by another context).
- **Device loss**: the atlas pages upload again whole from their CPU copy (same texture handles); pictures with text
  stay valid and replay without recording (before: the atlas was reset and every picture with text went stale).
- `font.Glyph_Image.epoch`, `font.Page_Ref`, `font.atlas_pages_hold`, `font.atlas_settings_generation`.
- `tests/retained`: the scene has color emoji and shaped Arabic (system fallback) next to Latin text, rotated glyphs
  with an emoji; a page reuse with tiny pages makes only the picture on it stale while a picture drawn every frame
  keeps its page and replays exactly; new rendering settings and `clear_atlas` make a picture stale; after a device
  loss a picture with text replays identically without recording.
- **Cascades**: `font.cascade(entries, features, no_system_fallback)`: per-character fallback through the entries
  (`ranges` = CSS `unicode-range`), then the **system fallback** (`IDWriteFontFallback::MapCharacters`); clusters stay
  in one face (marks, selectors, ZWJ emoji sequences). OpenType `features` on every face.
- `font.with_simulations` (synthetic bold / oblique), `font.axes`, `font.with_variations` (variable fonts),
  `font.unload`, `font.valid`, `font.primary_face`, `font.set_settings`, `font.clear_atlas`, `font.clear_word_cache`.
- **Shaping**: `font.shape` -> `Shaped{glyphs (visual order), clusters (logical order), width}` (`Glyph_Pos`,
  `Cluster`), `Shape_Options{direction, one_run, letter_spacing, word_spacing, justify}`, `font.measure`,
  `font.caret_x`, `font.hit_index`, `font.shaped_destroy`. Words shaped once and cached (sharded, bounded, per-thread
  front cache): measuring is thread-safe without a global lock.
- **Analyses**: `font.bidi_levels`, `bidi_runs`, `runs_of_levels`, `visual_order`, `reorder` (UAX #9);
  `font.line_breaks` (UAX #14, dictionaries for Thai...); `font.maybe_rtl`, `font.first_strong_rtl`.
- **Glyph bitmaps**: `font.glyph_image` (grayscale, `Settings.subpixel_steps` horizontal positions, rendering mode and
  grid fitting from `Settings`), **color glyphs** (COLR / CPAL layers composited to RGBA, drawn as images: emoji),
  atlas pages of both kinds with LRU reuse that never clears a page a current frame uses (`atlas_begin_frame`,
  `atlas_remove_user`, `atlas_page_count`, `atlas_page_info`, `atlas_evictions`).
- `draw.glyph_run(dc, size, pos, color, glyphs)` (the painter's entry point), `draw.text_ex(..., opts)`.
- `font.Settings` / `font.DEFAULT_SETTINGS` (`font.init(s, settings)`).
- `tests/text`: faces, memory faces, fallback (U+2190 in a Latin font), ligatures and kerning, Arabic joining,
  Devanagari, bidi, line breaks, color emoji pixels, atlas stress with a tiny atlas, measuring from 8 threads, and a
  WARP pixel test of drawn text.

### Changed

- `font.set_settings` with new rendering settings (subpixel steps, rendering mode, grid fit, color glyphs) forgets the
  cached bitmaps (they were made with the old settings; with other subpixel steps their keys meant other positions)
  and bumps the settings generation.
- Text under a GPU transform at its layout size (rotation, skew) is placed at subpixel positions in local units, as
  text at a uniform scale: a picture recorded at its own scale and replayed rotated draws what direct drawing draws.
- `Picture.atlas_generation` and `font.reset_atlas` are gone (`font.clear_atlas` clears the pages: pictures on them go
  stale).
- **`font` is rebuilt on DirectWrite** (stb_truetype is gone): faces from the system collection
  (`font.load_system`, `font.has_system_family`), files (`load_from_file`) and memory (`load_memory`,
  `load_from_memory`, `load_embedded`: a custom font file loader, keys never reused). Same `Font_Id`, `metrics`,
  `text_width`, `x_from_index`, `index_from_x`, `glyph` (now outline metrics) and `kern` (a pair shaped together minus
  apart) as before, so existing callers get fallback and shaping unchanged. See [docs/text.md](docs/text.md).
- `font.Metrics` gains `x_height`, `cap_height`, `underline_offset` / `_thickness`, `strike_offset` / `_thickness`.
- `draw.text` shapes (fallback, ligatures, kerning, bidi in the string's direction) and draws through `draw.glyph_run`;
  it moved to `draw/text.odin` with `TEXT_RASTER_TOLERANCE`. `draw.Context.glyphs` holds the textures of the atlas
  pages; `draw.init` / `begin_frame` / `end_frame` / `destroy` call into it (text.odin).
- `font.State` no longer has `pending` / `pending_pixels` / `glyphs` / `fonts`: the atlas is in pages uploaded per
  draw context (`font.atlas_sync_page`).

### Fixed

- `font.shape` of one right-to-left run of several words (`one_run`, a layout fragment) left its clusters in visual
  word order: the caret of the logical end and hit testing landed inside the text. Clusters are sorted back to logical
  order (`O(n log n)`).
- A full atlas no longer resets in the middle of a frame (glyphs drawn earlier in the frame showed the glyphs
  rasterized over them: "20 ☒ 7 minutes").

## [0.8.2] - 2026-10-19

### Added
- The palettes of fidget are built in: `PALETTE_GRAPHITE`, `PALETTE_NORD`, `PALETTE_DRACULA`, `PALETTE_AMBER`, `PALETTE_AERO`,
  `PALETTE_BOOTSTRAP`, the `NAMED_PALETTES` table (with Midnight and Daylight) and `palette_named(name)`. fidget uses the table.

## [0.8.1] - 2026-10-19

### Added
- **Status bars and frame statistics** (`ui/status.odin`): `status_bar(id)` (a bar along the bottom of a window, theme
  tags "bar", text a little smaller), `status_fill(id)` (the flexible part of the bar: takes the room left, clips its
  items), `status_item(id, tone, mono, clickable, width)`, `status_separator()`.
- `Frame_History`: a ring of `History_Sample`s (up to `HISTORY_SERIES` = 8 stacked values, a time, an app tag):
  `history_init` / `history_destroy` / `history_resize` (keeps the newest) / `history_clear` / `history_push` /
  `history_at` / `history_last` / `history_find_tag` (complete a sample later: GPU times arrive a few frames late) /
  `sample_total`; `history_stats(h, since_ms, budget)` (n, mean, min, max, p50, p95, p99, over budget, per-series mean
  and max, span) and `history_rate(h, now_ms, window_ms)` (samples per second).
- `frame_graph(id, &history, Frame_Graph_Opts)`: one stacked bar per sample, newest at the right; per-series colors,
  `series` (draw more series than the history counts, e.g. a GPU time over the CPU phases), `bars`, a dashed `budget`
  line, `scale` / `max_scale` (the top fits most bars; a rare spike is cut and marked instead of flattening the rest),
  `warn` / `bad` cap marks, `highlight`. The result is the box's signal plus the history index of the bar under the
  pointer. `graph_scale` gives the top it uses. Nothing asks for frames.
- `stat_row(id, label, value, width, mono, swatch_color, tone)`, `stat_heading`, `swatch`: rows of detail panels and
  graph legends.
- `popover(id, anchor, width, side, align_right)`: a floating panel above or below a widget (the other side when it
  does not fit, clamped to the window), open as long as the app builds it; `popover_rect(id)` for input the app routes
  itself.
- `render.set_gpu_timing(r, on)`: the GPU time of each `frame_submit` measured at run time, without
  `-define:GPU_TIMING` (timestamp queries in a ring, read back later: the CPU never waits); `gpu_timing_enabled`,
  `gpu_next_frame` and `gpu_result` (the time and the index of the submit it measured, to attribute it to its frame).
- `render.texture_memory(r)`: GPU memory of the renderer's textures by kind (glyph atlases, images with their mips,
  layer targets).
- `examples/fidget`: its status bar uses them (build and draw time per frame, stacked, with a tooltip per frame).

## [0.8.0] - 2026-10-19

### Added
- **Menus** rebuilt (`popups.odin`): any depth of submenus (`menu_submenu`, opens on click, after
  `MENU_HOVER_MS` of hover, or with Right / Enter / Space; to the right of its item, or the left when there is no room),
  `menu_separator`, disabled items (`menu_item(..., enabled = false)` or a `disabled` scope: muted, skipped by the
  keyboard), automatic width (`ctx_menu(key)` with width 0: as wide as the widest item), placement that stays on screen
  (flips to the other side of the point or anchor rect, then clamps), `ctx_menu_open_rect` (below a button, above when
  there is no room), `ctx_menu_open(..., from_keyboard = true)` (first enabled item selected), `menu_select`,
  `menu_depth`, `menu_rect`. An open menu owns the keyboard (key presses and typed text, in order): Up / Down / Home /
  End over enabled items (wrapping), Right / Left through submenus, Enter / Space choose, Escape closes one level, a
  letter selects the next item starting with it. Levels the app stops building close.
- **Keyboard lists** (`list.odin`): `list(id, &List_State)` + `list_row(&st, i, label, selectable)`: one Tab stop with
  an active row; Up / Down / Page Up / Page Down / Home / End (skipping non-selectable rows such as group headers),
  Enter or double click (`activated`), Escape (`cancelled`), type-ahead (`LIST_TYPEAHEAD_MS`), the active row kept in
  view; rows drawn with "selected" / "weak_selected" tags. `list_select`, `list_state_destroy`.
- **Wrapped text**: `Box_Flag.Text_Wrap` (a `.Text` height is that of all the lines at the width the X pass gave),
  `paragraph(id)`, `wrap_lines`.
- **Line edit history and commands**: Ctrl+Z / Ctrl+Y / Ctrl+Shift+Z (typing and deleting merge into steps,
  `FIELD_UNDO_STEPS`), Ctrl+Insert / Shift+Insert / Shift+Delete; `field_undo`, `field_redo`, `field_can_undo`,
  `field_can_redo`, `field_cut`, `field_copy`, `field_paste`, `field_delete`, `field_insert`, `field_select_all`,
  `field_has_selection`, `field_selection` (for context menus).
- `tab_stops(on)` scopes (widgets left out of the Tab order), `tab_direction(s)` and `focus_step(s, from, dir)` (an app
  handing the focus to its own content and back), `tabs(..., right_clicked, middle_clicked)`.
- `ui.destroy(s)` frees the state. `platform.Key.Menu` (the application key), `Num_Add`, `Num_Subtract` (Ctrl+keypad
  plus / minus zoom), keypad digits as `N0`..`N9`.
- `tests/keyboard`: menus (keyboard, submenus, Escape by level, placement, press outside), lists (moves, headers,
  type-ahead, kept in view, Enter / Escape), line edit history and clipboard, wrapped text, without a window.
- fidget: View menu with submenus.

### Changed
- `ctx_menu` (`width` now optional) pads its panel; `State.ctx_menu_key`, `menu_sel`, `menu_width`... are replaced by
  `State.menus` (the stack of open levels). Dropdowns open below their button (above without room) and from the
  keyboard (Down, Alt+Down, F4) with the current value selected.

## [0.7.0] - 2026-10-19

### Added
- **Retained drawing**: `draw.Picture`, `picture_begin` / `picture_end` (record what is drawn between them instead of
  drawing it), `replay(dc, pic, m)` (`Replay_Result`: `Drawn`, `Culled`, `Stale`), `picture_destroy`,
  `picture_release`, `picture_bounds`, `picture_stale`, `picture_size`, `recording`. Transforms pushed while
  recording are **slots** (`current_slot`, `push_slot`, `picture_set_slot`, `picture_slot`): their matrices change
  without recording again (one GPU range rewritten). Clips pushed while recording are mapped at replay (an exact
  scissor under a uniform scale + translation, as `push_clip`). A replay draws under the current transform, alpha
  stack and clips, in the order of the frame (immediate drawing and replays mix). Pictures that would show text at
  another raster size, or whose glyphs were evicted from the atlas, report `Stale`.
- Persistent GPU heaps for pictures (`render.Heap_Kind`, `heap_alloc`, `heap_free`, `heap_write`, `heap_bytes`,
  `heaps_reset`, `Slot_Data`, `Replay`, `Batch.replay`, `Frame_Data.replays`): first-fit ranges, growth by
  GPU copy. `draw.set_retained_budget` / `retained_bytes`: pictures not drawn in the current frame are evicted
  (least recently drawn first) past the budget and uploaded again from their recording when drawn.
- **Device loss**: `render.recover` recreates the device, the swap chain or offscreen target, the pipeline and every
  texture under the same handle (contents cleared: `device_generation` changes); `frame_begin` and
  `draw.begin_frame` recover on their own (`Present` failures and `GetDeviceRemovedReason` are watched);
  `device_lost`, `simulate_device_loss` (tests). The glyph atlas is reset, the heaps emptied (`heap_generation`).
- **Gradients** evaluated per pixel: `draw.gradient(dc, rect, Gradient, radii, tint)`; `Gradient_Kind` (linear,
  radial, conic), repeating, stop positions, transition hints, `Gradient_Space` (sRGB, linear, Oklab, Oklch, Lab,
  Lch, HSL, HWB), `Hue_Method`, tiles (size, repeat per axis, spacing: CSS background-size / repeat / space),
  dithering. `render.KIND_GRADIENT`, gradient tables (`Frame_Data.grads`, `GRAD_*`).
- **Box shadows**: `draw.box_shadow` (outer, optionally cut out of a rounded rect) and `draw.inset_shadow`: the
  exact gaussian blur of a rounded rect with per-corner radii (erf along x, the corner arcs integrated over their
  angle), `render.KIND_SHADOW`, `SHADOW_INSET`, `SHADOW_HOLE`.
- `Rect_Inst.aux`, `Clip_Data.xform`, `CLIP_SCISSOR`, `Batch.shape`.
- Tests: `tests/retained` (replay identical to direct drawing, slots, z order, partial recording, culling, budget,
  device loss, in both blend spaces), `tests/gradients`, `tests/shadows` (against a numeric convolution).
- `examples/transforms --retained` (with `--stress=N`).

### Changed
- `Clip_Data` is 96 bytes; `render.init` and `init_offscreen` are split (`create_swapchain`,
  `create_offscreen_target`) so that `recover` can rebuild them.
- `push_effects` / `push_layer` while recording fall back to the alpha (a picture holds no offscreen layer);
  `backdrop_capture` returns nothing.

## [0.6.0] - 2026-10-19

### Added
- **Blend spaces**: `render.Blend_Space` (`Linear`, `Srgb`): where colors mix (blending, antialiased edges,
  interpolation, image filtering and mips, layer composites). `Srgb` composites like web browsers (CSS Color 4 /
  Compositing 1: `rgba(0, 0, 0, .5)` over white is 128). `render.init(..., space)`, `render.init_offscreen(..., space)`,
  `render.set_blend_space` (at run time: frame view, translucent swap chain format and color space, pooled targets),
  `render.blend_space`. Per layer: `draw.Layer_Effects.space` (`draw.Layer_Space`), `draw.blend_space(dc)`;
  `render.Layer.space`, `render.Image_Ref.space`.
- `draw.set_interpolation(dc, .Target | .Srgb | .Linear)` (`draw.Interpolation`): where corner colors interpolate
  (`render.FLAG_LERP_SRGB`, `FLAG_LERP_LINEAR`), e.g. CSS gradients in sRGB whatever the frame's space.
- RGBA textures stored in the renderer's space when created (`render.texture_space`; `R8G8B8A8_UNORM` premultiplied on
  sRGB values in `Srgb`), converted by the shader when drawn into a target of the other space (`render.FLAG_TEX_SRGB`).
- **Text correction**: `render.Text_Rendering` (`curve`: `None`, `Srgb`, `Power`; `gamma`, `contrast`,
  `coverage_exponent`), `render.set_text_rendering`, `render.text_rendering`, `render.text_rendering_default`,
  `TEXT_RENDERING_LINEAR` (the historical look), `TEXT_RENDERING_SRGB` (Chromium on Windows: Skia's sRGB curve,
  contrast 1.0). Skia's `SkMaskGamma` computed per glyph in the vertex shader; same text weight in both spaces.
- `draw.alpha_like_linear`, `ui.tuned`: translucent colors tuned for linear light keep their look in an sRGB frame;
  `ui.apply_palette(t, p, space)`; the UI interpolates its gradients in linear light in both spaces.
- `render.linear_to_srgb`, `render.srgb_to_linear`.
- `tests/blend_space` (WARP pixel tests of both spaces); `tests/layers` and `tests/effects` run in both spaces.
- Examples: `effects --srgb`, `transforms --srgb`, fidget's Settings > Blending (and `--blending=srgb|linear`).

### Changed
- Corner colors are interpolated **premultiplied** (a transparent corner no longer darkens a gradient).
- The glyph atlas holds raw coverage (`font.GLYPH_GAMMA` is gone): the 0.8 exponent is now
  `Text_Rendering.coverage_exponent`, applied by the shader (same look in `Linear`).
- The constant buffer of `rect.hlsl` is 48 bytes (target space, text parameters).
- A translucent window's swap chain color space is set explicitly (`SetColorSpace1`).

## [0.5.0] - 2026-10-19

### Added
- **Filters** on layers: `draw.push_effects(dc, bounds, Layer_Effects{alpha, filters, blend})` (then `pop_layer`).
  `Filter` / `Filter_Kind` / `Color_Matrix`; constructors `filter_blur`, `filter_drop_shadow`, `filter_brightness`,
  `filter_contrast`, `filter_grayscale`, `filter_sepia`, `filter_saturate`, `filter_hue_rotate`, `filter_invert`,
  `filter_opacity`, `filter_matrix`; `filter_is_identity`, `filters_outset`. Chains run as GPU passes
  (`render/filter.hlsl`): color matrices fused (up to 8, clamped between), separable gaussian blur with bilinear tap
  pairs and power-of-two reductions above `render.set_blur_sigma_limit`, drop shadows. Colors are filtered in sRGB as
  browsers do.
- **Blend modes**: `Blend_Mode` (the 16 modes of CSS Compositing 1, plus `Plus_Darker` / `Plus_Lighter`) on
  `Layer_Effects.blend`; the composite reads a copy of what lies under it (`render.FLAG_BLEND`, `Batch.backdrop`).
- **Backdrops**: `draw.backdrop(dc, r, radii, filters)`, `backdrop_capture` / `backdrop_draw` (CSS backdrop-filter,
  frosted glass), `render.FLAG_SCREEN`.
- **Clip shapes**: `draw.push_clip_ellipse`, `draw.push_clip_polygon` (nonzero / even-odd), antialiased.
- Renderer: `render.Frame_Data`, `render.Op` (clear, copy, filter pass), `render.Pass`, `render.Image_Ref`,
  `render.acquire_snapshot`, `render.release_target`, `render.blur_taps`.
- `tests/effects`: pixel tests of every filter and blend mode against the specifications' formulas, blur energy /
  symmetry / profile (full resolution and reduced), drop shadows, ellipse and polygon clip coverage, backdrops,
  target reuse.
- `examples/effects` (`build.bat effects`): demo, `--stress=N`, `--bench=N`. Screenshot in `docs/screenshots`.

### Changed
- Frames run their steps **in recording order** (layers are no longer drawn before the frame): `frame_submit(r,
  Frame_Data)` replaces the positional arguments; `Batch` gains `backdrop` and `op`; `Layer.done` is gone.
- Inside a layer the clip stack restarts at the layer's rect; the clip shapes around it cut its composite.
- Pooled targets are handed back as soon as their last reader is recorded: a frame with many layers uses a few
  textures.
- `Clip_Data` is 80 bytes (`kind`, `first`, `count`, `flags`); `CLIP_CIRCLE` moved from `parent` to `flags`.

## [0.4.2] - 2026-10-18

### Added
- `draw.set_circular_corners(dc, on) -> previous`: rounded rects, images and rounded clips drawn while it is on use
  circular arcs whatever `render.set_corner_smoothing` says (the squircle suits the UI; web content and other
  specifications need circles). Per primitive: `render.FLAG_CIRCLE`, `render.CLIP_CIRCLE` (or-ed into
  `Clip_Data.parent`). Reset by `begin_frame`. Pixel test in `tests/layers`.

## [0.4.1] - 2026-10-18

### Added
- **Layers (group opacity)**: `draw.push_layer(dc, bounds, alpha)` / `draw.pop_layer` draw into an offscreen render
  target composited once with `alpha`, so overlapping primitives of the group do not show through each other (CSS
  `opacity`). Transforms, rounded / rotated clips, images, text and nested layers work inside. Falls back to
  `push_alpha` when the layer would be empty or too large. `draw.layer_depth`.
- Renderer support: `render.Layer`, `Batch.target`, `frame_submit(..., layers)`, a pool of fp16 render targets
  (`render.acquire_target`, `release_targets`, `targets_bytes`), `render.FLAG_LAYER` (texel-exact composite).
- **Offscreen renderer**: `render.init_offscreen(r, size, warp)` (no window; WARP software rasterizer available) and
  `render.read_pixels`. `render.destroy` releases every GPU object.
- `tests/layers`: pixel tests (group opacity vs. per-primitive alpha, opaque layer = no layer, nested layers with a
  rotated rounded clip, target pooling, fallback).
- `examples/transforms`: the orbiting planet fades as one group (`push_layer`).

### Changed
- The shader constant buffer is 32 bytes (adds `target_origin`). `init` is split into device creation and pipeline
  setup (shared with `init_offscreen`); `frame_end` and `resize` do nothing for an offscreen renderer.

## [0.4.0] - 2026-10-18

### Added
- **2D affine transforms** in `draw`: `Affine` (CSS `matrix(a, b, c, d, e, f)` convention), `push_transform` /
  `pop_transform`, `current_transform`, and the helpers `affine_mul`, `affine_translate`, `affine_scale`,
  `affine_rotate`, `affine_skew`, `affine_around`, `affine_apply`, `affine_apply_vector`, `affine_inverse`,
  `affine_bounds`, `affine_determinant`, `affine_scale_factor`, `affine_is_identity`, `affine_is_scale_translate`,
  `affine_from_xform`. Rects (rounded, borders, shadows), gradients, text and images follow the transform; rotated and
  skewed shapes are evaluated in local space in the pixel shader (exact corners, 1 px antialiasing). Scaled text is
  re-rasterized at its on-screen size.
- **Rounded / transformed clips**: `draw.push_clip_rounded(dc, r, radii)` (per-pixel, antialiased, nests up to 8
  deep); `push_clip` under rotation or skew clips the exact rect. `draw.current_clip`.
- **Images**: `render.create_texture_rgba`, `update_texture_rgba` (sRGB, straight alpha in; stored premultiplied in
  linear light), `destroy_texture`, `texture_size`, `max_texture_size`; mip chains regenerated after updates.
  `draw.image`, `draw.image_corners` (rounded corners, sub-rectangles, tint) and `draw.image_tiled` (seamless
  repeat). Images and glyphs share batches.
- `examples/transforms` (`build.bat transforms`): animated demo, `--stress=N` / `--bench=N` load test.
- `-define:GPU_TIMING=true` + `render.gpu_ms`: GPU time of the frame (timestamp queries).
- Unit tests for the affine helpers: `odin test tests/affine`.
- [docs/draw.md](docs/draw.md): transforms, clips, images, costs and limits.

### Changed
- `render.Rect_Inst` is 144 bytes (adds `xform`, `clip`, `flags`); `use_tex` takes `KIND_SHAPE` / `KIND_GLYPH` /
  `KIND_IMAGE`. `render.Batch` gains `image`; `render.frame_submit` takes the optional transform and clip tables.
- `draw.Context.clips` holds `draw.Clip` (scissor + shape) and `xforms` holds `draw.Transform` (an `Affine`).
  `push_scale` / `pop_xform` keep their behaviour; the existing examples render pixel-identical to 0.3.2.
- Soft shapes (`soft > 1`) drawn under `push_scale` scale their blur with the rest of the shape.

## [0.3.2] - 2026-10-15

### Fixed
- Wine (and any system without DirectComposition): `render.init(transparent = true)` fell over on
  `CreateSwapChainForComposition`; it now falls back to an opaque window (`render.is_transparent` tells which).
- fidget: removing one of the initial tags crashed (it deleted a string literal).
- fidget: a clicked or dragged sticky note went to the back instead of the front.

## [0.3.1] - 2026-10-15

### Changed
- **Self-contained exes**: the icon font is compiled in (`ui.ICON_FONT_DATA`, `font.load_embedded`); nothing has to
  sit next to the exe any more.
- Text fonts: Segoe UI and Consolas are read from the Windows font folder (`platform.system_font_path`); when they
  are missing (Wine, trimmed installs) the exe falls back to Roboto and Inconsolata compiled into it
  (`font.load_system_or_embedded`, `font.FALLBACK_UI_DATA`, `font.FALLBACK_MONO_DATA`). fidget: `--embedded_fonts`
  forces the fallbacks.

## [0.3.0] - 2026-10-15

### Added
- **Arrow-key focus navigation**: once a widget that does not use arrows has the focus, the arrows move it to the
  nearest Tab stop in that direction (trapped inside modals, scrolled into view). Sliders, text fields and open
  menus keep their arrows.
- **Scrollbars**: every `View_Scroll_Y` box gets an overlay scrollbar (drag the thumb, click the track to jump);
  `text_edit` has vertical and horizontal bars.
- **Wrapping rows**: `ui.flow(gap)` and the `Wrap` box flag place children left to right and start a new line when
  the row is too narrow. Chips and the fidget button / tag / swatch rows use it.
- **Corner rounding**: `ui.set_rounding` (0 = square, 1 = default, up to 2) scales box radii and widget chrome;
  `ui.rad` for custom draws. Radio buttons stay round, and so do boxes with the new `Fixed_Radius` flag.
  Rounded rects can use squircle corners (`render.set_corner_smoothing`), which removes the visible kink where an
  arc meets a straight edge. At rounding 0 the Windows 11 window corners go square (`platform.set_square_corners`).
- **Density**: `ui.set_density` / `ui.dense` (Comfortable or `DENSITY_COMPACT`): row heights, vertical gaps and
  paddings shrink, the text keeps its size.
- **Disabled and muted scopes**: `if ui.disabled(cond) { ... }` disables everything built inside (no clicks, hover or
  focus) with a neutral look and a fade; `button_icon(disabled = ...)` uses it. `if ui.muted() { ... }` dims
  secondary content that stays interactive.
- **Finishes**: `Palette.finish` paints raised surfaces `Flat`, `Gradient` (Bootstrap 2: vertical gradient, top
  highlight, embossed text, focus glow) or `Glass` (Windows 7 Aero: glossy top half, bottom glow, white rim).
  `ui.paint_rect` gives custom draws the same finish. Palettes can also set a bar colour.
- **Translucent windows**: `render.init(transparent = true)` presents through DirectComposition with a linear fp16
  (scRGB) swap chain, so translucent pixels compose correctly; `platform.set_backdrop` shows the Windows 11 acrylic
  backdrop behind them.
- **Selection outline**: selected rows, menu items and palette entries get a crisp accent border over a light fill.
- fidget: Aero and Bootstrap themes (8 themes; Graphite is now the default), Settings for rounding, corner shape and
  density, an "Enabled" switch that disables a card, a grouped data table (collapsible department groups with
  totals, two-line headers with column totals, right-aligned numbers, column separators, alternating rows),
  `--bench=N` (CPU time per frame), `--compact`, `--size=WxH`, `--long_text`.
- `tools/keyboard_test.ps1`: 33 checks (arrow navigation, menus closing on a click outside).

### Changed
- A box with `Draw_Border` keeps its border out of the layout (like CSS border-box): its children sit inside it, so a
  border never hides a child's own outline.
- Disabled boxes no longer get a dimming overlay: they switch to neutral colours and fade as a whole.

### Fixed
- Context menus and dropdowns now close on a click anywhere outside, not only on clickable boxes.
- Rects ignored the alpha stack (`draw.push_alpha`): only text faded.
- The page and the menu bar inherited the default radius, leaving dark pixels in the window corners.
- The sort arrow and resize lines of the table header were not aligned with the column separators.

## [0.2.0] - 2026-10-15

### Added
- **Multi-line editor** `ui.text_edit` with `ui.Text_Area`: selection (keyboard and mouse, double-click word),
  Up / Down keep the column, Home goes to the first non-blank character, Ctrl+Home / End, Page Up / Down,
  word moves and deletes, Enter keeps the indentation, clipboard (CRLF and tabs normalized), undo / redo
  (Ctrl+Z, Ctrl+Y or Ctrl+Shift+Z; edits grouped per second), wheel scrolling, optional line numbers,
  optional Tab-indents mode, Ctrl+Enter = committed, Escape leaves the field.
- **Keyboard focus navigation**: Tab / Shift+Tab move through the Tab stops in build order (wrapping), the
  focused widget is scrolled into view and gets a focus ring; Enter / Space activate buttons, checkboxes, radios,
  switches, segmented items, chips, tabs and dropdowns; sliders take arrows, Page Up / Down, Home / End.
  Inside a modal, Tab cycles through the dialog only, and the page loses the focus when the dialog opens.
- **Context menus and dropdowns from the keyboard**: Up / Down select, Enter / Space choose.
- `ui.focused_name()` (id of the focused box), new box flags `Text_Input` and `Scroll_Self`.
- fidget: a multi-line editor card, more shortcuts in the cheat sheet, `--state_title` for scripted tests.
- `tools/keyboard_test.ps1`: 28 checks with real keystrokes and modifiers (Ctrl+A/C/V, Tab, Space, Ctrl+Z/Y,
  Ctrl +/-/0, Ctrl+K, Ctrl+, and a dropdown driven from the keyboard), only sent while fidget is in front.
- New logo: a white switch and slider on a cobalt rounded square (`tools/make_logo.ps1`), also the icon of `todo.exe`.

### Fixed
- `icon_button` registered its box under a key it then replaced: the button could not hold the keyboard focus.
- A focused widget no longer steals Enter / Space from an open context menu.

## [0.1.0] - 2026-10-15

First release.

### Added

- **platform** (Win32): per-monitor DPI aware window sized from the monitor DPI, events (keys, text with UTF-16
  surrogates, mouse, wheel with modifiers), clipboard, cursors, dark title bar, OS "show animations" setting,
  `wait_event` / `poll_events` (re-entrancy safe during live resize), app icon from resource id 1.
- **render** (Direct3D 11): one instanced-quad pipeline for SDF rounded rects, borders, soft shadows and glyphs;
  sRGB target (linear blending); waitable swap chain with one frame in flight for low input latency
  (~47 ms input-to-scan-out at 60 Hz, measured); `RENDER_PROBE` latency / frame-gap probe.
- **font**: TrueType via `stb_truetype`, glyph cache, shelf-packed atlas, text measurement and caret mapping.
- **draw**: rects (per-corner colors and radii), text, clip / alpha / scale stacks, sRGB / hex / HSV helpers.
- **ui**: box tree with keyed persistence (`##` / `###` id rules), style / tag / parent scopes using
  `@(deferred_none)`, five-pass layout (pixels, text, percent, children-sum, strictness, floating, cross-axis
  alignment, scrolling), signals (hover, press, click, double / right / middle click, drag, wheel), animations
  that follow the OS setting, tag-based themes with cross-fades and two built-in palettes, built-in zoom
  (Ctrl+wheel, Ctrl +/-/0).
- **Widgets**: label, button (+icon), icon button, checkbox, radio, switch, slider, range slider, stepper,
  segmented control, chips, rating, progress (determinate / indeterminate), dropdown, tabs, key caps, cards, form rows,
  single-line text field (selection, word moves, clipboard, mouse), scroll region, context menu, menu bar, tooltips,
  toasts (8 positions), modal dialogs, color pickers, fuzzy matching with highlighted labels, custom-draw boxes.
- **fidget**: widget gallery (Controls, Inputs, Data with a 20,000-row virtualized table, Playground), command
  palette, menu bar, Settings and About dialogs, six themes, persisted settings.
- **todo**: a todo app with persistence, filters, search, context menu, light / dark theme.
- **smoke**: renderer, font and draw layers without the UI.
- `build.bat`, embedded exe icons, scripted interaction tests (`tools/fidget_test.ps1`, `tools/ui_test.ps1`),
  screenshot generator (`tools/screenshots.ps1`), icon generator (`tools/make_icon.ps1`).

[0.200.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.200.0
[0.199.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.199.0
[0.197.4]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.197.4
[0.198.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.198.0
[0.197.3]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.197.3
[0.197.2]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.197.2
[0.197.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.197.1
[0.197.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.197.0
[0.196.3]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.196.3
[0.196.2]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.196.2
[0.196.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.196.1
[0.196.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.196.0
[0.195.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.195.1
[0.195.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.195.0
[0.194.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.194.0
[0.193.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.193.0
[0.192.3]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.192.3
[0.192.2]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.192.2
[0.192.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.192.1
[0.192.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.192.0
[0.191.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.191.1
[0.191.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.191.0
[0.190.2]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.190.2
[0.190.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.190.1
[0.190.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.190.0
[0.189.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.189.1
[0.189.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.189.0
[0.188.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.188.0
[0.187.2]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.187.2
[0.187.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.187.1
[0.187.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.187.0
[0.186.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.186.0
[0.185.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.185.0
[0.184.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.184.0
[0.183.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.183.0
[0.182.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.182.0
[0.181.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.181.0
[0.180.3]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.180.3
[0.180.2]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.180.2
[0.180.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.180.1
[0.180.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.180.0
[0.179.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.179.0
[0.178.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.178.0
[0.177.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.177.1
[0.177.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.177.0
[0.176.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.176.1
[0.176.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.176.0
[0.175.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.175.1
[0.175.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.175.0
[0.174.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.174.0
[0.173.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.173.0
[0.172.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.172.0
[0.171.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.171.0
[0.170.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.170.0
[0.169.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.169.0
[0.168.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.168.0
[0.165.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.165.1
[0.167.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.167.0
[0.166.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.166.0
[0.165.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.165.0
[0.164.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.164.0
[0.163.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.163.0
[0.162.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.162.0
[0.161.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.161.0
[0.160.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.160.0
[0.159.2]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.159.2
[0.159.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.159.1
[0.159.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.159.0
[0.158.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.158.0
[0.157.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.157.0
[0.156.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.156.0
[0.155.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.155.0
[0.154.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.154.0
[0.153.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.153.0
[0.152.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.152.0
[0.151.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.151.0
[0.150.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.150.0
[0.149.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.149.0
[0.148.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.148.0
[0.147.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.147.0
[0.146.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.146.0
[0.145.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.145.1
[0.145.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.145.0
[0.144.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.144.0
[0.143.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.143.0
[0.142.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.142.0
[0.141.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.141.1
[0.141.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.141.0
[0.140.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.140.0
[0.139.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.139.0
[0.138.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.138.0
[0.137.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.137.0
[0.136.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.136.0
[0.135.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.135.0
[0.134.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.134.0
[0.133.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.133.0
[0.132.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.132.0
[0.131.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.131.0
[0.130.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.130.0
[0.129.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.129.0
[0.128.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.128.0
[0.127.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.127.0
[0.126.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.126.0
[0.125.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.125.0
[0.124.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.124.1
[0.124.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.124.0
[0.123.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.123.0
[0.122.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.122.0
[0.121.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.121.0
[0.120.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.120.0
[0.119.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.119.0
[0.118.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.118.0
[0.117.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.117.0
[0.116.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.116.0
[0.114.2]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.114.2
[0.115.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.115.0
[0.114.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.114.1
[0.114.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.114.0
[0.113.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.113.0
[0.112.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.112.0
[0.111.3]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.111.3
[0.111.2]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.111.2
[0.111.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.111.1
[0.111.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.111.0
[0.110.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.110.0
[0.109.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.109.0
[0.108.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.108.0
[0.107.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.107.0
[0.106.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.106.0
[0.105.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.105.0
[0.104.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.104.1
[0.104.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.104.0
[0.103.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.103.0
[0.102.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.102.0
[0.101.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.101.0
[0.100.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.100.0
[0.99.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.99.0
[0.98.3]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.98.3
[0.98.2]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.98.2
[0.98.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.98.1
[0.98.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.98.0
[0.97.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.97.0
[0.96.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.96.0
[0.95.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.95.0
[0.94.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.94.0
[0.93.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.93.0
[0.92.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.92.0
[0.91.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.91.0
[0.90.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.90.0
[0.89.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.89.0
[0.88.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.88.0
[0.87.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.87.0
[0.86.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.86.0
[0.85.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.85.0
[0.84.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.84.0
[0.83.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.83.0
[0.82.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.82.0
[0.81.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.81.0
[0.80.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.80.0
[0.79.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.79.0
[0.78.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.78.0
[0.77.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.77.0
[0.76.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.76.0
[0.75.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.75.0
[0.74.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.74.0
[0.73.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.73.0
[0.72.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.72.0
[0.71.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.71.0
[0.70.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.70.0
[0.69.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.69.0
[0.68.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.68.0
[0.67.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.67.0
[0.66.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.66.0
[0.65.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.65.0
[0.64.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.64.0
[0.63.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.63.1
[0.63.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.63.0
[0.62.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.62.0
[0.61.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.61.0
[0.60.2]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.60.2
[0.60.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.60.1
[0.60.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.60.0
[0.59.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.59.0
[0.58.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.58.0
[0.57.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.57.1
[0.57.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.57.0
[0.56.2]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.56.2
[0.56.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.56.1
[0.56.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.56.0
[0.55.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.55.0
[0.54.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.54.0
[0.53.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.53.0
[0.52.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.52.0
[0.51.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.51.0
[0.50.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.50.0
[0.49.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.49.0
[0.48.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.48.1
[0.48.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.48.0
[0.47.2]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.47.2
[0.47.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.47.1
[0.47.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.47.0
[0.46.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.46.0
[0.45.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.45.1
[0.45.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.45.0
[0.44.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.44.0
[0.43.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.43.0
[0.42.3]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.42.3
[0.42.2]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.42.2
[0.42.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.42.1
[0.42.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.42.0
[0.41.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.41.1
[0.41.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.41.0
[0.40.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.40.1
[0.40.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.40.0
[0.39.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.39.0
[0.38.3]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.38.3
[0.38.2]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.38.2
[0.38.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.38.0
[0.37.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.37.0
[0.36.2]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.36.2
[0.36.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.36.1
[0.36.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.36.0
[0.35.3]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.35.3
[0.35.2]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.35.2
[0.35.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.35.1
[0.35.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.35.0
[0.34.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.34.0
[0.33.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.33.0
[0.32.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.32.1
[0.32.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.32.0
[0.31.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.31.0
[0.30.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.30.1
[0.30.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.30.0
[0.29.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.29.0
[0.28.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.28.0
[0.26.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.26.0
[0.25.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.25.0
[0.23.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.23.0
[0.22.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.22.1
[0.22.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.22.0
[0.19.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.19.0
[0.18.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.18.0
[0.17.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.17.1
[0.17.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.17.0
[0.16.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.16.0
[0.15.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.15.0
[0.14.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.14.0
[0.13.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.13.1
[0.13.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.13.0
[0.12.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.12.0
[0.11.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.11.1
[0.11.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.11.0
[0.10.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.10.1
[0.10.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.10.0
[0.9.3]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.9.3
[0.9.2]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.9.2
[0.9.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.9.1
[0.9.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.9.0
[0.8.2]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.8.2
[0.8.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.8.1
[0.8.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.8.0
[0.7.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.7.0
[0.6.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.6.0
[0.5.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.5.0
[0.4.2]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.4.2
[0.4.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.4.1
[0.4.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.4.0
[0.3.2]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.3.2
[0.3.1]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.3.1
[0.3.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.3.0
[0.2.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.2.0
[0.1.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.1.0
