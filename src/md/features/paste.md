# Paste

A paste gives a widget what the clipboard holds: text, files or an image, as one answer. The widget says which kinds it
takes; the toolkit asks the clipboard, decides which kind wins once the clipboard has answered, and decodes an image on
the chores when the widget asks for its pixels. Before this, the toolkit's paste knew only text, and opencode native
asked the files, the image and the text itself (`attachments.odin`, `Composer_Paste`).

## What a paste gives

One `ui.Paste_Answer` for the widget that asked, in a later build:

| Kind | What comes |
|---|---|
| `.Text` | the text, UTF-8 |
| `.Files` | absolute paths, and `cut` (a file manager's Cut: a paste moves them) |
| `.Image` | the image as the clipboard held it, still encoded (`data` and its `mime`); its pixels (`rgba`, `size`) when the request asked to decode |

The answer has one kind. A program never gets "the text and the image": the choice of what a paste means is the
toolkit's, once for every program.

## The order of preference

Among the kinds asked:

1. **Files.** A file manager offers the paths as text too (KDE, GNOME Files): the files are what was copied.
2. **Text.** A spreadsheet's cells come as text and as a picture of the cells, an office program's selection too: the
   text is what was copied.
3. **Image.** A screenshot, a browser's Copy image: no text with it.

This is the rule opencode native had; it moves here unchanged.

## How it is asked

The kinds are asked one after the other, in that order, and the next is asked only when the last came empty. Each step
is a `platform.clipboard_request`, which returns at once; its answer is a `Clipboard_Data` event of a later poll. When
a kind comes, the paste is decided: nothing more is asked. When none comes, the answer is `.Nothing`: galerie's Paste
with no picture on the clipboard did nothing, and the person could not tell a paste that failed from a key that was not
read. Refused: no answer (the program cannot say "nothing to paste"), a timeout in the program (it does not know how
many kinds are asked, nor how slow the owner is). A text field takes text only (`{.Text}`), so its paste of nothing
stays silent; the program takes `.Nothing` when its kinds have it (`PASTE_KINDS_ALL` does).

```
Idle ─request─▶ Asking(Files) ─empty─▶ Asking(Text) ─empty─▶ Asking(Image) ─empty─▶ Ready (.Nothing)
                     │ok                    │ok                    │ok
                     ▼                      ▼                      ├─decode─▶ Decoding ─chore done─▶ Ready
                   Ready                  Ready                    ▼
                                                                 Ready
Ready ─build─▶ taken by paste_answer, or dropped at the end of the build ─▶ Idle
any state ─request─▶ Asking (the last paste is dropped: its answers and its chore are stale)
```

- A kind that is not asked is skipped: a text field's paste is one request.
- A program's own clipboard in memory (`Build_Params.clipboard_get`, a test's) has only text: with it, only `.Text` is
  answered, at the next build; empty, `.Nothing`.

## One API

`ui.paste_request(key, kinds, decode)` and `ui.paste_answer(key, kinds)` are the text paste of before, extended. There is
no second API for rich paste.

- `paste_request(key)` asks for text, as before; `paste_request(key, {.Files, .Image, .Text})` asks for all three.
- `paste_answer(key, kinds)` takes the answer only when its kind is in `kinds`. Two parties can share one key: the
  editor takes the text (`{.Text}`), the program takes what the editor left (`{.Files, .Image}`) after the editor in
  the same build.
- `Text_Edit_Options.paste` and `edit_menu`'s `paste` say what the editor's Ctrl+V, Shift+Insert and its menu's Paste ask
  for. The default is text.

## The platforms' formats

| Kind | Windows | Wayland and X11 |
|---|---|---|
| text | `CF_UNICODETEXT` | `text/plain;charset=utf-8` (or what the offer has of `text/plain`; X11 `text/plain`) |
| files | `CF_HDROP`, `Preferred DropEffect` for the cut | `text/uri-list`, else `x-special/gnome-copied-files`; the cut from `application/x-kde-cutselection` or GNOME's first line |
| image | `PNG`, `image/png`, else `CF_DIBV5`, `CF_DIB` (`mime` `image/x-dib`) | `image/png`, else `image/jpeg`, `image/bmp`, `image/x-bmp` |

The platform layer had these reads already (`clipboard_request`, `clipboard_image_decode`); this work is the decision
and the decode in `ui`.

## Threads

- Linux: each read is the window's loop's, without a wait (a pipe on Wayland, `ConvertSelection` on X11). The requests
  of a window run one after the other.
- Windows: the system keeps what was copied; `OpenClipboard` and a copy of the bytes are done in the call, as for the
  text. The copy of a large image is a memory copy, no decode.
- The decode (PNG, JPEG, BMP, a DIB to RGBA) is a chore (`ui.task`). Its result comes at the start of a later build,
  then the widget takes it in that build. A 4K screenshot is tens of milliseconds to decode: never on the interface's
  thread.

## Refused alternatives

- **Ask the three kinds at once and decide when all came** (what opencode native did). An image read for nothing when
  the text wins: tens of megabytes through a pipe or a memory copy for a spreadsheet's cells. The steps cost a frame
  each on Windows and on the store, which a person does not see.
- **Look at `clipboard_formats` first and ask only what is there.** On X11 the list of another program's types is a
  read that waits for it. The step that comes empty is as cheap, and does not wait.
- **A second API for rich paste beside the text paste.** Two ways to paste, two keys waiting, two ways to drop a stale
  answer. One paste waits at a time, whatever it asks.
- **Always decode the image.** opencode native attaches a PNG or a JPEG as it came: decoding it to encode it again
  wastes the work and the quality. The decode is asked.
- **Give the program every kind that came.** Each program would choose again, and differently.

## Subtle points

- An image-only clipboard pasted into a text field gives nothing to the field. The program that asked for `.Image` on
  the field's key takes it after the field, in the same build.
- A text field takes its answer only while it has the focus. An image or files are the program's: they come whatever
  has the focus, in the build they are ready, and are dropped at its end when nobody takes them.
- `line_edit` has no `paste` option: a field of one line holds a name, a path or a query, never an attachment. A
  program that wants files dropped into such a field asks with the field's key itself (`paste_request`) and takes the
  files after it.
- A decode that fails still answers `.Image`: `data` and `mime` are there, `rgba` is nil. The program says the image
  could not be read.
- The answer's text, paths and bytes live until the next `paste_request`. A program clones what it keeps.
- A new request replaces the one waiting, a decode running too: its result is dropped when it comes (a serial).
