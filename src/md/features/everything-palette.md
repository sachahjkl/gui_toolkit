# The everything palette: intent

The palette ([palette.md](palette.md)) reaches every act of a program. Today it runs a command, flips a switch, or
opens the settings on a setting. This design lets each item of the palette show its own control in the palette, so a
person drives the whole program from it without going where the act lives, and can still go there. Modus's palette
(`kernel/src/md/features/palette.md`, "The form of an entry, from its descriptions") proved the model; this is its
form in the toolkit.

## The problem

- **A setting is not editable in the palette.** A switch flips; any other setting opens the settings page. A font, a
  theme, a number, a choice of three: each one leaves the palette.
- **The control of a value comes from its name, not from its nature.** `config.Def.kind` says how a value is stored
  (`Bool`, `Int`, `Float`, `String`). The settings page gives a font picker to the family settings because it knows
  their names (`Standard_Targets.faces`), and theme cards because the program passes `Page_Options.themes`. `unit` is a
  free text ("ms") and `bytes` a flag beside it. A program's new font setting is a text field, everywhere.
- **A command takes no argument.** "Rename the session" opens a dialog; "Set the model" is a source of its own.
- **There is no way back to where an act lives.** The palette cannot open the page, scroll to the control, and give it
  the focus.

## The model

### 1. A value's nature, apart from its storage

`config.Def` gains its **value kind** (`Def.value_kind`): what the value is, not how it is kept (`Def.kind`). One
closed table of the toolkit (`config.Value_Kind`). A value kind checks what it can without the disk or the system, at
every layer (the page, the file, the command line, a policy); a value it refuses is `Bad_Type`, and `config.value_hint`
says what it takes. The empty text is a value of every text kind: "none, the program's own" (a family's "Default").

| Value kind | Stored as | What it is | What it checks | Shown |
|---|---|---|---|---|
| `Plain` | any | no nature of its own: its storage decides | its storage, bounds, choices | as stored |
| `Font_Family` | String | a family of the system's fonts | nothing (below) | its name |
| `Theme` | String | a theme of the program's list | nothing (below) | its name |
| `Color` | String | a colour | `#` and 3, 4, 6 or 8 hex digits | as stored |
| `Path` | String | a file or a folder | no NUL byte | as stored |
| `Address` | String | a URL | a scheme, then `:` and more (`https://…`, `mailto:…`) | as stored |
| `Keys` | String | a chord, or chords apart by spaces | each chord's parts apart by `+`, none empty | as stored |
| `Size` | Int | a count of bytes, KiB or MiB | ≥ 0; `B`, `K`/`KiB`, `KB`, `M`/`MiB`, `MB`, `G`…, `T`… typed | `4 MiB`: the largest unit that is exact |
| `Duration` | Int / Float | a time | ≥ 0; `ms`, `s`, `min`, `h`, `d` typed | `300 ms`, in its unit |
| `Fraction` | Float | a share, 0 to 1 | 0 to 1; `45%` typed | `45 %` |
| `Length` | Int / Float | a length on the screen | its own symbol typed (`12 px`) | `12 px`, `1.5 em` |
| `Factor` | Float | a multiplier | its symbol typed (`1.5×`, `1.5x`) | `1.25 ×` |
| `Rate` | Int / Float | a count per second | its symbol typed (`30/s`) | `30 /s`, `400 px/s` |

`Factor` and `Rate` were not in the first table; real settings need each, and as `Plain` numbers they would have lost
their unit, which the units' table forbids (a unit belongs to a kind):

- `Factor` (×): the toolkit's `appearance.zoom`, `appearance.density`, `appearance.rounding`, `input.zoom_step`,
  `input.step_shift`, `input.step_ctrl`, `input.step_alt`.
- `Rate` (`/s`): the toolkit's `input.key_repeat_rate`, cliche's `record.fps` and `record.gif_fps`, Wren's
  `browser.touch.fling_friction` (1/s). `Rate` in `px/s`: the toolkit's `scrolling.fling_stop_speed` and
  `scrolling.autoscroll.max_speed`, Wren's `browser.touch.fling_min_speed`. A speed is no `Length`: a typed "px" alone
  would be refused, and a rate's slider steps in its own unit. A family and a theme are not checked: their lists are the system's and the program's, known
to the interface only once read on a chore, and a value no longer in the list (a font removed) is the person's choice
kept for when it comes back. A path is not checked on the disk: the interface's thread reads no disk.

A number's **unit** (`Def.unit`, a `config.Unit`) is data of the kind, taken from one table of units (`config.UNITS`),
as Modus's integer units: a text unit can say anything, and two settings of one nature must read alike. Each unit
belongs to one kind; `.None` is the kind's first unit. `register` asserts both (a unit of another kind, a kind on a
storage it does not take): a program's mistake shows at its first start.

| Kind | Units (the first is `.None`'s) |
|---|---|
| `Size` | `Byte`, `Kibibyte`, `Mebibyte` |
| `Duration` | `Millisecond`, `Second`, `Minute`, `Hour`, `Day` |
| `Length` | `Pixel`, `Em`, `Milli_Em` (‰ em) |
| `Fraction` | `Percent` |
| `Factor` | `Times` |
| `Rate` | `Per_Second`, `Pixel_Per_Second` |

The units are those the programs' settings hold today (Wren keeps sizes in MiB, its periods in hours and days); a count
of things ("nodes", "items") is no unit: a `Plain` number, its title says what it counts. `unit` (free text) and
`bytes` went: `bytes` is `Size`. Only `Size` and `Duration` convert between their units when
typed (a byte and a millisecond are fixed); an em depends on the font and a pixel per second is no count per second, so
`Length` and `Rate` accept their own symbol only. A bare letter `K`, `M`, `G`, `T` is binary (1024), as the old `bytes`
read it and as `KiB` shows; `KB`, `MB`… are decimal, as written. The file keeps the stored number (`4194304`), never the
text shown: a profile is read by every version, in every language.

A bare number is in the setting's unit, with one exception: a `Fraction` in the file and on the command line is the
stored share (`0.45`), and in the page's number field the percent it shows (`45`). `config.parse_value` reads the
first, `config.parse_shown` the second.

### 2. The control comes from the value, in one table

One table of the toolkit gives the control of a value from its storage, its value kind and its choices. The settings
page and the palette read it; no name of a setting appears in either.

| The value | The control |
|---|---|
| Bool | a switch, flipped in place |
| a closed list of at most 6 values | a row of buttons, the value in use marked |
| a closed list of more | a sub-list that filters as one types, the value in use marked |
| `Font_Family` | the sub-list of families, each name in its own face |
| `Theme` | the sub-list of themes, each with its swatches |
| `Color` | the colour picker |
| `Keys` | the shortcut recorder |
| a number | a stepper or a slider with its unit; `Size` and `Duration` take their suffixes when typed |
| `Path` | a field that completes paths |
| free text | a field |

A program that needs another control gives a kind of its own in its `Page_Options.custom`, as today; it is never
derived from a name.

**Layer 1, as built.** The table is `prefs_page.control_of` (a `Control` from the Def, the count of its choices and of
the program's themes, and whether the program draws it), and `prefs_page.setting_line` draws a preference's line with
the control it gives; the settings page draws every line with it. `ui` may import `config` (no cycle: `config` imports
no package of the interface), but the controls need what only `prefs_page` holds: the page's state (a field's text
while typed, the held slider, the font pickers, the colour being picked), the program's data in `Page_Options` (its
themes, its choices, its own controls) and the registry's writes with the program's `changed`. The palette's settings
source is in `prefs_page` too, so layer 2 draws the same controls there.

| `Control` | Given to | Drawn as, on the page |
|---|---|---|
| `Custom` | a name of `Page_Options.custom_names` | the program's, under the words |
| `Switch` | Bool | a switch |
| `Segments` | a closed list of at most 6 (`SEGMENTS_MAX`) | a row of buttons; under the words when they do not fit |
| `List` | a closed list of more | a drop-down list (the filtering sub-list is the palette's, layer 2) |
| `Font_Family` | `Font_Family` | the font picker, each family in its face, its default the program's face |
| `Theme` | `Theme`, the program giving its themes | the cards with their swatches, under the words |
| `Color` | `Color` | a swatch and the value on a button; a click opens the colour picker in a popover under it, as the font picker's list |
| `Keys` | `Keys` | the shortcut recorder |
| `Number` | a bounded number (`max > min`) but `Size` | a slider, the field, − and +, its unit; the field reads the unit's suffixes |
| `Field` | the rest | a field, in the monospace face for a `Path` or an `Address`; a number's unit after it |

A `Size` is a field and never a slider: its ranges span powers of two (1 KiB to 1 GiB), which a linear track cannot
reach, and "4 MiB" is read and written whole. A `Theme` without a theme list, and a closed list's value the program
fills (`Page_Options.choices`), fall to the next rule: a field, or the list. A path's field completes in the palette's
run mode (below, "A path completes").

What only picked a control by a name went: the page's switch on the three family names, `THEME_PREF` as the cards'
trigger, `Page_Options.hotkeys`. What stays is the program's data: `Page_Options.themes` (the list the cards show) and
`appearance.mode` (which version of each theme the cards show), the standard family settings' faces
(`standard_face_of`: which of the program's faces a family replaces, so the picker names that face as its default and
lists monospaced families first for the monospace one; a program's own family setting names the interface's face),
`Page_Options.shortcut_prefs` (what the system says of a global shortcut).

### 3. An item's modes

A row stays compact: its title, and at its right the value in use ("Theme  Nord"), read for the rows in view only, as
the mark is. Nothing more until the person asks.

- **Enter runs.** A command runs. A switch flips and the palette stays. Any other value opens the **run mode** of its
  row: the control unfolds under the row, in the palette; the field's text becomes the control's filter where it has
  one (a family, a theme).
- **In the run mode, a change applies at once** (a font, a theme, a density): the person sees the result while they
  move through the list. **Enter keeps it** and goes back to the list; **Escape puts back the value of before** and goes
  back.
- **Shift+Enter goes to** where the act lives (below). A source's own Shift+Enter alternate is replaced by it: one
  meaning everywhere. (A source that needs another act gives it on Ctrl+Enter or Alt+Enter.)
- **The palette keeps its height.** The field never moves; the list under the unfolded control scrolls.

### 4. Commands with arguments

A `ui.Command` can state its **arguments**: each one a name, a storage, a value kind, choices, bounds, as a setting's
value. Enter on such a command opens its form in the run mode, each argument with the control of rule 2; Enter on the
last runs it. "Rename the session" is a command with one text argument; "Set the model" one with a closed list that the
program fills. No form is written for one command.

### 5. Go to, by an act name

An element of the interface can state the **act name** of what it acts on: `setting:appearance.theme`,
`command:session.rename`. The toolkit keeps the act names of the elements of the frame shown, in each view. An item of
the palette has the act name of its setting or its command. Shift+Enter shows the view that holds that act name (the
settings page on its setting, a view's home), scrolls the element into view, gives it the focus and lights it once. A
program writes nothing for go to but the act name of the element. An item whose act name no view can show has no go to,
and its hint row does not offer it.

### Layer 2, as built: the run mode

The run mode is a state of the palette (`ui.Palette_Run`, `src/ui/palette_run.odin`), apart from what a value is:

```
List ──Enter on an item that runs──▶ Control (a setting's value)        ──Enter: kept──▶ List
  ▲                                │                                    ──Escape: put back──▶ List
  │                                └▶ Form, argument 0 ──Enter──▶ argument 1 … ──Enter on the last──▶ the choice, closed
  └──────────────── Escape at argument 0 ◀── Escape at argument n steps to n − 1
any level ──a close the palette did not ask (a click outside, Ctrl+K, its window gone)──▶ closed, as Escape at each level
any level ──its item gone from its source's answer──▶ List, nothing put back
```

- **The palette owns the levels and the keys; a runner owns the values** (`ui.Palette_Runner`: open, text, build,
  write, undo, values, close). The settings source's runner and the commands' forms runner are `prefs_page`'s
  (`prefs_page/palette_run.odin`): only it has the control table. `ui` imports `config` for `Command.arguments`
  (`config` imports no package of the interface).
- **The palette's field keeps the keyboard.** Its text is the control's filter (a family, a theme, any closed list) or
  the value's text (a number, a colour, keys, a field), set when the control opens; the query is kept and put back at
  the close. Enter and Escape are always the palette's, read before the field: a field inside the control would take
  Enter for itself, and the run mode would not know a value was kept. Up, Down, Page Up and Page Down go to the
  control: they move through a list or step a number.
- **Every write happens in `palette_chosen`, at the top of the program's next build**, before the page is built. The
  palette's view is built after the program's content; a value written there would show in the palette one frame
  before the page (the day-one test 1). The view notes the write; `palette_chosen` makes it.
- **In the palette every closed list is the sub-list** (`ui.palette_sublist`): rows of one height, the rows in view
  built, a short list too. The page keeps its row of buttons for six choices or fewer, where a line has the height of
  one button; in the palette one way through the choices by the keys is worth more than the look of the page. A
  filter typed selects the best row and writes nothing; a move (a key, a click) writes at once; Enter writes the row
  selected, then keeps.
- **A number**: Up and Down step it, the slider under the row writes when it is let go (as on the page, the file is not
  rewritten at the pointer's rate), the text typed is written at Enter. **A colour**: the picker without its own text
  (`color_picker`'s `text = false`): the palette's field is that text, said once. **Keys**: the text, or the recorder
  under it. **A free field** (a path, an address, a size): its text, written at Enter; a value refused stays in the
  field, its reason under it.
- **A path completes** (`prefs_page/palette_path.odin`). Under the field, the entries of the folder typed (the text up to
  its last separator; `~` is the home folder) that start with its last part, folders first, each group by name; a name
  that starts with a dot shows only when the part typed does. Up and Down choose one, Tab (or a click) puts it in the
  field, a folder with its separator, so the next Tab goes on inside it; Enter keeps the field's text. The folder is
  read on a chore when the folder typed changes, never at each build and never on the interface's thread (a share that
  hangs costs the palette nothing but "Reading the folder…"). Tab belongs to the run mode's control
  (`Palette_Run_Keys.tab`), and the control writes the field with `palette_run_set_text`, as the person typing would.
  Refused: completing on each key typed (a shell's way): the field would change under the fingers.
- **Undo.** The runner notes the value before and whether it was the default. Escape puts it back (a reset when it was
  the default, so the file does not gain a line), only when the value now is the last one the run mode wrote: another
  path that wrote since wins.
- **The run row says its title; its value is in the control** (the field, the mark in the sub-list): the value at the
  row's right goes while it is open, said once. The hint row says the run mode's keys ("Enter Keep", "Escape Put
  back"; a form's "Enter Next" and "Escape Back").
- **The run mode takes the list's room.** Under the field: the run row, then the control, which fills the rest; its
  sub-list scrolls. The other rows step aside until Enter or Escape: the palette keeps its height.
- **A locked setting** (a policy, the command line) is a disabled row with its value at its right and its reason as
  its detail ("Locked by a policy."): no control.
- **Its item is kept by its source and its id**, looked up again only when the sources' answers change (the palette's
  generation), never at each build.

### Layer 3, as built: act names and go to

- `ui.act_name(box, name)` states the act name of a box at its build. Each State keeps the act names of its last
  frame (`acts`, a map of the name's 64-bit hash to the box's key, filled while the frame is built and swapped at its
  end): the work is one insert per element built, none per frame over data. A hash and not the name: no string kept per
  frame; two names of one hash in one window are not expected (64 bits).
- `ui.act_shown(name)`: whether a window of the program (the States its Views build in) showed it in its last frame.
  `ui.act_go(name)` goes there: at the end of the build that shows it (after the layout, the rects final) the box is
  scrolled into view in each scroll box around it, its first focusable box gets the focus, its view comes forward, and
  it is lit once (`ACT_LIGHT_MS`, a fading ring of the accent; with the animations off it stays still and goes). Not
  shown yet: the wish waits `ACT_GO_BUILDS` builds for it (the settings opened by the same press come at the next one).
- **A source reaches what no frame shows** (`Palette_Source.reach`): the settings source shows the setting's page
  (its Advanced part unfolded when the setting is one, the page's search cleared) and asks the program to show its
  settings. The commands source reaches nothing: a command is reachable when an element states its act name in a frame
  shown (a toolbar's button).
- **Shift+Enter is go to, in every source.** An item with an act name that a frame shows or its source reaches: the
  palette closes and goes there. The hint row says "Shift+Enter Go to" only for it; for another item Shift+Enter does
  what Enter does. `Palette_Alternates.shift` and `Palette_Commands_Options.shift` went: one meaning everywhere.
- The settings page names each setting's line `setting:<name>`; the commands source names its items `command:<id>`.

### Layer 4, as built: commands with arguments

- `ui.Command.arguments: []config.Def`: each argument is a value as a setting is (its name, storage, value kind,
  unit, choices, bounds, default). A closed list the program fills: `Palette_Commands_Options.choices(user, command,
  argument)`, as `Page_Options.choices` for a setting.
- The forms runner keeps a registry of its own for the form (`config.Prefs`, the arguments registered), so each
  argument gets the control of the table and is checked as a setting is, with no form written for one command.
- Enter on the last argument ends the run mode and closes the palette; `palette_chosen` returns the command with
  `Palette_Choice.arguments`: each value as the settings file writes it (`config.value_text`), in the arguments' order.
- A program without the settings source installs the forms runner alone: `prefs_page.palette_forms_use`.

## Decisions

- **One source of truth.** The palette and the settings page both read and write the registry (`config`). A change in
  one shows in the other at the next frame; no copy of a value is kept in the palette.
- **Data, not widgets.** A source and a program give values, kinds, choices and act names; the toolkit chooses the
  control from its closed table. A source that drew its own control would make each program's palette different again.
- **Live change, with Escape to undo**, because a font or a theme is judged by seeing it. The value before the run mode
  is kept until Enter or Escape; a value written by another path meanwhile (a sync, the page) wins, and Escape then
  leaves it.
- **The value kind, not the name, chooses the control.** The family settings and the theme stop being cases of the
  settings page: a program's new setting of the same kind gets the same control everywhere.

## Refused

- **A form written per command** in the palette or in the program: each new command would need code there.
- **A widget given by the source:** the palette would draw what a program builds, and the look would split again.
- **A unit as free text:** two settings of one nature read differently, and the palette cannot accept "4 MiB" for one
  and not the other.
- **A palette that grows when a row unfolds:** the field moves under the person's eyes.

## Subtle points

- **The row that is drawn is the one that runs.** A table rebuilt while the run mode is open (a language, a source's
  new version) keeps the unfolded item by its source and id; if it is gone, the run mode closes and puts back nothing
  (there is nothing to put back to).
- **The run mode is a state of the palette** (closed, a control open, a command's form at its argument n). Escape
  steps back one level; a click outside the palette closes it as Escape does at each level.
- **A locked setting** (a policy, the command line) shows its value and no control: its row says why.

## The day-one tests

1. With the settings page open beside the palette, a theme changed in the palette's run mode shows on the page in the
   same frame; Escape puts the page back too.
   (`a_theme_changed_in_the_palette_shows_on_the_page_in_the_same_frame` in `tests/prefs_page`: it counts the frames
   whose palette and page showed two values; a write made in the palette's own build fails it.)
2. Enter on an unfolded row while its source's table is made again (a new language) acts on the same setting, never
   on the row that took its place. (`the_row_that_runs_is_its_item`: another order of the pages; its item gone, the
   run mode closes.)
3. A program's new `Font_Family` setting, with no other code, gets the family list in the palette and on the page.
   (Layer 1: on the page, `a_new_font_family_setting_gets_the_family_picker` in `tests/prefs_page`. In the palette the
   family list is the control the table gives a `Font_Family`: no name of a setting in the run mode.)

The other tests of the layers: `escape_leaves_a_value_written_by_another_path`, `a_typed_value_is_kept_or_refused`,
`a_locked_setting_shows_its_value_and_why`, `a_command_s_form_gives_its_values` (Escape at each level),
`shift_enter_goes_to_a_setting` in `tests/prefs_page`; `shift_enter_goes_to_a_command_s_button` in `tests/commands`.

## Layers

1. Value kinds and units in `config`; the one control table, used by the settings page (its name cases removed). Done.
2. The run mode in the palette for settings, with live change and Escape. Done.
3. Act names and go to. Done.
4. Commands with arguments and their form. Done. The programs' part is in the roadmap.
