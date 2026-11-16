type: Fixed

**`session.advance` on a view's window**: it looped for ever, because that window's clock never moved. It now advances the application's clock.
