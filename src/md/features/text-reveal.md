# A cut text shows itself whole

A text wider than its box is cut, and its end is an ellipsis (`draw_box_text`). The person saw that something was
missing and had no way to read it: a long session title in a list, a path in a narrow column, a value in a table. Only
data elides (a label a person must read grows or wraps, README). The cut stays, because the layout needs it, and the
ellipsis opens the whole text.

## The decision

- The ellipsis of a cut text is a target of its own. The pointer over it is a hand and lights it in the accent colour.
  A click on it opens a **reveal**: a bubble under the ellipsis, with the whole text, selectable, and two small glyphs
  in its top right corner, Copy and close, without words. The text wraps at `REVEAL_MAX_WIDTH_EM`: a long text makes
  the bubble taller, not as wide as the window. The bubble is the text's; buttons with words made it heavy.
- The reveal stays until the person closes it: the cross, Escape, or a press outside it. A tooltip goes when the
  pointer moves; the text must be read, selected and copied at leisure.
- Every cut single-line text has it, in every program, with no flag. A program does nothing to get it.
- The ellipsis wins over the box under it: a click on a row's cut title opens the reveal, a click elsewhere on the row
  acts as before. The target is the ellipsis only, a few pixels, so the row keeps almost all its surface.
- Ctrl+C in the reveal copies the selection, or the whole text when nothing is selected.

## How

- The draw pass knows where it cut: `draw_box_text` keeps the ellipsis's rect on the box (`Box.ellipsis`, window
  pixels, as tall as the box), and clears it when the text fits. A build does not clear it: several builds can come
  before one draw, and the hit test between them would lose the target. A box out of its clip is not drawn and keeps
  an old rect, but the hit test never reaches a point outside the clip.
- The hit test returns a synthetic key for a point on an ellipsis, as for a scroll bar (`reveal_key`, its owner in
  `State.reveal_owner`). The press and the release then go to that key like to a box: no box under it is pressed or
  clicked, so the row does not act.
- `text_reveal_build` (end_build, before the toasts) takes a click on such a key, keeps a copy of the owner's text and
  where its ellipsis was, and builds the bubble. While it is open it owns the keys (`Key_Owner.Text_Reveal`), as a menu
  does: Escape closes it and the program does not see that Escape.

## Refused

- A tooltip on hover alone: it goes when the pointer moves to it, nothing in it can be selected or copied.
- Making the whole cut box the target: a cut title of a clickable row would no longer open its row.
- A flag to ask for it: every program would forget it at the very place a text is cut.
- Cutting a dialog's title and revealing it: a label a person must read is never cut (README). The title shrinks before
  the header's tools and its close cross, and wraps, a long word (a path) between its characters.

## Subtle points

- Only `draw_box_text`'s single-line cut has a reveal. A rich paragraph cut at its last line (`rich_text`) has none yet.
- The rect is the last frame's, as every hit test: a text that changes width between two frames has the old target for
  one frame.
