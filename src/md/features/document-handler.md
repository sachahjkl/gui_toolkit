# A handler of document types

A program that opens files of its own types (a PDF reader, an image viewer) appears in the system's "Open with" for
them, and can be their default. The how-to is in
[docs/desktop.md](../../../docs/desktop.md#a-handler-of-document-types); this file keeps the reasons.

## Two parts, not one part with two options

`Part.Documents` lists the program as a handler of `Integration_Options.document_types`. `Part.Default_Documents` makes it
their default. Each part is a fact that `status` reads from the system. One part with two options would have one state
for two facts: "listed, but not the default" would read as partial, and the install would repair it at each start.

- `default_documents` implies `open_documents`: a default counts only for a program associated with the type (the MIME
  Applications specification; the `OpenWithProgids` of Windows).
- A setup `Choice` ties a box to each part: "Open PDF files with Feuille" to `{.Documents}`, "Make it the default PDF
  reader" to `{.Default_Documents}`.

## The type is the program's constant

`Document_Type` holds the extension, the MIME type and the description. The program gives all three. Refused: one
table of the toolkit that maps an extension to its MIME type. The program knows its own types, and a table of the
toolkit is never complete. The browser's `file_types` keep their table (`CONTENT_TYPES`): a browser names web documents
only.

## Linux

- The part lives in the desktop entry: its `MimeType=` lists each type. An entry exists while `start_menu` or the part
  is on. Without `start_menu` the entry has `NoDisplay=true`: the menu does not show it, and "Open with" still lists it.
  The `Launcher` part then reads as absent.
- `Exec` takes `%f`: the launcher runs one process per file, as Windows does with `"%1"`. A program that takes one path
  needs nothing more. `%U` (a browser) and `%F` (a file manager) come first: a line has one file code.
- The default is the line of each type in `[Default Applications]` of `$XDG_CONFIG_HOME/mimeapps.list`, edited as the
  file manager's (`mimeapps_with_default`): the program's id first, the former ids after it, given back on removal.

## Windows

- Everything is in the user's `Software\Classes` and `Software`: no administrator rights.
- A ProgID per type, `<vendor_key>.<key>.<ext>` ("FromentSoftware.Feuille.pdf"). A ProgID holds letters, digits and
  periods only, so an extension of `document_types` holds letters and digits.
- Three lists name the ProgID, and each of them feeds another place of the shell:
  - `<ext>\OpenWithProgids`: "Open with" of a file.
  - `Applications\<exe name>\SupportedTypes`: the program's own record, which "Open with > Choose another app" reads.
  - The Capabilities, named by `RegisteredApplications`: Settings > Default apps. The value is `<key>.Documents`, apart
    from a browser's `<key>`: a program that is both keeps two lists that never overwrite each other.
- Windows 8 and later keep the default in `FileExts\<ext>\UserChoice`, with a hash that only the shell computes.
  A program cannot set it. With `default_documents` an install opens Settings at the program's page
  (`ms-settings:defaultapps?registeredAppUser=<value>`) when a type's choice is another program's. Windows 10 opens the
  general page. So Windows has no `Default_Documents` part: `supported_parts` says so, and a program shows that box
  only where the part exists.
- Removal deletes the ProgIDs, the values that name them, the program's record and its Capabilities, then the parents
  left empty. It never edits a `UserChoice`: the shell falls back when the ProgID is gone.
- The ProgIDs of an earlier install are those in the Capabilities' `FileAssociations`: a type taken out of the list
  goes at the next install.
