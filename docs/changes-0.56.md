# What changed in gui_toolkit 0.56

**0.56.2: a lazy column keeps its height.** An item that showed nothing counted as not measured yet: a space of the mean height
when skipped, nothing when built. With several of them near the end of a scroll box that follows its bottom, the content's
height changed at every frame and the scroll bar jumped without end (found on opencode native: events of a conversation
that draw nothing). No code to change. Wren: an item may now be empty at no cost.

**0.56.1: screenshots are fast on a real window.** Tried on opencode native (2310x1505), a screenshot took about two seconds
and held the window. A wake asked for from `devtools.service` was consumed by the frame already starting, reading a
translucent window's fp16 target ran `pow` per channel, and the PNG was encoded on the UI thread. All three are fixed; a
screenshot's PNG is larger than before (`flate.deflate_runs`), and a timeline compresses its pictures when it ends. No code
to change.

For an application on the toolkit (Wren first). 0.55's report is docs/changes-0.55.md. **Nothing breaks and nothing is
required**: the `ui` API does not change, and an application that already calls `devtools.start_from_env` and
`devtools.service` has all of this with no change of code. It only needs the toolkit at 0.56 and Node 22+ on the machine
that runs the tools.

## Timelines: a run kept whole

A timeline is what happened in a window: each action with when it happened, a picture of the window after it, the time
of every frame in between. Details in docs/devtools.md, "Timelines".

```
TOOLKIT_DEVTOOLS=9222 my_app
node tools/cdp.mjs record --timeline run1                       # what a person does, until Enter
node tools/cdp.mjs play run1/timeline.json --timeline run2      # again; exit code 1 if a picture differs
node tools/cdp.mjs play run1/timeline.json --timeline run2 --realtime     # with the recorded pauses
node tools/cdp.mjs play steps.txt --timeline run3 --against run1          # a script against a run
```

Each run is a folder:

- `index.html`: one file with the pictures in it, to attach to a bug report. The steps, a strip of the frames' times, the
  picture of each step (arrow keys, Play), what differs from the reference.
- `timeline.json`: the steps and frames, what `play` reads.
- `trace.json`: Chrome's trace format, a slice per build and layout, a mark per step, a counter of the frame time.
- `steps.txt`, `step-NNN.png`, `step-NNN.diff.png`.

A step differs when over 0.4 % of its pixels differ by more than 32 of 255 (`--max-diff` for the share), so numbers shown
live pass. The `start` step is compared too: a run played from another screen is reported as different, so start it from
the same one.

From a script: `recordTimeline(send, {dir, stop, injected})` and `playTimeline(send, {source, dir, against, realtime,
maxDiff})` in `tools/timeline.mjs`, `act`, `words` and `opts` in `tools/cdp_client.mjs`; tests/e2e/run.mjs uses them.

**For Wren: a timeline holds what was on screen and what was typed, as they were.** That means the web pages shown and
any password typed into them. Record on a test profile, not on real browsing, and do not share a run made on real data.

## The screencast

`Page.startScreencast` sends the window's frames as `Page.screencastFrame` events, and `node tools/cdp.mjs cast <dir>`
writes them as PNGs until Enter. One frame at a time (the next waits for `Page.screencastFrameAck`), no faster than
`minIntervalMs` (200), none while nothing changes. PNG only: `format`, `quality` and `maxWidth` are ignored. Each frame is
read back and compared on the UI thread and encoded on a thread of its own, which takes a core while it runs: be wary of
frame times read from a run being filmed. A timeline takes one picture per action for that reason.

## New commands

| Method | What |
|---|---|
| `Toolkit.frames` `{after?}` | the last frames one by one, after build `after`: `build`, `t`, `frameMs`, `buildMs`, `layoutMs`, `totalMs`; `now` on the same clock as `t`. |
| `Toolkit.pollRecording` | the recorder's lines since the last call, with when they happened. |
| `Page.startScreencast`, `Page.screencastFrameAck`, `Page.stopScreencast` | see above. |

## Moved

`tests/e2e/png.mjs` is now `tools/png.mjs`.

## Checked, and not

- tests/e2e runs in the CI: recording, playing back, `--realtime`, a difference found, the screencast, on
  `examples/whatsnew --headless`.
- `index.html` was opened in Edge once by hand (its controls, 390 px wide, no error). The CI only checks that the pictures
  are in the file.
- Recording was tested with events sent over the protocol, not a real mouse. The code path is the same.
- A timeline was played and played again on opencode native (13 steps, the settings, scrolling, find: none differed).
- `trace.json` was checked for its structure, and not yet opened in Perfetto or `chrome://tracing`.

## Limits

- A timeline's frames come from a ring of 240: a step that takes longer than the ring holds loses the oldest.
- Something that keeps moving (an animated web page in Wren) makes each step wait its 1.5 s, the page says "still moving
  when taken", and its pictures differ on a replay. This was not tried on Wren: the runs so far are on
  `examples/whatsnew`.
