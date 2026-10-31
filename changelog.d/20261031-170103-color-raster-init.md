type: Fixed

**`font`**: when Direct2D could not make its device for color glyphs, the locks held at that moment were zeroed under their owner: the failure now only gives back the Direct2D objects.
