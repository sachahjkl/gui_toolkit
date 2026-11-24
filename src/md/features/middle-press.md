# The middle press: a box or autoscroll

A middle press in a scroll area starts autoscroll (`src/ui/autoscroll_region.odin`, [docs/autoscroll.md](../../../docs/autoscroll.md)).
A box that takes the middle button keeps it, as in a browser: a link opens in a new tab, a tab closes.

The box says it with `.Middle_Click`. A middle press on such a box, or on a box inside it, starts no autoscroll; the
box gets the press and `signal(b).middle_clicked` at the release. A middle press elsewhere (on text, on the
background, on a clickable box without the flag) starts autoscroll and is swallowed.

The flag is the box's, not the hit-test's: a button without it does not lose the middle press to its `.Clickable`.
Most clickable boxes do nothing with the middle button, and autoscroll over them is what the person expects.

A disabled box with the flag does not keep the press: it does nothing with it.

Refused: a program that turns autoscroll off to keep its links' middle click. Its scroll areas lose autoscroll everywhere.
