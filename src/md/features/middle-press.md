# The middle press: a box or autoscroll

A middle press in a scroll area starts autoscroll (`src/ui/autoscroll_region.odin`, [docs/autoscroll.md](../../../docs/autoscroll.md)).
A box that takes the middle button keeps it, as in a browser: a link opens in a new tab, a tab closes.

The box says it with `.Middle_Click`. A middle press on such a box, or on a box inside it, starts no autoscroll; the
box gets the press and `signal(b).middle_clicked` at the release. A middle press elsewhere (on text, on the
background, on a clickable box without the flag) starts autoscroll and is swallowed.

The flag is the box's, not the hit-test's: a button without it does not lose the middle press to its `.Clickable`.
Most clickable boxes do nothing with the middle button, and autoscroll over them is what the person expects.

A disabled box with the flag does not keep the press: it does nothing with it.

## A part of a box: `Box.middle_at`

A rich paragraph is one box; its links are runs inside it, wrapped across lines. The flag is wrong for it: the press on
its plain text must start autoscroll, the press on a link must not. The box says which points take the middle button
with `Box.middle_at(b, p) -> bool` (reset each build). The region asks it at the press, with the point in window
coordinates. `rich_paragraph` sets it when it has links. The press is read in `process_events`, after `begin_build` freed
the last build's memory: the runs and `Box.custom_user` are gone. So the paragraph keeps, per box, its layout's key
in the layout cache and where its text starts (`State.rich_hits`, dropped with its box). The hook finds the layout
again by that key and the fragment under the point; the layout's list of links says whether its run is a link. A
layout gone from the cache (`set_family` clears it) knows no link: the press starts autoscroll. The release on
the link reports `Rich_Result.link_middle_clicked` and `link`: the paragraph is `.Clickable`, so `signal` already
gives its `middle_clicked`, and the paragraph reads which link is under the pointer, as it does for a left click.

Why a hook asked at the press:

- The hit test runs only at a middle press. Per build, a paragraph with links writes one map entry: no rect per link.
- The answer comes from the geometry that is already kept (the layout cache and the box's rect). No second copy of the
  links' rects can go stale.
- Any box with parts can say it: a terminal's or an editor's links take the same hook, and the region does not change.

The subtle point: a hook runs before the build, so it reads nothing of the last build's arena (`Box.text`,
`Box.custom_user`, a frame allocation). It reads the box's rect and what its widget keeps across builds.

Refused:

- The flag on the whole paragraph: its plain text loses autoscroll.
- A list of rects that the paragraph gives to the region during its build: work and memory for every link at every
  build, for an event that is rare, and the rects are the last layout's anyway (the layout of this build is not done).
- A pointer to the layout kept on the box: `set_family` frees every layout between two builds. The key fails safe.
- A test `b.custom == rich_draw` in the region: it ties the region to one widget; each new widget with links adds a case.
- A box per link: a link wraps over lines inside the paragraph's single layout; boxes per fragment break its layout,
  its selection and its find.

Refused: a program that turns autoscroll off to keep its links' middle click. Its scroll areas lose autoscroll everywhere.
