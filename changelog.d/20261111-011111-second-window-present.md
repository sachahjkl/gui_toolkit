type: Fixed

**A second window never waits for the screen** (`render.set_present_wait`, set by `host` for every window but the first): on Wayland a Fifo present waited for a frame callback the compositor never sent to a window it did not show, and froze every window of the thread. Its frames now go out in a mailbox (else with tearing).
