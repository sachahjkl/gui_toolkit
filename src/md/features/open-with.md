# "Open with": intent

A file's menu lists the applications that open it, each with its icon, the default first. The one chosen opens the
file. `ui.Open_With` is that submenu for every program and for the file picker's rows.

## Purpose

papier, classeur and feuille each read `desktop.handlers_for_file` on a worker, kept the answer by path, and built the
submenu. None showed the applications' icons. The file picker offered only "Open with its program".

## Decisions

- **Ask when the menu opens, read on a chore** (`open_with_ask`). The system's list is files (Linux) or COM calls
  (Windows): 10 ms and more. The icons are read in the same chore, once per ask, never per frame.
- **A handler carries where its icon is** (`desktop.Handler.icon`): Linux, the desktop entry's `Icon` key; Windows,
  the shell's "file,index" (`IAssocHandler.GetIconLocation`). `desktop.handler_icon` reads the pixels. The list stays
  cheap for a program that shows no icons.
- **The items build inside the program's `menu_submenu`** (`open_with_items`). The program keeps its own words and
  place for the submenu; the toolkit gives the rows: "Reading…" while they are read, "No application" when there is
  none, "Name (default)" first.
- **Choosing and running are two steps** (`open_with_chosen`, `open_with_run`). papier writes its entry to a file
  before it opens it, on its own worker: it takes the handler and runs `desktop.open_with` itself. The others call
  `open_with_run`, which opens on a chore and says a failure in a toast.
- **The system's calls are hooks of the struct** (`handlers_of`, `icon_of`, `open`; nil: the desktop's). A test gives
  a fixed list and records what opened, with no global and no system.
- **A serial and a counted link drop late answers.** A new ask drops the last one's answer; an answer after
  `open_with_destroy` finds no Open_With. The link is counted atomically: a job's `lost` can run on a chore.
- **The pictures are Menu_Icon's**, as `Shell_Menu`'s: a texture at the first draw of the row, on the renderer that
  draws it, released with the list.

## In the file picker

The row menu of one local file shows "Open with" beside "Open with its program". It is tied to `.Open`: a program that
removes Open removes both. Several files: none (one application per file is no menu).

## Refused

- **The shell's own "Open with" item** (`Shell_Menu`). Windows' shell menu has one, Linux's has none: the toolkit's
  list is the same on both.
- **A cache of the lists by type.** The associations change while a program runs; one read per menu opened is cheap off
  the interface's thread.
