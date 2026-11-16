# A picture's owner

A `draw.Picture` keeps its recording on the CPU and its GPU ranges in the retained heaps of one renderer. Each window
has its own draw context and its own renderer. A picture a widget keeps can be replayed in another window's context: a
terminal moved to a window of its own, a view docked and undocked.

## The faults it fixes

- **A heap generation is no identity.** A picture was resident when its `heap_gen` matched the renderer's
  `heap_generation`. Two renderers both start at 0: replayed in another renderer, a picture read as resident there and
  drew the other renderer's ranges at its offsets: another picture's instances, or nothing.
- **A destroyed context.** `draw.destroy` freed the list of pictures with GPU ranges, and the pictures still said
  `resident`. A later `picture_release` or `picture_destroy` freed ranges in a renderer that no longer existed.

## Decisions

- **`Picture.owner: ^Context`.** The context whose renderer holds its ranges, set at upload; nil when it holds none.
  A replay in another context gives the ranges back to the owner, then uploads in the new one. A picture that moves
  between two windows at every frame uploads at every frame: a move is a rare event, not a mode.
- **`draw.destroy` lets go of its pictures.** It gives back every registered picture's ranges, marks it not resident and
  clears its owner. The picture keeps its recording and uploads again where it is replayed next.
- **`picture_release(pic)` and `picture_destroy(pic)` take no context.** The owner is the only context they can act on;
  a context argument would invite the wrong one. A widget that keeps pictures (the terminal's rows) frees them in its
  own `destroy`, where no context is at hand.

## Refused

- **A renderer id in the picture.** It fixes the first fault, not the second; the owner fixes both and gives the
  context to release in.
- **The widget forgets its pictures when the context changes.** Every widget that keeps pictures would carry the same
  check, and would free and record what an upload alone recovers.
