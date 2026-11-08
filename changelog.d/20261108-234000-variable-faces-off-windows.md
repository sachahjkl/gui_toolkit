type: Fixed

**Variable faces off Windows**: `font.axes` reads a face's axes from its `fvar` table, and `font.with_variations` makes an instance the native backend opens at its location (a simulation of it keeps it). Both did nothing there, so a variable font was drawn at its default instance: a web font in `font-weight: 400` whose default is 300 came out light.
