# Thumbnails in the file managers

A program that opens documents of its own types (feuille: PDF files) makes the file managers show those documents as
thumbnails: the first page, in Explorer and in Nautilus, Dolphin or Thunar. Everything comes from the program itself:
no library of another vendor, no file shipped beside the program. The how-to is in
[docs/desktop.md](../../../docs/desktop.md#thumbnails-in-the-file-managers) and
[docs/shell-thumbnail.md](../../../docs/shell-thumbnail.md); this file keeps the reasons.

## One part, `Part.Thumbnails`

The thumbnails are a part of the integration (`Integration_Options.thumbnails`), as the document types are: a fact that
`status` reads from the system, written by `install`, taken away by `remove` and by an install with the option off.
A setup `Choice` ties a box to `{.Thumbnails}`; `Facts.parts` covers every part, so the setup needs no code for it. The
types are the program's `document_types`: one list says what the program opens and what it draws.

## Windows: a DLL is unavoidable

- Explorer asks a type's thumbnail of an in-process COM server only: the CLSID named by
  `<type>\ShellEx\{e357fccd-a995-4576-b01f-234630154e96}`, whose `InprocServer32` is a DLL that implements
  `IThumbnailProvider`. An executable cannot be one. Refused: a local server (`LocalServer32`, an executable that
  serves COM): the shell does not ask one for thumbnails.
- The DLL is the program's own: a small Odin package of the program (`src/thumbnailer`), built with
  `-build-mode:dll`, that gives its render procedure to `gt:shell_thumbnail` and exports `DllGetClassObject` and
  `DllCanUnloadNow`. The toolkit's package does the COM plumbing: the class factory, `IInitializeWithStream`,
  `IThumbnailProvider`, the counts. The render is the program's, so the thumbnail is the page the program shows.
- Odin's runtime gives a DLL its `DllMain`, which runs the `@(init)` procedures at `DLL_PROCESS_ATTACH`, under the
  loader's lock. So `set` only stores two values there; the render runs later, in a COM call. Each COM entry makes its
  own Odin context (`runtime.default_context()`): the caller is the shell's thread, which has none.

## Embedded, then written by the install

- The release stays one file. `gt:toolbox` builds the DLL before the program and passes
  `-define:GT_THUMBNAIL_DLL=<file>`; `gt:desktop` `#load`s it, as it does the console launcher (`GT_CONSOLE_LAUNCHER`).
  A check from Linux has no DLL and builds without one.
- The install writes it beside the executable: `<install folder>\<executable's stem>_thumbnails.dll`
  (`thumbnail_dll_file`). A constant rule: removal and status find it from the executable alone.
- The DLL follows the executable's version. An update replaces the executable; at its next start the installed copy
  applies its integration (`desktop.apply`), and `status` reads the part as partial while the DLL's bytes are not the
  embedded ones, so `apply` installs and rewrites it.
- A loaded DLL cannot be overwritten nor deleted, but can be renamed. A write that meets the old one in use renames it
  to `.old` and writes the new one in its place; removal does the same and leaves the `.old` to the uninstall's
  deferred deletion (`files_remove` names the DLL, as it names the launcher). Refused: `MoveFileExW` with
  `MOVEFILE_DELAY_UNTIL_REBOOT`: it writes `HKLM` and needs administrator rights.

## HKCU only

- Everything is in the user's `Software\Classes`: the CLSID (`<Program> thumbnails`, with the mark), its
  `InprocServer32` (`ThreadingModel = Apartment`), and the `ShellEx` key under each extension and under the program's
  ProgID of that type. No administrator rights, as every part of the integration.
- The `ShellEx` value is the program's CLSID, which is its mark: removal deletes the key only while it names that CLSID.
  An install replaces another program's handler of the type in `HKCU` (the person asked for it); removal does not bring
  it back. A handler of the type in `HKLM` comes back by itself once ours goes.

## The surrogate process

- Explorer does not load a thumbnail provider into itself: since Windows 7 it runs it in a surrogate process
  (`dllhost.exe`), so a crash of the provider never takes Explorer down. The DLL never sees Explorer's memory, and the
  document comes as an `IStream` (`IInitializeWithStream`), not a path: the provider reads what the stream gives.
- The surrogate keeps the DLL loaded for some time after the last thumbnail, and may call the provider from several
  threads. The program's render must be thread-safe (`gt:pdf` is). `DllCanUnloadNow` says `S_OK` only when no object
  and no lock is left.

## The size cap

The provider reads the whole stream into memory before it renders: a PDF's cross-reference table is at its end. A
stream larger than `DOCUMENT_MAX` (256 MB) is refused at once: the surrogate's memory is the person's, and a thumbnail
of a file of gigabytes is not worth it.

## The pixels

The render gives straight RGBA, fitted in the size asked. The provider writes a top-down 32-bit DIB section of BGRA
with every pixel opaque, composited on white, and says `WTSAT_RGB`: a page is paper, and a transparent pixel would show
the background of the view through it.

## Linux: the program itself is the thumbnailer

The freedesktop.org thumbnailers are programs, not libraries: a `.thumbnailer` file in
`$XDG_DATA_HOME/thumbnailers` names a command line (`Exec` with `%i`, `%o`, `%s`) and the types. The program's own
executable is that command (`thumbnail_arguments`, default `--thumbnail %i %o %s`): nothing more to build or ship.
The file carries a marker comment (`# <name> thumbnailer`), and removal deletes only a file that has it. `TryExec` is
the executable, so a file left by a program that was deleted is ignored by the readers, gt:desktop's included
(`thumbnail_linux.odin`).
