type: Fixed

**`arena.Pool`**: a slot whose generations are spent is retired instead of wrapping, so a handle never comes back to life, even after 2^32 reuses.
