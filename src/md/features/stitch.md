# Stitching a scrolling capture

`image.Stitcher` makes one tall picture of a page that scrolls, from screens of it taken one after the other. cliche's
scrolling capture is its first user (cliche `docs/sharex.md`, "Decisions"): scroll the window, capture it, add the
frame, until a frame adds nothing. The stitcher is pure: no capture, no scroll, no clock. It is in `gt:image` because
any program that captures a view that scrolls needs the same join.

## Decisions

- **Incremental, not a list of frames.** The caller decides after each frame whether to scroll again: the frame that
  adds nothing is the end of the page. `stitch_add` answers that at once (`.Same`), so the capture loop needs no
  second comparison of its own. The one call over a list (`stitch`) is the same stitcher in a loop, for a caller that
  has its frames already and for the tests. A separate `stitch_overlap(prev, next)` was refused: the caller would
  keep the frames, the header and the footer itself, and join them again.
- **Exact rows by hash.** A screen's pixels are exact: a row of the page that scrolls up is the same bytes in the next
  frame. Each row is hashed once (XXH3 64 over its RGBA bytes), so a comparison of two rows is one compare of two
  words. The overlap found is checked byte for byte once: a collision of hashes never joins wrong rows.
- **The overlap is the largest run aligned at the end.** For frame k, the candidate overlaps are the `L` last rows of
  frame k-1's middle against the `L` first rows of frame k's middle. The largest `L` that matches wins: the smallest
  move. On a page whose rows repeat, two alignments can match; the largest overlap is the one a wheel step gives most
  often (a step moves less than a screen), and it never duplicates rows that both frames show. Cost: rows times
  candidates, a few million compares for a 1000-row frame, on a worker.
- **The least overlap.** Below `min_overlap` rows (16 by default) a match is taken as chance (a blank line, a rule)
  and the frames as not overlapping. The frame is then refused (`.No_Overlap`) and the stitcher is unchanged: a picture
  with a hole or a row twice is worse than a shorter one. The caller scrolls less and adds again, or ends. Appending
  the frame anyway was refused for that reason.
- **Header and footer: rows that do not move.** A sticky header and a status bar are the same rows at the same place in
  two frames that scrolled. The first pair of frames that differs fixes them: the rows equal at the top (the header),
  the rows equal at the bottom (the footer). They are kept for every later frame: the header from the first frame at
  the top, the footer from the last frame added at the bottom, and only the middle is matched and appended. A
  header found again for each pair was refused: the picture's top is written at the first pair, and a header that grew
  later could not be taken back.
- **A bound on the height.** `max_height` (32768 rows by default) stops a page that never ends (an infinite feed) from
  taking the memory: at 1920 columns the bound is 240 MiB. The rows past it are cut, the footer still fits below,
  and the stitcher answers `.Full`.
- **Frames of one size.** Every frame has the first frame's width and height; another size is refused (`.Refused`).
  A window resized during a capture is a new capture.
- **Pure, on a worker.** Hashing and the search are passes over the pixels. A caller adds frames on a worker; the
  interface's thread only receives the answers.

## Refused

- **Feature matching or phase correlation.** They find the move of a camera's picture, with noise and scale. A screen
  has neither: its rows are exact, so equal hashes find the move exactly and faster, and a page of repeated rows is a
  question of a rule (the largest overlap), not of a peak in a correlation.
- **A fixed step.** The rows a wheel notch moves depend on the system, the program, its zoom and its smooth scrolling;
  the last step stops at the page's end. The overlap is measured for every frame.
- **A tolerance for near-equal rows.** Exact hashes are enough for a screen. A tolerance makes each compare a pass
  over the row and widens the false matches of a page with repeated rows. If an animated region (a caret, a spinner)
  in the middle breaks the matches, the way open is a count of rows allowed to differ inside an overlap, still by
  hash.

## Subtle points

- A header found too tall (the first rows of the middle equal by chance in the first pair, as a blank margin) loses no
  row: the rows it hides at the top of a later frame are the bottom of the frame before, already appended.
- A footer found too tall hides new rows at the bottom of a frame; the next frame shows them higher, in its middle, and
  the last frame's footer ends the picture. So the picture stays whole.
- The middle of the last frame before a `.Same` frame ends the picture; the `.Same` frame's footer is the same rows.
