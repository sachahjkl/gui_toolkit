# Side panels that fold

A side panel stands beside a content and folds to a rail: a narrow column of icons or marks. The views' side zones
(`views.md`, Minimise), the settings' sidebar (`prefs_page`) and any split of a program (papier's list beside its
preview, Wren's devtools) use one mechanism, in `src/ui/side_panel.odin`:

- `Side_Fold`: the state machine below, two bits. A program keeps it and saves it (`side_fold_format`, `side_fold_parse`).
- `side_fold_follow`: it reads the room once per build and applies the rule.
- `side_fold_set`: the manual act (a fold button, a key, a pull, a strip's Minimise).
- `side_handle`: the handle between the panel and the content. Open, it resizes the panel. Folded, it is the rail's
  edge line, and a pull opens the panel. A push of an open panel down to its rail folds it.
- `side_fold_button`: the fold button (`PANEL_LEFT_CLOSE` / `PANEL_LEFT_OPEN`, `RIGHT` for a panel at the right).
  The program places it in a row it already has, at the same pixel in both states.
- `Side_Panel`, `side_panel_begin`, `side_panel_handle`: the three above for a program's own split, with the width it
  keeps.

## The rule

A side panel folds when, open at its width, it leaves the content less than the content's least width:

    room - panel width < content_min        → narrow
    room - panel width >= content_min + gap → wide again

- `room` is the width of the whole split (the panel, its handle and the content), from the last layout. The fold does not
  change it, so a fold can never cause the next measure to cross back.
- `panel width` is the open width, never the rail's. The rule asks whether the panel *can* be open.
- `content_min` is the caller's: `DOCK_MIN_EM` for the views' content, `prefs_page.BODY_MIN_EM` for the settings' pages.
- `gap` is `SIDE_FOLD_GAP_EM` (1 em): the hysteresis. Inside the band of one em, the state that was there stays. A sweep of
  the width around the threshold changes the state once each way, never once per pixel. This is the same reason as the
  34/35 em of What's new (`whats-new.md`) and the scroll bar that appears.
- No fixed breakpoint of the window: the rule is the same in a window, in a dialog (the settings as a dialog) and in a
  dock space of a program's own.

## The state machine

The state is two bits: `narrow`, the side of the threshold that was seen last, and `folded`, what shows. The automatic
state is `folded == narrow`. A manual choice is `folded != narrow`. It is not a third field: it follows from the two.

| State                  | `narrow` | `folded` | Shows  |
|------------------------|----------|----------|--------|
| Wide, open (auto)      | false    | false    | open   |
| Wide, folded (manual)  | false    | true     | rail   |
| Narrow, folded (auto)  | true     | true     | rail   |
| Narrow, open (manual)  | true     | false    | open   |

Events:

- **Start.** The two bits are read from the memory (zero: wide and open). The first `side_fold_follow` is a measure as any
  other. If the room is on the remembered side, nothing changes, and a manual choice holds. If the room is on the other
  side, it is a crossing.
- **The width crosses the threshold** (`side_fold_follow`, either way): `narrow` takes the new side and `folded = narrow`.
  The automatic state takes over, and a manual choice made before is gone.
- **Manual fold, manual unfold** (`side_fold_set`): `folded` takes the value asked and `narrow` stays. The choice holds
  until the next crossing. A manual act that asks the automatic state (a fold while narrow) is the automatic state again.
- **The room is unknown** (0, the first frame): no measure, no change.

What is remembered across restarts: both bits. A restart in a window of the same size keeps the manual choice. A restart
on the other side of the threshold shows the automatic state: the choice was made for another width. A crossing writes
the memory, so a choice that a crossing overrode does not come back at the next start.

**Why it changed (0.313).** Before, a manual Minimise was remembered forever, and a narrow fold (`sp.folded`) was a
second state outside the memory, with a third bit (`sp.unfolded`) for a Restore while narrow. These were three states
that told different stories: a panel minimised in a narrow window stayed minimised in a wide one, and a Restore while
narrow was lost at the next start. The user's rule: a manual choice holds only until the next crossing. Refused:
- a window breakpoint (the settings' old `NARROW_EM`, 40 em): wrong in a dialog;
- a timer that ends a manual choice;
- a manual choice remembered per width: a person cannot see or predict it.

## The handle and the pull

`side_handle` is a `splitter` with the press kept (`press_data`). It maps the pointer to a raw width from the width
shown at the press. The threshold is the larger of the rail's width plus `SIDE_PULL_EM` (1 em) and the open panel's
least. Under it, the panel is folded. Past it, the panel is open at the raw width, held to its limits. One drag, one
threshold: a pull outward from the rail opens the panel at the pointer, with no jump, because the threshold is never
under the open panel's least (the views' rails, 2 and 3.5 em, open at 3 and 4.5 em; the settings' rail opens at the
sidebar's least). A pull back folds it again, and its open width becomes the width it had at the press. Each change of state is a manual act
(`side_fold_set`). The keys on the handle resize an open panel and never fold it. Folded, the handle stays: it draws
the rail's edge line, the same line as when the panel is open.

## The settings' sidebar

The settings' sidebar (`prefs_page.build`) is a `Side_Panel` at the left. Its width is `prefs_page.sidebar_width`. Its
fold state is `prefs_page.sidebar_fold`, a hidden String preference (`side_fold_format`: `"folded narrow"`, `""`). Its
content minimum is `BODY_MIN_EM` (26 em: what the old 40 em breakpoint left beside the 14 em sidebar).

- **Open**: the fold button at the start of the search row, then the search well, the pages, the version, the file,
  Export and Import, as before.
- **The rail** (`RAIL_EM`, 3.5 em, as opencode native's): the fold button at the top, at the same pixel as when open
  (its centre on the rail's centre, the same row height). Under it:
  - a magnifier;
  - the pages' icons, each with its title as the tooltip, the page shown lit (`selected`, the row face's look). With
    the focus on one, Up and Down show the previous and the next page, and the focus follows;
  - at the foot, a "…" button whose menu holds the version (as its heading), the settings file (it opens it), Export and
    Import.
  A pull of the rail's edge opens the sidebar.
- **The magnifier** opens the sidebar with the search field focused (a manual unfold: it holds until the next crossing).
  The results show in the body, as for any search. Refused: a popup field over the rail. It is a second field with a
  second focus, and it covers the first page lines that the results replace.
- Each page has an icon. A page without one shows the first letter of its title in the rail.

Refused: the old icons-only column under 40 em (no search, no foot, no fold button). It was a third state of the
sidebar, beside open and nothing, and it came from a breakpoint of the window.

## For a program's own split

A program keeps a `Side_Panel` (its width and its fold) and saves it when `side_panel_handle` says `finished` or
`fold_changed`, and when `side_panel_begin` says `crossed`. It builds, in order:

    w, folded, _ := ui.side_panel_begin(&app.side, room, o)   // room: the split's width at the last layout
    ui.next({width = ui.px(w), height = ui.fill()}); ...the panel, or its rail when folded...
    ui.side_panel_handle("###split", &app.side, room, o)
    ui.next({width = ui.fill(), height = ui.fill()}); ...the content (.Fits_Width)...

For a panel at the right (`o.after`), the content comes first, then the handle, then the panel. The rail is the
program's (what a folded list says is the program's own). The toolkit gives its width and the fold button.
