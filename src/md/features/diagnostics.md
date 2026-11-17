# The Diagnostics page's source

The settings' Diagnostics page (`prefs_page/diagnostics.odin`) says the adapter, the window and the last frames' times.
It read them from a `host.Host`. Wren has a loop of its own: its windows are no `host.Host`, and its renderer is a field
of its App, not of a `host.Shared`. The page now reads a `Diagnostics_Source`: four plain fields, read at each build.

## Decisions

- **Plain data, read at each build.** The renderer (the adapter and its API), the window (its size and scale), a
  `host.Frame_Ring` (the frames' times) and whether partial redraw is on. A program gives them in its `Page_Options`,
  which it makes at each build already. The page keeps nothing of them past the build.
- **A frame ring, not a hook per sample.** The ring is the host's own record (`host.FRAME_RING` slots, a few stores a
  frame, no allocation) and `host.frame_stats` reads it. A program with a loop of its own keeps one ring per window and
  calls `host.frame_add` after each picture: the same numbers, the same statistics, no second format.
- **`diagnostics_of(&h)`** gives a host's window its source: the programs on the host write one call.
- **No renderer, no page.** The source replaces the pointer whose nil hid the page; a zero source hides it the same way.
- **`diagnostics_rows`** is public: the rows a source gives, in the temporary allocator. The page keeps a copy, and a
  test reads them without a window.

## Refused

- **A `host.Host` that the program fills by hand.** `Shared` holds the renderer by value: a program with its own renderer
  would copy it, and the copy goes stale at the next device loss. The host's other fields (the pacer, the hooks) mean
  nothing outside its loop.
- **A procedure per line** (the program says each value): every program would write the same lines, and the page's words
  would leave the toolkit.
