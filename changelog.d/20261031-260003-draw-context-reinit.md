type: Fixed

**`draw.destroy` leaves the context empty**: `draw.init` on the same struct appended to the lists it had freed, and frames drew garbage.
