type: Added

**Pictures read from files, combined, cut and trimmed (gt:image)**:
  - `image.decode` gives the RGBA8 picture of a PNG, JPEG (baseline or progressive), WebP or BMP file. `image.file_format` reads the format from the file's first bytes, not from its name.
  - `image.combine` puts several pictures in one, side by side or stacked, with a gap and a background; each is centred across.
  - `image.cut_out` removes a band of columns or rows and joins the two sides.
  - `image.trim_bounds` gives the part of a picture left once its edges of one colour are trimmed (with a tolerance).
  - `image.edge_mean` gives the mean colour on the edge of a rectangle: what is around it, to fill it with.
