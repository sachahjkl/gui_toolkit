# A logo's files, drawn large and shrunk

A program's logo is a drawing at any size (`toolbox.Logo.draw`); `toolbox.write_logo` writes its PNG files, its `.ico`
and the project's picture.

## Drawn large, then shrunk in steps

- **A size is drawn large, then shrunk.** A drawing rasterised directly at 16 px has edges the coverage blurs unevenly;
  drawn at the master's size or more and shrunk, its edges are the filter's, the same at every size. Six programs wrote
  the same loop for it (papier, inspecteur, classeur, cliche, atelier, Wren): the loop is now `write_logo`'s, and a
  program gives only its drawing.
- **The size drawn** is the size times `LOGO_SHRINK_STEP` (4) as many times as needed to reach `Logo.draw_size` (0: the
  master's size). A size above it is drawn at its size. With neither, every size is drawn at its size: the toolbox then
  shrinks nothing.
- **One step shrinks by 4 at most.** The cubic filter of `paint.resize` keeps a clean edge down to a quarter; one step
  from 1024 to 16 drops most pixels and aliases.
- **The drawing knows the size it is for** (`draw(pixels, size, user)`): it draws `pixels` wide what must read at `size`.
  A small size thickens its lines and drops its details (each program's `detail_for`); the drawing cannot learn it from
  the width it draws at, which is the master's.
- **`logo_shrink(big, size)`** is the loop alone, public: Wren composes its layers at the final size (a grid between its
  body and its bird), so it shrinks each layer before it draws the next over it.
