# Contrast on selected rows

Every word on a selected row reads at WCAG AA (4.5:1) against the row's face, both at rest and under the pointer — its
title, its secondary (`weak`, `faint`, `soft`) details, any colour of its own (an error's red), and the letters a search
lit in it. A program changes nothing; the toolkit computes the inks from the selection's ground and passes them down.

## The fault

Wren measured its address-bar suggestions on Ember dark (`list_row` + `selected` + `.Chosen`, detail under `tags("weak")`,
matched letters through `ui.label_fuzzy`):
- row ground `#83634E`, title `#EDEDED` (4.65:1);
- weak detail `#8F8F8F`: **1.68:1** (it kept the grey meant for the page's dark background);
- matched letters on `match_bg` (`#B68565`): **1.29:1**, and `match_bg` against the row 1.69:1 (the highlight is the
  accent at 0.18, invisible on a selection that is itself a tint of the accent).

The toolkit's palette (`palette.odin`) had the same pattern: a weak detail line inside a selected row.

A second fault surfaced when testing every theme: in Old Head (light), `find_text` was fixed to black on the find bar's
matches (`.Warn`, olive `#808000`, at 0.62 and 0.85) over its navy selection (`#000080`), dropping to 3.60:1 and 4.45:1.
Since 0.364 a find's match no longer changes its letters' colour (see below).

## Decisions

- **Inks computed on the selection's own ground** (`src/ui/selection_ink.odin`): when a `.Chosen` box is built, its face
  at rest (`ground`) and under the pointer (`hot`) are resolved over what is under it. `selection_ink(ground, hot, fg, share)`
  produces:
  - `text`: `fg` made readable at `SELECTION_INK_RATIO` (4.5:1) on both `ground` and `hot`; if the two grounds pull it
    apart, black or white (whichever reads better on both);
  - `weak`: `text` mixed toward `ground` by binary search (12 halvings, below one 8-bit sRGB step) only as far as keeps
    `max(4.5, worst(text) * share)`, where `share` is the theme's own weak-to-text contrast ratio on the page. Where a
    deep ground has room, secondary text stays visibly quieter than the title; on a mid ground like Ember's brown, it
    stays readable at 4.5:1.
- **Inherited down to a box with its own face (and public `ui.ink_for`)**: `Box.ink`, `ink_weak`, `ink_ground` and
  `ink_hot` ride down the subtree in `build_box`. `chosen_inks` always composites `b.target_bg` over `under` (without
  requiring `.Draw_Background`), so custom-drawn `.Chosen` rows with the `selected` tag pushed still resolve their inks
  against the theme's selection fill. Plain and bright text take `ink`; `weak`, `faint` and `soft` take `ink_weak`; any
  other colour (a fault's red, a badge) keeps its hue pushed to 4.5:1 against the selection's ground and hover face.
  `ui.ink_for(row, fg)` exposes the same mapping for programs that pass an explicit `next({fg = ...})` inside a selected
  row (returning `fg` unchanged when `row == nil` or not chosen).
- **Memoized per window and theme**: `State.selection_inks` caches up to 32 `(ground, hot, fg, share)` entries and resets
  when `theme.serial` changes. No work proportional to row count per frame.
- **Underline for matched letters on a selection** (`match_runs` and `label_fuzzy`): off a selection, matches keep their
  accent tint (`match_bg`), with `match` using a computed `Match_Ink` slot (`readable` against `match_bg` over the page).
  On a selection (`match_on_selection()`), the tint goes away and matched letters are underlined in the row's ink. An
  underline does not depend on colour, needs no bold font weight to be loaded, and works identically in `rich_paragraph`
  and `label_fuzzy`.
- **Find matches keep the row's inks** ([find-in-view.md](find-in-view.md), "The look of a match"): a match is a light
  fill and an edge, its letters drawn as the rest of the row. On a selected row it is the edge alone, so the row's inks
  hold inside a match too. The edge is made to reach 3:1 against what is under the box (a selection's ground or the page). Up to 0.363 an opaque tint
  carried its own ink (`find_text`, checked against the composite by `find_match_ink`); it went with the tint.
- **Off a selection, weak text on the page is held to 3:1** (WCAG AA for non-text / large text): weak text on the page
  is a hint beside a title that already reads at 4.5:1, and keeping a clear step below the main text is its point.
- **Checked on every theme** (`tests/theme_look/selection_contrast_test.odin`): walks every theme in `ui.THEMES` (dark
  and light) across all four selection styles (`list_row` selected and weak_selected, `menu_item` selected and nav),
  checking titles, weak, faint, error, `label_fuzzy`, `match_runs` and `find` matches.

## Refused

- **Hard-coding a "selected weak" token per theme**: forty-plus themes would each need hand-tuned values for four
  selection roles, and any new theme or user colour would break again. Computing from the ground guarantees AA everywhere.
- **Bold for matched letters on a selection**: a program or font may not carry a bold face for every weight/size, and
  bold shifts glyph widths when a row is selected or unselected. An underline keeps the exact layout and works with any font.
- **Opaque yellow for find matches**: it looks harsh on dark themes and removes the letters' own colours. A light fill
  and an edge (find-in-view.md) keep the text as it is on every theme.
