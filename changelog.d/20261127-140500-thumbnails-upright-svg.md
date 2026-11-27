type: Fixed

**Photo thumbnails stand upright, and SVG files get one.** The file picker's and classeur's thumbnails
(`ui.file_thumbnail_make`) showed a phone's photo sideways; they now follow its EXIF orientation, and the picture cache
(`gt:pictures`) does too. An SVG drawing is drawn as its thumbnail. A JPEG thumbnail is decoded at a reduced size when
the program has the fast decoder.
