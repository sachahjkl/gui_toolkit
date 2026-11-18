type: Fixed

**`session.save_png` without a renderer**: in a session started with `no_renderer`, it ends the test with "this session
has no renderer", as `capture` does, instead of crashing it.
