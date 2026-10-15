# Attribution

The architecture of `ui`, `draw`, `font` and `render` (box tree with keyed persistence, size kinds and the layout passes,
signals, tag-based themes, the SDF rect shader, the frame loop) is a port to Odin of the corresponding layers of the
[RAD Debugger](https://github.com/EpicGamesExt/raddebugger). No C code is copied; the design and algorithms are.

RAD Debugger is MIT licensed:

    Copyright (c) Epic Games Tools

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
    documentation files (the "Software"), to deal in the Software without restriction, including without limitation
    the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
    permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of
    the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
    THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
    TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.

`ui/icons.ttf` (compiled into the exes) is the icon font from `raddebugger/data/`.

## Embedded fallback fonts

Compiled into the exes and used only when the Windows fonts (Segoe UI, Consolas) are missing, e.g. under Wine:

- `font/data/Roboto-Regular.ttf`: Roboto, font data copyright Google 2011, Apache License 2.0
  (`font/data/Roboto-LICENSE.txt`).
- `font/data/Inconsolata-Regular.ttf`: Inconsolata, copyright (c) 2006-2012 Raph Levien, copyright (c) 2011-2012
  Cyreal, SIL Open Font License 1.1 (`font/data/Inconsolata-OFL.txt`).
