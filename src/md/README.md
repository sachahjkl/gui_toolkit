# gui_toolkit: intent

This folder follows <https://srcmd.org>: the reasons behind the toolkit's modules, their decisions and their subtle
points. The documentation for the programs that use the toolkit is in [docs/](../../docs/). Only Markdown is here: the
tools that list the packages of `src/` skip a folder that holds no Odin file.

## Overview

The toolkit is an immediate-mode interface (`ui`) over its own platform layer (`platform`), renderer (`render`, `draw`)
and text (`font`). Two rules shape every module:

- The interface's thread makes no system call and no work in proportion to the data in a frame. Readings go to the
  chores (`ui.task`); a result comes back at a next build.
- What is one app's state lives in its State (or its Window, its Renderer), never in a global.

## File Index

- [features/file-browser.md](features/file-browser.md): the file browser of `ui.file_dialog`: why it reads through sources, how stale answers are dropped, what a quiet build does not do
