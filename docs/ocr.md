# ocr: the text in a picture

`import ocr "gt:ocr"` (the package is named `tk_ocr`). It reads the text in a picture with the engine the system has:
Windows.Media.Ocr on Windows, Tesseract on Linux. A program starts without either: `available` then answers false, and
`recognize` answers `.No_Engine`.

Every call blocks: a program calls them on a thread of its own, never on the interface's thread.

```odin
r, err := ocr.recognize(pixels, width, height, stride, .RGBA)   // or .BGRA; Recognize_Options{languages} to choose
if err != .None { show(ocr.error_text(err)); return }            // No_Engine, No_Language...
defer ocr.result_destroy(&r)
if len(r.lines) == 0 { show("No text"); return }
clipboard_set(r.text)
```

| Procedure | |
|---|---|
| `available() -> (Engine, bool)` | the system's engine (`.Tesseract`, `.Windows`, `.None`), and whether it can read: its library is there and a language is installed |
| `languages(allocator) -> []string` | the languages installed, in the engine's codes: Tesseract's (`eng`, `fra`, `chi_sim`), Windows' BCP-47 tags (`en-US`) |
| `recognize(pixels, width, height, stride, format, o, allocator) -> (Result, Error)` | the text of a picture of 4 bytes a pixel (alpha not read) |
| `result_destroy(&r, allocator)` | frees a Result |
| `error_text(err) -> string` | an Error in words, for a notification |

`Recognize_Options.languages`: the languages to read, in the codes `languages` gives. Tesseract reads all of them at once (`eng+fra`).
Windows reads one: the first one installed. If the list is empty, the package uses the user's languages:

- On Windows, it takes the languages of the user's profile (`TryCreateFromUserProfileLanguages`).
- On Linux, it takes the language of `LC_ALL`, `LC_MESSAGES` or `LANG`, and English, if they are installed. If neither is
  installed, it takes the first language installed (`default_languages`).

`Result`:

- `text`: the lines in reading order.
- `lines`: each line with its text, its rectangle and its words (each word has its text and rectangle). The rectangles
  are in the pixels of the picture given.
- `engine`: the engine that read the picture.
- `language`: the languages it read with (`eng+fra`, `en-US`).

A picture with no text is not an error: its Result has no lines.

`Error`:

| Value | Meaning |
|---|---|
| `No_Engine` | the system has no engine. |
| `No_Language` | none of the languages asked is installed, or no language is installed at all. |
| `Bad_Picture` | a size, a stride or a length do not match. |
| `Too_Large` | the picture is larger than the engine takes. Windows refuses a side above `OcrEngine.MaxImageDimension`. |
| `Failed` | the engine stopped with an error. |

## What to install

**Linux**: Tesseract 5 and its data for each language to read.

| System | Packages |
|---|---|
| Debian, Ubuntu | `tesseract-ocr` (English included), `tesseract-ocr-fra`, `tesseract-ocr-deu`... |
| Fedora | `tesseract`, `tesseract-langpack-fra`... |
| Arch | `tesseract`, `tesseract-data-eng`, `tesseract-data-fra`... |
| NixOS | `tesseract` in `environment.systemPackages` (its library must be on the loader's path: `LD_LIBRARY_PATH` or the program's wrapper) |

The package loads `libtesseract.so.5` (then `libtesseract.so`) with `dlopen`. It reads the language data
(`<code>.traineddata`) from the first of these folders that has some:

1. `$TESSDATA_PREFIX`, then `$TESSDATA_PREFIX/tessdata`;
2. `/usr/share/tesseract-ocr/5/tessdata` (Debian, Ubuntu);
3. `/usr/share/tessdata` (Arch, Fedora, openSUSE);
4. `/usr/share/tesseract/tessdata`;
5. `/usr/local/share/tessdata`;
6. `/run/current-system/sw/share/tessdata`, `~/.nix-profile/share/tessdata`, `/etc/profiles/per-user/$USER/share/tessdata`
   (Nix).

**Windows** (10 and later): the OCR part of a language pack. Settings → Time & language → Language & region → a language →
Language options → "Optical character recognition". In PowerShell, as an administrator:
`Get-WindowsCapability -Online | ? Name -like 'Language.OCR*'`, then `Add-WindowsCapability -Online -Name Language.OCR~~~fr-FR~0.0.1.0`.

## What the engine sees

Engines are trained on print: black text on white, with letters 20 to 30 pixels tall. A screen gives text of 10 to 16
pixels, often light on a dark theme. `prepare` (pure, used by `recognize` for both engines) changes the picture in this
order:

1. **Grey.** It computes the luminance of each pixel with the BT.601 weights.
2. **Dark on light.** It finds the most common grey, in 16 steps. That grey is the ground, because text covers less of a
   region than its ground. If it is in the darker half, the package inverts the picture (`dark_background`).
3. **Contrast.** It makes the darkest 1 % black and the lightest 1 % white (`stretch_contrast`). This step does
   nothing on a picture with less than 16 steps between them.
4. **Scale.** It measures the height of the lines (`text_height`): the median height of the bands of rows that have ink.
   It does not count bands thinner than 3 rows (rules, underlines) or columns with ink on more than 80 % of the rows
   (borders). Then `upscale_factor` gives the scale:

   | Line height | Scale |
   |---|---|
   | under 10 px | ×3 |
   | under 20 px | ×2 |
   | 20 px or more, or no line measured | ×1 |

   It lowers the scale until the picture has at most 40 million pixels and fits the engine's longest side. The scale
   uses bilinear interpolation, because engines read smooth letter edges better than pixel steps.

Then the engine reads the picture:

- **Tesseract** reads it as one byte a pixel. It uses page segmentation mode `PSM_AUTO` (blocks and columns). If that finds
  no line, it reads again with `PSM_SINGLE_BLOCK`, which finds one word or one short line in a small region. Its notes go
  to `/dev/null`, not to the program's stderr.
- **Windows** reads it as a `SoftwareBitmap` in Bgra8. The package makes it with `SoftwareBitmap.CreateCopyFromBuffer`
  from a `Windows.Storage.Streams.Buffer` that it fills through `IBufferByteAccess`. The other route is `LockBuffer` and
  `IMemoryBufferByteAccess`. It needs four more objects for the same copy.

## Reading order

`reading_order(lines, allocator) -> string` orders the lines and returns the text. Two lines whose heights overlap by
half of the shorter one are on the same row. A row is read left to right, the rows top to bottom. The text joins the
lines of a row with a tab (table cells, a label and its value) and the rows with `"\n"`. Engines give lines block by
block, which is one column at a time. Read by rows, a screen region keeps its rows together, for example a table pasted
into a spreadsheet. Two columns of prose are read row by row, so their lines alternate.

## Threads

The Windows engine joins the calling thread to the Windows Runtime (`winrt.init`, the multithreaded apartment) for each
call and leaves it after. A thread that is already in a single-threaded apartment stays there. The Tesseract engine
creates its own `TessBaseAPI` for each call and loads the language data each time. Two threads can therefore read at the
same time.

Tests: `odin test tests/ocr -vet`. The pure tests check the reading order (rows, overlaps), the scale rule and its limits,
the dark ground, the line height (rules and borders not counted), a dark picture prepared, the languages of a locale and
a bad picture. The engine test draws lines of text in the toolkit's Roboto at 13 and 14 px: dark on light, then light on
dark. The engine of the system must read each one back as one line, with its words, at the place where the test drew it.
If no engine or no English is installed, the test writes a log line and passes.
