# The frame latency object: one count per present

Direct3D 11's swap chain is made with a frame latency waitable object (`LOW_LATENCY`, `swapchain_latency`). The pacer
waits on it before a frame reads its input: the frame then starts when the swap chain can take it. This file records how
the renderer keeps that object's count exact, and why.

## What the object is

The object is a semaphore that DXGI owns. Its rules, as the toolkit relies on them:

- A new object holds MaximumFrameLatency counts.
- Each frame that leaves the swap chain's queue releases one count.
- A raise of MaximumFrameLatency releases the difference. A lowering takes nothing back.
- A wait that returns signaled takes one count. A wait that times out or is alerted takes nothing.
- ResizeBuffers does not give the object a new count (a resize spam showed the surplus kept across later resizes).

A program that waits once for each present keeps the count at MaximumFrameLatency minus the frames in flight. Each count
beyond that lets one more frame queue, and the surplus never leaves by itself: every wait returns at once and the chain
stays that many frames deep until the window closes.

## The rule: the renderer counts the surplus, and takes it back without waiting

`Present_State` holds two facts about the object:

- `slot_taken`: a wait took a count, and no present has used it. A frame that presents nothing (a region of nothing)
  keeps it, so the next wait does not take a second count.
- `latency_debt`: the counts the object holds beyond what the frames in flight justify. Two events add to it:
  - a present with no count taken (`latency_presented`): the frame retires and releases a count that no wait took;
  - a lowering of MaximumFrameLatency (`latency_lowered`): the system keeps the counts of the higher latency.

Before each wait, `latency_drain` takes the debt from the object with zero-timeout waits, as far as the object has
counts to give. A count not released yet stays owed and is taken at a later wait. Every wait on the object goes through
the renderer (`wait_for_frame`, `wait_frame_slot`), so the renderer sees every count taken.

Consequences:

- **The first present of a chain is the "count taken for good".** The pacer does not wait before the first present (a
  chain never shown releases nothing to wait for). That present adds one to the debt, and the drain takes the count.
  Measured in opencode native before this rule (RENDER_PROBE, a fast hand over a list, six runs each): 48 ms from input
  to screen with that count left in the object, 30 ms without it. A chain made again whose first frame waits (the pacer
  has presented before) owes nothing: the old fixed debt of one made that wait time out (100 ms) once.
- **A frame shown at once keeps its at-once present.** A resize step of the system's size loop
  (`cadence_inner_frame`) and an input answer do not wait: a wait there stalls the size loop of the system, or a
  program that resizes the window from outside, for a refresh at each step. Their presents add to the debt instead.
- **A wait that times out adds nothing by itself.** Its present then has no count and adds one to the debt.

## The bug that this rule fixes

The debt counted only the lowering surplus. Each frame of a resize spam in the size loop set the latency to 2, presented
without a wait, then set it to 1 again. The lowering was paid back; the present without a wait was not. After the spam
the object held one surplus count for each such frame. Every later wait returned at once, and the chain queued frames as
deep as the system allows: the window showed each later resize about half a second late, for the rest of the session.
The pacer's choice not to answer input at once (`pacer.odin`: "Input after a rest is not shown at once") was measured
against the same leak: one input answer left the chain one frame deeper for good.

## Refused

- **A wait before every present.** A frame shown at once must not wait for a refresh (see above). A zero-timeout wait
  does not help: when the queue is full it takes nothing, and the count is owed all the same.
- **A program that waits on the object's handle itself** (the old `render.frame_waitable`). The renderer cannot see
  that wait, so a present after it would count as a present with no count taken. A debt one too high takes the count of
  the next frame's wait, that wait times out, and its present adds one more: a stall of 100 ms at every frame. A count
  missed the other way only leaks one frame of depth. `wait_frame_slot` takes the window's input while it waits, as
  `platform.wait_handle` did, and records the count.
- **A reset of the count when the queue is empty**, read from the frame statistics. The object's count cannot be read
  without taking it, and a handle from DXGI cannot be released back.

## The WebGPU backend

wgpu-native exposes no latency object. The backend's own is a waitable timer that the backend arms after each
present (`wgpu_present.odin`). A timer is signaled or not; it holds no count, and no surplus can build up. It uses
`slot_taken` with the same meaning, and never has a debt.
