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

`config.Def` gains its **value kind**: what the value is, not how it is kept. One closed table of the toolkit:

| Value kind | Stored as | What it is |
|---|---|---|
| `Plain` | any | a value with no nature of its own: its storage decides |
| `Font_Family` | String | a family of the system's fonts |
| `Theme` | String | a theme of the program's list |
| `Color` | String | a colour (`#rrggbbaa`) |
| `Path` | String | a file or a folder |
| `Address` | String | a URL |
| `Keys` | String | a chord or a sequence of chords |
| `Size` | Int | a count of bytes |
| `Duration` | Int / Float | a time, in the unit the setting states |
| `Fraction` | Float | a share, 0 to 1, shown in percent |
| `Length` | Int / Float | a length on the screen, in logical pixels or ems |

A number's **unit** is data of the kind (`Duration` in milliseconds or seconds, `Length` in pixels or ems), taken from
one table of units, as Modus's integer units: a text unit can say anything, and two settings of one nature must read
alike. `unit` (free text) and `bytes` go: `bytes` is `Size`.

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
2. Enter on an unfolded row while its source's table is made again (a new language) acts on the same setting, never
   on the row that took its place.
3. A program's new `Font_Family` setting, with no other code, gets the family list in the palette and on the page.

## Layers

1. Value kinds and units in `config`; the one control table, used by the settings page (its name cases removed).
2. The run mode in the palette for settings, with live change and Escape.
3. Act names and go to.
4. Commands with arguments and their form.
