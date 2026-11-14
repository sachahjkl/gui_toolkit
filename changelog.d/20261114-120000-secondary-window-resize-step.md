type: Fixed

**`host`: a second window's resize step is drawn at once on Wayland**: the paced window's frame draws the resize steps of the other windows first (`host_steps`, the `host_paint` path), and `platform.wait_slot` ends when such a step waits. Before, a window that is not paced waited for the paced window's slot and its work, and the compositor showed its last picture stretched to the new size.
