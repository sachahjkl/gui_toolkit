# Views: one content, four presentations

Status: steps 1 to 4 are written (the model, the memory, the Dialog presentation, the ready-made views; the Internal
presentation, the Detach icon, the drag of a dialog's header, the header's menu; the Panel presentation, the dock
spaces, the drops on a dock target, the palette's commands; the External presentation and its windows; section 7.3). The rest is the plan for
the toolkit and for the six programs. The user's decisions are in section 2.5 (the chrome rules)
and section 8.2.

A **view** is a build procedure and its data, declared by an id. The program says that the view is open or closed and
gives its data. The toolkit decides where the view is built. The four presentations are degrees of attachment to the
owner window:

| Presentation | What it is | Modal |
|---|---|---|
| **Dialog** | centred over the owner window, with a scrim. This is the `ui.modal` of today. | yes |
| **Internal** | an internal window: a floating window inside the owner window, drawn by the toolkit. It moves by its header, resizes by its edges, stays above the content and below the dialogs. Several can float; a click brings one to the front. It works on every system, Wayland too. | no |
| **External** | an external window: an OS window of its own, resizable. It uses the renderer and the fonts of the program. | no |
| **Panel** | docked to an edge of the owner window (left, right, bottom, top) or in a dock space of the program. Several views at one place are tabs. It can be undocked. | no |

Each view has a **home**: Dialog or Panel (with its dock place). A dialog's home is Dialog. A side pane's home is
Panel. **Re-attach** brings a view back to its home. Re-attach is not a close: the view stays open.

The user changes the presentation with the small icons of the view's top area, its right-click menu, the palette's
commands, by dragging its header or its tab, and with the dock targets. The docking machinery does not invade the
screens: at rest, a view adds nothing that the program did not draw (section 2.5). The toolkit remembers the last
presentation per view id. Every view accepts the four presentations,
confirmations too. The toolkit has no special case and no program logic.

`ui.modal`, `Modal_Options`, `dialog_header` and `modal_corner` stop being public. `if ui.modal(...) { ... }` goes from
every program. The programs' side panes and their window code (ocn `detached.odin`, inspecteur's journal and Mission
windows, Wren's developer tools window) become views in this work. No compatibility layer is kept.

Contents:

1. [Inventory](#1-inventory)
2. [The API](#2-the-api)
3. [The state machine of a view](#3-the-state-machine-of-a-view)
4. [External windows](#4-external-windows)
5. [Internal windows](#5-internal-windows)
6. [Panels and dock spaces](#6-panels-and-dock-spaces)
7. [Migration and order of work](#7-migration-and-order-of-work)
8. [Risks and open questions](#8-risks-and-open-questions)

---

## 1. Inventory

The columns:

- **Holds**: what the dialog or the pane shows.
- **Data**: where the data comes from, and the procedure that opens it.
- **Result**: how the answer gets to the program.
- **Size**: the `Modal_Options` or the splitter it uses.

Abbreviations: "mutates" means the block changes the program's state directly. "Resizable" means `size = &x`, kept by
the program.

### 1.1 The toolkit

| Site | Holds | Data | Result | Size |
|---|---|---|---|---|
| `src/ui/palette.odin` `palette_view` | the command palette: a search band, the ranked items of its sources, the hint row | `^Command_Palette` and its sources (palette.md). It reads Up/Down/Page keys before its field. It opens with `palette_open`. | `palette_chosen -> (Palette_Choice, ok)` | resizable `PALETTE_WIDTH_EM`×`PALETTE_HEIGHT_EM`, `top = PALETTE_TOP`; the views keep its size |
| `src/ui/commands.odin:637` `shortcuts_sheet` | the list of the keys, by group | `^Shortcuts_Sheet` and `commands` at each frame. It opens with `sheet.open = true`. | none | `SHEET_WIDTH_EM`. Its height is the content, at most `SHEET_HEIGHT` of the window. |
| `src/ui/confirm.odin:47` `confirm` | a title, a note, the lines it acts on, Cancel and the act | `Confirm_Options` at each frame. It opens with `open^ = true`. | `Confirm_Answer`: `.Confirmed`, `.Cancelled` once, else `.None` | grows from `width_em` up to `DIALOG_MAX_WIDTH_EM` |
| `src/ui/confirm.odin:126` `prompt` | a title, a note, one field, Cancel and OK | `^Line_Edit` (the program's) and `Prompt_Options` | `Confirm_Answer`. The text stays in the field. | grows from `width_em` |
| `src/setup/dialog.odin:371` `setup.dialog` | the install dialog: the location, the options, the disk | `^setup.Dialog` (`setup.open`, `:88`), worker jobs (`job_collect`) | `setup.Event` returned at each frame | resizable `DIALOG_EM`, min `DIALOG_MIN_EM`, `d.size` |
| `src/prefs_page/install.odin:10` `install_frame` | the setup dialog of each program, offered at a start | `Install` (`install_open`, `:11`) | `setup.Event` (`.Launched`) | the setup dialog's |
| `src/ui/docking.odin:145` `dock_begin` | the dock: stacks of tabs, splits, floating panels, "Open in a window" (`Dock_Options.windows`, `:107`) | the program's `Dock` and its panel ids | `Dock_Result.closed`, `.windowed` | the dock's layout text, saved by `on_save` |
| `examples/fidget/settings_ui.odin:107`, `shell.odin:270`, `:340`, `:390` | the settings, a palette, a confirmation, About | `app.*_open` | mutates | `top` 0.10, 0.11, 0.16 |
| `examples/showcase/shell.odin:247`, `:255`, `:262`, `scenes.odin:418` | the palette, `confirm`, `prompt`, a resizable dialog (export) | `app.*_open` | as in the toolkit | `app.dialog_size` |
| `examples/docking`, `examples/panes` | the dock and the panes | their own | none | their own |
| `src/ui/file_browser_view.odin` `file_dialog_view` (merged from 0.255–0.259 as a modal of its own) | the toolkit's file browser: the path bar, the places, the list, the preview, Save's question | `^File_Browser` (`State.files`), opened by `ui.file_dialog` | `done(Dialog_Result)`, once; the person's close is Cancel (`View_Kind.on_end`) | resizable `FILE_BROWSER_WIDTH_EM`×`FILE_BROWSER_HEIGHT_EM`, also kept per `remember_id` |

Now a view: `"file_dialog"`, one instance per owner window, built by the views (no pass of its own in `end_build`),
its header the views' (title, icon), its Save question a confirmation over it (`confirm_open` with the browser's
instance). See `file-browser.md`.

### 1.2 papier

| Site | Holds | Data | Result | Size |
|---|---|---|---|---|
| `src/qr.odin:51` `qr_build` | a QR code and its text | `app.qr.text`, cloned by `qr_open` (`qr.odin:36`) | none | the width comes from the window (`side / em + 3`) |
| `src/actions.odin:213` | the toolkit's palette | the table of `ACTIONS` | an action (its move to sources: palette.md) | the palette's view |
| `src/actions.odin:217` | `ui.shortcuts_sheet` | `ACTIONS` | none | the sheet's |
| `src/setup_view.odin:60` | `install_frame` | `app.install` | `.Launched`: quit | the setup's |

The settings of papier are a page (`src/settings_view.odin:66`), not a dialog. The list and the view of papier
(`src/view.odin:405`, a `splitter`) are its content, not a side pane (section 1.9).

### 1.3 classeur

| Site | Holds | Data | Result | Size |
|---|---|---|---|---|
| `src/layouts.odin:159` | `ui.prompt`: the name of a layout | `l.naming`, `l.field` | `.Confirmed`: `layout_save`. An empty name opens the prompt again. | default |
| `src/goto.odin:218` `goto_build` | "Go to": a field and the rows that match, Tab completes | `app.goto`, rows computed before the modal (`goto_rows`) | mutates (`go_to`) | `pw / em`, `top = 0.12` |
| `src/options.odin:60` `options_build` | the settings (`prefs_page.build`) | `app.options`, `prefs_page.show` | mutates the preferences. Close undoes a preview (`options_unpreview`). | resizable `OPTIONS_PREFERRED_EM`, `o.size` |
| `src/dialogs.odin:69` `confirm_build` | `ui.confirm`: delete or empty the trash | `app.confirm` (paths, names), set by `confirm_delete` | `.Confirmed`: `job_add(.Delete)` | default |
| `src/dialogs.odin:102` `conflict_build` | "a name taken": two files, a checkbox, four buttons | the job that asks (`job_asking`). The dialog is open while a job asks. | a `Conflict` choice (Skip, Keep both, Replace, Cancel the job) sent to the job | `CONFLICT_WIDTH_EM` |
| `src/batch.odin:264` `batch_build` | batch rename: three fields, options, the list of new names | `app.batch` (`batch_open`, `:90`), names computed before the modal | mutates and applies | `pw / em`, `top = 0.1` |
| `src/palette.odin:209` | `ui.shortcuts_sheet` | `p.sheet_list` | none | the sheet's |
| `src/palette.odin:222` | the toolkit's palette, its settings among its items | `palette_list` | a choice and its modifiers: run, record keys, alias (its move to sources: palette.md) | the palette's view |
| `src/palette.odin:262` `palette_recorder` | the recorder of a command's keys (`ui.key_take`) | `p.recording` | mutates the keymap | default |
| `src/view.odin:91` | `install_frame` | `app.install` | `setup.Event` | the setup's |

The main window is `host_open` (`src/app.odin:358`). Its side panes are in section 1.9.

### 1.4 inspecteur

| Site | Holds | Data | Result | Size |
|---|---|---|---|---|
| `src/props_view.odin:21` `props_build` | Properties of a process: tabs, a filter, actions | `app.props` (pid, start, tab). It reads the sampler at each frame. Its keys are read inside it. | mutates. It opens the kill confirmation and the affinity over itself. | resizable `PROPS_W_EM`×`PROPS_H_EM`, `pp.size` |
| `src/affinity_view.odin:82` | the processors of a process | `app.affinity` | `act_start(.Affinity_Set)` | `AFFINITY_W_EM` |
| `src/diagnosis.odin:168` | the findings of a diagnosis | `app.diagnosis_open` and the findings | none | `DIAG_W_EM` |
| `src/menu.odin:427` `confirm_build` | `ui.confirm`: kill, signal, stop a service, dump | `app.menu.confirm`, set by `confirm_service` (`:409`) and others | `.Confirmed`: `confirm_act` | default, `enter_confirms` |
| `src/commands.odin:278`, `:301` | the palette and the sheet | the command table | an index | the palette's |
| `src/view.odin:89` | `install_frame` | `app.install` | `.Launched` | the setup's |

`view.odin:47` computes `free_keys` from seven booleans of dialogs. This is an implicit state machine that the views
remove (section 3.5). The journal and Mission Control windows are in section 1.9.

### 1.5 cliche

| Site | Holds | Data | Result | Size |
|---|---|---|---|---|
| `src/editor.odin:2094` | the palette of the editor (to sources: palette.md) | `EDITOR_ACTIONS`, `disabled` | `editor_action` | the palette's |
| `src/editor.odin:2096` | `ui.shortcuts_sheet` | `EDITOR_ACTIONS` | none | the sheet's |
| `src/editor.odin:2097` | `ui.confirm`: drop the changes | `ed.asking` | `.Confirmed`: `ed.close_due` | default |
| `src/editor.odin:2133` `editor_size_dialog` | resize the picture, or add margins: number fields, swatches | `ed.size_dialog`, filled by `editor_size_dialog_open` (`:2105`) | apply: one undo step | `width_em = 24` |
| `src/history_view.odin:1182`, `:1192` | the palette and the sheet of the history window | tables | an action | the palette's |
| `src/history_view.odin:1200` | `ui.confirm`: delete files | `hw.delete_ids` | `worker_send(History_Delete)` | default |
| `src/workflow_view.odin:615` | the add palette, a chooser (palette.md) | `m.add_table` | `workflow_add_chosen` | the palette's |
| `src/workflow_view.odin:660` | `ui.confirm`: delete a workflow | `m.delete_id` | `workflows_remove` | default |
| `src/history_view.odin:553` | `install_frame` | `app.install` | `.Launched` | the setup's |

cliche has several owner windows: the history window (`history_view.odin:345`), one editor per picture
(`editor.odin:437`), the overlays and the pins. A dialog belongs to the window whose build opens it.

### 1.6 opencode native

All dialogs are built in one place, `src/views.odin:44`–`61`, after the page. `App_Context.open: [Dialog]bool`
(`constants.odin:216`) opens them. `dialog_options` (`settings.odin:668`) gives the sizes. `dialogs_track`
(`settings.odin:641`) keeps them in the preference `layout.dialogs`, by position in `DIALOGS_SIZED`.

| Site | Holds | Data | Result | Size |
|---|---|---|---|---|
| `src/settings.odin:749` | the settings (`prefs_page`, server pages) | `settings_open` (`:713`) | mutates the preferences | `DIALOG_PREFERRED_EM[.Settings]`, resizable |
| `src/commands.odin:189` | Help, the keys | `cx.open[.Help]` | none | resizable |
| `src/session_tools.odin:471` `changes_modal` | what a prompt changed, go back | `Changes_State` (a union, `:174`), `changes_open` (`:237`) | posts to the server | resizable |
| `src/files.odin:476` | the files of the project | `files_open` (`:392`) | mutates, opens a diff | resizable |
| `src/schedules.odin:219` | the schedules of a session, a form | `schedules_open` (`:87`) | posts to the server | `top = SCHEDULES_TOP` |
| `src/schedules.odin:606` | the artifacts | `artifacts_open` (`:382`) | none | resizable |
| `src/diff_full.odin:48` | a whole diff | `diff_full_open` (`:24`) | none | resizable |
| `src/output_view.odin:411` | the output of a command, one per command (`OUTPUT_PANEL_BASE`) | `cx.outputs.shown`. It moves to a window already (`output_view_body(..., in_window)`). | none | resizable |
| `src/palette.odin:248` | the program's own palette | `palette_open` (`:55`) | runs a command | resizable, `top = PALETTE_TOP` |
| `src/sidebar_rows.odin:351` | `ui.confirm`: delete a session | `sidebar.delete_id` (`:336`) | `delete_session` | `width_em = 26` |
| `src/images.odin:445`, `:474` | the image viewer, or its wait | `image_view_open` (`:352`) | none. A press around the picture closes it. | the size comes from the picture at each frame (`viewer_frame`) |
| `src/servers.odin:570` | add or edit a server: three fields | `server_edit_open` (`:536`) | mutates `app.servers` | `top = SERVER_DIALOG_TOP` |
| `src/pair.odin:89` | the pairing code | `pair_open` (`:27`) and a request | none | `width_em = 40` |
| `src/context_menus.odin:353` | `ui.prompt`: rename a session | `cx.open[.Rename]`, `rename.field` | `rename_commit` | `width_em = 28` |
| `src/missed_view.odin:128` | "What you missed" | `missed_view_open` (`missed.odin:442`) | marks the notices seen | resizable |
| `src/diagrams.odin:274` | a diagram | `diagram_view_open` (`:239`) | none | resizable |
| `src/setup.odin:78` | `install_frame` | `app.install` | `.Launched` | the setup's |

`Picker` (`picker.odin:96`) is a popup anchored to a button, not a dialog. Menus, pickers and tooltips stay popups.
`overlay_open` (`commands.odin:138`) gathers every open dialog for the keys behind them. The panels and
`detached.odin` are in section 1.9.

### 1.7 Wren (read-only)

Wren builds its dialogs in the frame of each browser window (`windows.odin`). Each browser window is an owner.
Wren does not use `gt:host`: it has its own loop (`src/host/loop.odin`) and its own windows.

| Site | Holds | Data | Result | Size |
|---|---|---|---|---|
| `src/browser/confirm_shell.odin:88` | `ui.confirm` of the shell (delete a bookmark folder, a download, history) | `app.confirm`, set by `confirm_ask` and the `*_asked` procedures | a `kind` switch on `.Confirmed` | default |
| `src/browser/fs_shell.odin:134` | a page asks for files | the head of `app.ask_state.queue`, queued by a page (`fs_shell_ask`) | `page.fs_ask_done(req, granted)` | `width_em = 30` |
| `src/browser/notification_shell.odin:191` | a page asks for notifications | the head of `app.notes.asks` | the page's callback | `width_em = 30` |
| `src/browser/storage_access_shell.odin:45` | a page asks for storage access | the head of `app.sa_queue` | the page's callback | `width_em = 32` |
| `src/browser/passkey_choice.odin:164` | choose a passkey | `app.passkey_choice`. It closes when the page ends its request. | the Vault's ticket | resizable, `c.size` |
| `src/browser/webauthn_shell.odin:103`, `:163`, `:216` | a security key: PIN, account, touch | the WebAuthn request. One question at a time. | the request's answer | resizable |
| `src/browser/vault_shell.odin:721`, `:1047` | `ui.confirm`: log out, fill an insecure page | `s.logout_ask`, `s.ask_open` | mutates the Vault | default |
| `src/browser/vault_shell.odin:777` | the Vault's login, unlock, approval | `app.vault` | mutates the Vault | resizable, `s.dialog_size` |
| `src/browser/vault_shell.odin:997` | set a PIN | `s.pin_dialog`. It closes when the Vault locks. | mutates | resizable, `s.pin_size` |
| `src/browser/vault_save.odin:270` | the password generator | `s.gen_dialog` | copies the password | resizable, `s.gen_size` |
| `src/browser/qr_shell.odin:27` | the QR code of the page | `app.qr_url` (`qr_open`, `:15`) | none | `QR_SIDE_EM + 6` |
| `src/browser/bookmarks_ui.odin:171` | edit a bookmark or a folder | `app.bview`. It closes when the bookmark goes. | mutates | `width_em = 28` |

Most of Wren's dialogs use a local `open := true` and close by their own rule (the queue empty, the Vault locked).

### 1.8 The dialog patterns

| Pattern | What makes it | Examples |
|---|---|---|
| **A. Question** | A fixed set of answers. The program acts on one answer, once. | every `ui.confirm`; classeur conflict; Wren permissions, WebAuthn touch |
| **B. Typed answer** | Fields, then OK. The value is in the program's fields. | every `ui.prompt`; classeur batch rename; cliche size; ocn server, rename; Wren PIN, bookmark |
| **C. Chooser** | A list and a search. Enter chooses, then the view closes. | palettes; classeur goto; Wren passkey choice, account choice |
| **D. Viewer** | Shows data. No answer. | QR codes, the sheet, diagnosis, image, diagram, diff, output, artifacts |
| **E. Long-lived tool** | Its own state, its own keys, actions that act at once, it stays open. | settings (classeur, ocn), inspecteur Properties, setup, ocn Changes, files, schedules, Wren Vault |
| **F. Queue-driven** | Opened by a request from another thread or a page. Closed when the request ends, whatever the user does. | classeur conflict; Wren fs, notifications, storage access, passkeys, WebAuthn |

### 1.9 Side panes, dock panels and windows of their own

The rule: a pane that the user can hide, resize or move becomes a view with a home of Panel. A part of the window
that is always there with a fixed size is content (papier's list and view, classeur's folder columns, inspecteur's
navigation sidebar of `SIDEBAR_EM`, ocn's conversation).

| Program | Site | Holds | Data | Today | Its view |
|---|---|---|---|---|---|
| classeur | `src/view.odin:372` | the sidebar (places, folders) | `app.sidebar` (shown), `app.sidebar_px` | a `splitter` at the left, a preference for its width | `"sidebar"`, home Panel left of the frame |
| classeur | `src/inspector.odin:304` | the inspector of the selected item | `app.inspector`, its `ui.Pane` kept in `inspector.width`; `inspector_ask` | a `pane_split` beside the list that has the keyboard, folded to a strip | `"inspector"`, home Panel right of the frame |
| cliche | `src/history_view.odin:573` | the preview of the selected capture | `hw.preview_open`, preference `history.preview_width` | a `splitter` at the right of the history window | `"preview"`, home Panel right of the history window's frame |
| inspecteur | `src/services_view.odin:57` | the details and the journal of the selected service | `app.services.pane`, preference `services.details_height` | a `splitter` under the list of services | `"service"`, home Panel bottom of the dock space `"services"` |
| inspecteur | `src/journal_window.odin:32` | a service's journal in its own window, one per service | `Journal_Window` (manager, name, its own `Journal_View`) | a `host.Host` with its own title bar, `JOURNAL_WINDOW_SIZE` | `"journal"`, an instance per service, home Panel bottom of the frame, first External |
| inspecteur | `src/mission_control.odin:119` | the eight Mission Control panels (`Mission_Panel`, `:22`) | `app.mission.dock`, its text saved by `mission_save` | `ui.dock_begin` in the Mission Control section, `windows = true` | `"mission/<panel>"`, home Panel in the dock space `"mission"` |
| inspecteur | `src/mission_window.odin:28` | a Mission Control panel in its own window | `Mission_Window`; reopened at the next start (`mission.windows`) | a `host.Host` | the External presentation of `"mission/<panel>"` |
| ocn | `src/views.odin:37` | the sessions' sidebar | `app.sidebar` (`hidden`, `width`) | a `splitter` at the left | `"sidebar"`, home Panel left of the frame |
| ocn | `src/preview.odin:564` | the dock: Conversation, Preview, Terminals, Stats (`Panel`, `preview.odin:21`) | `app.dock`, `dock_setup` (`:186`), preference `layout.dock` | `ui.dock_begin` around the conversation | the conversation is the frame's content; `"preview"`, `"stats"`, `"terminal"` (an instance per shell, `TERM_PANEL_BASE`) are views, home Panel right |
| ocn | `src/detached.odin:88` `panel_detach` | a dock panel in its own window | `Detached`: a `host.Host`, `detached_style`, `detached_asks`, the terminal's keys moved by the `input` hook (`:178`) | built after the main window in `main_after_frame` (`main.odin:409`) | the External presentation of each view. The file goes. |
| ocn | `src/output_view.odin:411` | a command's output, dialog or window | `cx.outputs`, `OUTPUT_PANEL_BASE` | its own `in_window` path | `"output"`, an instance per command, home Dialog |
| Wren | `src/browser/devtools.odin:554`, `main.odin:1117`–`1129` | the developer tools, docked left, right or bottom of the page | `Window_Own.devtools`, `dev().size` | a `pane_split` beside the page | `"devtools"`, an instance per browser window, home Panel bottom |
| Wren | `src/browser/devtools_window.odin` | the developer tools in their own window | `Dev_Window` | its own window code on Wren's loop | the External presentation of `"devtools"` |

The developer tools' own dock (`devtools_layout.odin:142`, `devtools_elements.odin:493`) is their content. It stays
a `ui.dock_begin` inside the view.

Facts that constrain the design:

1. Pattern F opens and closes from the program's state. `view_close` must work at any time.
2. One view can have several instances at the same time: inspecteur's journal (per service), ocn's terminals and
   outputs, Wren's developer tools (per browser window), cliche's editor dialogs (per editor).
3. A view can open another view over it: inspecteur's kill confirmation over Properties.
4. A view's size can follow its content at each frame (ocn's image viewer).
5. Panels are not only at the window's edges. Mission Control and inspecteur's Services section have dock spaces of
   their own, inside the content of one section.
6. A view can hold a native child window: ocn's Preview (a web view, `under_children`, `preview_move`). It must follow
   the view to another OS window.
7. Four places in three programs repeat the same window code: a `host.Host` on the shared renderer, the style copied,
   the wakes forwarded, the window built after its owner.

---

## 2. The API

The file is `src/ui/views.odin`, in package `ui`. The external window backend is in `src/host/views.odin`.

### 2.1 Types

```odin
// How a view is shown, from the most attached to the least.
View_Presentation :: enum u8 { Dialog, Panel, Internal, External }

// An edge of a dock space.
View_Edge :: enum u8 { Right, Left, Bottom, Top }

// Where a panel goes: a dock space (by name; "" is the owner window's frame) and an edge of it.
View_Place :: struct { space: string, edge: View_Edge }

// What a view is, given once when it is registered. Sizes are in ems of the owner's style.
View_Options :: struct {
	title:          string,            // in the header, the tab and the OS title (a constant: kept)
	icon:           string,            // a glyph of icon_font before the title ("": none)
	icon_font:      font.Font_Id,      // 0: the state's icon font
	home:           View_Presentation, // .Dialog or .Panel: where re-attach brings it (default .Dialog)
	home_place:     View_Place,        // with home .Panel (default: the frame's right edge)
	first:          Maybe(View_Presentation),   // the presentation of its first opening, before the user chose (nil: home)
	float_edge:     Maybe(View_Edge),  // an internal window of no rect of its own opens against this edge of the content,
	                                   // MODAL_MARGIN_EM in (Right: top right, a tool window beside what it acts on); nil: centred
	width_em:       f32,               // the first size of the dialog and of the windows (0: DIALOG_WIDTH_EM)
	height_em:      f32,               // 0: as tall as what is in it
	min_width_em:   f32,
	min_height_em:  f32,
	extent_em:      f32,               // a panel's width or height (0: width_em, or height_em at Top and Bottom)
	resizable:      bool,              // the dialog has grips. The windows and the panels are always resizable.
	top:            Maybe(f32),        // the dialog's top at this fraction of the window (a palette); nil: centred
	under_children: bool,              // its external window gets a native child window (host Open_Options)
	moved:          proc(data: rawptr, win: ^platform.Window),   // it is now built in `win` (a native child follows); nil: none
}

// The handle a build procedure gets. The program reads it; it does not keep it after the build.
View :: struct {
	id, instance:  string,
	presentation:  View_Presentation,
	place:         View_Place,        // with .Panel
	shown:         bool,              // false: this build is unseen (measured, section 3.4). It takes no input.
	// (private fields: the kind, the data, the machine, the State it is built in, the root key)
}

// The build procedure. It builds the body only: the header is the toolkit's (section 2.5).
View_Build :: #type proc(v: ^View, data: rawptr)

// The views of a program: what is registered, what is open, what is remembered, the dock spaces.
Views :: struct { /* private */ }

Views_Options :: struct {
	path:    string,         // the memory file, in the program's state folder ("": memory only, for tests)
	windows: View_Windows,   // what opens an external window (host.view_windows for a host.Host program)
	labels:  View_Labels,    // the words of the header and the menus (zero: view_default_labels, translated)
}

// The answer of a view that ended. VIEW_CANCELLED: the user closed the view (Escape, the close button, the scrim),
// or its owner window went. Other values are the program's (an enum cast to int).
VIEW_CANCELLED :: -1
```

`Panel` comes before `Internal` in the enum because it is attached to the owner's layout; `Internal` is only drawn
over it. The order is not used for logic.

### 2.2 Procedures

**Who owns the Views.** A rule that every program and test must remember ("views_init first") is forgotten everywhere,
so nothing is called before the first view:

- A zero `Views` works: memory only, the allocator of its first use.
- Every `ui.State` has one. By default it is the State's own (`State.own_views`), made at its first use and destroyed by
  `ui.destroy`. `state_views(s)` gives it; `views()` gives the one of the State in use (being built, else last built
  or selected).
- A program that keeps the memory in a file, or whose windows share their views (an external window, a view moved
  between windows: one Views per program is required there), owns one `Views` and gives it to each of its windows'
  States with `set_views(s, vs)`. `views_init(vs, o)` is then optional: it reads the file. That program calls
  `views_destroy(vs)` after its last build; `ui.destroy` and `views_destroy` forget each other in either order.
- The ready-made views take no `Views`: `confirm_open(id, o)`, `palette_open(p)`, `setup.open(d, o)`... use
  `views()`. The host (step 4) gives its program's Views to each window it opens.

```odin
state_views   :: proc(s: ^State) -> ^Views            // its own, unless set_views gave one
views         :: proc() -> ^Views                     // of the State in use
set_views     :: proc(s: ^State, vs: ^Views)          // the program's, shared by its windows
views_init    :: proc(vs: ^Views, o: Views_Options)   // optional: reads the memory file (before its first view)
views_destroy :: proc(vs: ^Views)                     // closes every window, gives no answers, flushes the memory

// Declares a view. Call it once per id at start-up. The data's type is checked at each view_open.
view_register :: proc(vs: ^Views, id: string, build: proc(v: ^View, data: ^$T), o: View_Options)

// Opens the view (one already open comes forward: a window is raised, a panel's tab shown, a dialog focused). It opens
// in its last presentation (the memory), else `first`, else its home. `data` must stay valid until the view is
// closed: the program owns it. The owner is the State being built; `owner` names another one. An answer not taken
// from a former opening is dropped.
view_open :: proc(vs: ^Views, id: string, data: ^$T, instance := "", owner: ^State = nil)

// Closes it now, in whatever presentation. Its build is not called again. No answer is kept.
view_close   :: proc(vs: ^Views, id: string, instance := "")
view_is_open :: proc(vs: ^Views, id: string, instance := "") -> bool

// Whether it was open when the program last quit (a side pane, a journal window): the program opens it again.
view_was_open :: proc(vs: ^Views, id: string, instance := "") -> bool

// Moves it to another presentation (what the header buttons do). The choice is remembered.
view_present  :: proc(vs: ^Views, id: string, p: View_Presentation, place := View_Place{}, instance := "")
// Back to its home presentation and place. The view stays open.
view_reattach :: proc(vs: ^Views, id: string, instance := "")

// The answer of a view that ended, taken once: ok is false until it ended, and after it was taken.
view_ended :: proc(vs: ^Views, id: string, instance := "") -> (code: int, ok: bool)

// Inside a build: closes the view with this answer.
view_end :: proc(v: ^View, code: int)

// Inside a build: a title for this frame (a process's name). Temporary memory is enough.
view_title :: proc(v: ^View, title: string)

// Inside a build: the room of the body in this presentation, from the last layout (a viewer sizes its picture by it).
view_room :: proc(v: ^View) -> Vec2

// Inside a build: this opening's dialog size in ems (0: the kind's), as view_title gives a title. It wins over the
// id's remembered size (forgotten for this opening, not rewritten); the user's resize of this opening wins over it.
// A width past DIALOG_MAX_WIDTH_EM holds: the cap is for a dialog sized by its words, not one sized by its picture.
// Refused: an option of view_open (the size is known only once the picture is, in a build).
view_size :: proc(v: ^View, width_em, height_em: f32)

// Inside a build: `if ui.view_header_tools(v) { ... }` builds controls in the header, after the title.
@(require_results, deferred_none = view_header_tools_end)
view_header_tools :: proc(v: ^View) -> bool

// Whether a view shown as a dialog holds the keys of the State being built (inspecteur's free_keys, ocn's overlay_open).
views_hold_keys :: proc(vs: ^Views) -> bool

// In each owner window's build, around its content: `if ui.views_frame(&app.views) { content }`. It builds the
// frame's dock space (its panels), the internal windows, then the block is the content's box; the end of the
// statement builds the dialogs, on top (section 6.1).
@(require_results, deferred_none = views_frame_end)
views_frame :: proc(vs: ^Views) -> bool

// A dock space of the program's own, inside its content (Mission Control, Services). With `o.content`, the block is
// its fixed centre; without it, the space is panels only and the block is empty.
@(require_results, deferred_none = views_dock_end)
views_dock :: proc(vs: ^Views, name: string, o: View_Dock_Options) -> bool

View_Dock_Options :: struct { content: bool }
```

`dialog_body` and `dialog_buttons` stay public. A build procedure uses them for its body and its row of buttons.

The typed procedures are parametric over `$T`. They store `data` as `rawptr` and `typeid_of(T)`. `view_open` asserts
that `T` is the type that `view_register` got. This catches a wrong pointer on the first run.

### 2.3 How a view gets its data, and the order of builds

All windows of a program are built on one thread, one after the other. The owner's frame comes first. The external
windows come after it, in the owner's `host_frame`, as ocn's `detached_frames` does today. So a build procedure can
read and change the program's state through `data` with no lock. The rules:

1. **Data is the program's, by pointer.** It is a field of the app or a heap object. It is not temporary memory:
   `host_frame` frees the temporary allocator at the end of each window's frame.
2. **A change made by a view in an external window is seen by its owner at the owner's next build.** The toolkit asks
   that build at once: after an external window's frame with input or with an answer, it calls `wake_within(owner, 0)`.
   This replaces ocn's `detached_asks`.
3. **The build procedure runs with the State of the presentation current.** Dialog, Internal and Panel: the owner's
   State. External: the window's State. Every `ui` call inside it goes to the right State. `announce` inside it
   shows the toast in the window where the view is.
4. **An unseen build takes no input** (`v.shown == false`). Its events are nil and its dt is 0. It only measures the
   layout. A build procedure acts on signals, and an unseen build has none.
5. **A view does not keep a pointer to a box.** A view moves between States. Its boxes are found by key in the State
   of the frame.

### 2.4 How an answer gets to the program

The answer is polled with `view_ended`. It is not a callback.

- A callback runs where the view is built. That is often another window's State. The program's code then calls `ui`
  procedures on the wrong State. ocn passes `history_window_of(app)` to `app_announce` for this reason.
- A polled answer is read by the program in its owner's build, with the owner's State current.
- The answer stays until it is taken, or until the view opens again. It is given once.

A dialog is built at the end of the owner's build, after the owner's code that polls. So the program reads the answer
at the next build, one frame later than today. The toolkit asks that frame at once (`anim_busy`). Tests wait for the
answer with a bound (section 7.4).

The type of the answer is an `int`. A program casts its own enum: `ui.view_end(v, int(Conflict.Replace))`. Values
from 0 up are the program's. `VIEW_CANCELLED` is the toolkit's.

### 2.5 The header, and the chrome rules

The user's rule: the docking machinery must not invade the screens. A view at rest adds nothing to what the program
draws, except the header that a dialog always had. The rules:

1. **A panel alone in its stack has no tab strip**, unless its kind says `tabs_always` (ocn's terminals: a strip
   with one tab and its "+" says that more can come). A tab strip appears when two or more views share a stack, or
   one of them is `tabs_always`, or its zone is minimised. A panel alone otherwise adds no strip and no border: its
   body starts at the zone's top edge. A test checks this (section 7.4, test 17). A side zone that folds to its views'
   compact form (`rail_em`) adds no row either: its view places the fold button in a row of its own (rule 2b,
   Minimise).
2. **A lone panel's strip comes on a rest at its top edge, pushes its body down, and goes when the pointer leaves the
   panel** (`view_hover_strip`). At rest nothing is added. The strip is the stack's strip, as if the panel had
   company: its tab (its title, its menu), its moves, its Minimise, Maximise and Close (rule 2b). It takes its room:
   the body moves down under it, and no control of the panel lies over a control of the body. Its state machine, per
   view (`View_Record.hover`, `View_Hover`):
   - **Rest → Armed**: the pointer is in the stack's top band (`VIEW_HOVER_EDGE_EM`, by the last layout), no mouse
     button is down (`State.buttons_down`: a drag holds one) and none was pressed in this build. The time is noted.
   - **Armed → Rest**: the pointer leaves the band, or a button goes down. A new arming starts from zero.
   - **Armed → Shown**: the pointer stayed in the band for `VIEW_HOVER_DWELL_MS` (300 ms). While armed, the build asks
     for one timed frame at the deadline (`wake_within`), not a frame each refresh.
   - **Shown → Rest**: the pointer leaves the stack's rect (the pointer outside the window too), unless one of the
     strip's boxes is held (a tab dragged out) or the view's menu is open; Escape (read, not taken: the body still gets
     it); a click on the strip (its act is done in that build, the strip goes in the next one).
   - From Rest the strip comes back only by a new arming and a full dwell: the body never jumps back and forth by
     itself.
   So the body never moves while the pointer only passes the band, and never moves up under a pointer inside the
   panel. The fold button and the controls at the body's top stay where the pointer goes to them.
   **Why the dwell, its own delay.** The tooltip delay (`Feel.tooltip_delay_ms`, 500 ms) is too long for an act, and
   a person who makes it longer to see fewer tooltips would not mean a slower strip. The submenu delay
   (`Feel.menu_hover_ms`, 280 ms) is close, but a person may set it to 0 for quick menus, and a dwell of 0 brings the
   defect below back. So the strip has its constant.
   **Why it changed (0.314).** The strip came on the first build in the band and went as soon as the pointer was
   past `strip + VIEW_HOVER_KEEP_EM`. In opencode native the sidebar's fold button is 1 em under the panel's top,
   under the title bar: a pointer going down to it crossed the band, the button dropped by the strip's height, and the
   click landed on the strip's tab (a press and a small move detached the panel). Chasing the button down left the
   keep reach: the strip went, the button jumped back up. The fold button could not be reached while the strip showed.
   Refused: the strip over the body (0.267's defect, below: it covers the body's controls); a band kept for it at all
   times (two ems taken from every lone panel, against rule 1); the strip only with a modifier held (Alt: no one finds
   it); fading icons in the corner (the corner is the body's: its strips, its buttons).
   The panel's menu (rule 3) holds the strip's acts too, for a person who does not wait: a right click on the free part
   of the top band or on the fold button (`view_fold_button`) opens it, and it has Minimise and Maximise (or Restore)
   for a panel.
   **Why it changed (0.267).** Two small icons, Detach and Close, floated over the body's top right corner on the hover
   of its top area. They took no room, so they lay over the body's own controls: the user could not click on purpose
   either the panel's icon or the button under it (opencode native's browser panel), and the icons had no plate. The
   rules below were patches over that overlap; they are kept for the record. The user chose the strip that pushes the
   body, over a strip always shown (two ems taken from every lone panel, against rule 1) and over no hover control at
   all (the moves only in the menu and the palette: hard to find).
   *Before (refused since):* the icons never covered the control the pointer was on.
   **They never cover the control the pointer is on.** Where the pointer is in their corner over a control of the body
   (by the last layout, the icons apart), they do not show, and that control takes the press; elsewhere in the top area
   they show as before. They stay while one of them is held, not while any box of the body is. Shown over a control, they
   took the press meant for it: in opencode native the sidebar's server tabs fill its top area, and the click on their
   strip's right arrow, under the Detach icon, floated the sidebar (a new box tree: the strip at its start again).
   Refused: hiding them over any control of the top area (a field at its left would have hidden them for nothing), and
   moving them (the corner is where a person looks for them).
   **Never over a strip.** When a strip of the body (`ui.strip`, opencode native's server tabs) lies in their corner,
   they do not show at all, wherever the pointer is in the top area: shown when the pointer came to the area's free
   start, they covered the strip's right arrow, and the person had to go around them to reach it. The test is the
   strip's box, not its arrows: the arrows come and go with the scroll, the icons would have come and gone with them.
   The panel's menu (a right click on the area's free part, rule 3) and the palette still detach and close it. Refused: moving
   them past the strip (a sidebar's row of tabs ends near the panel's edge: no room is left there) and putting them under
   the strip's row (over the content that follows it, a "New session" button).
2b. **The tab strip, left to right** (`view_stack_strip`): the tabs, in the look of every row of tabs (`tab_box`) and on
   a strip ([strip.md](strip.md)): too many for the stack, they scroll with arrows over the faded edge, never a bar; the
   "+" of the shown view's kind (`new_tab`), right after the last tab (outside the strip: at its end when the tabs
   scroll), where the new tab appears; the shown view's moves (Float, Open in a window, Re-attach when
   not at home), small and weak, side by side, where the eye already is; the program's tools of the shown view
   (`view_header_tools`); then, at the right end, Minimise, Maximise and Close of the stack, drawn as the window's
   caption buttons (one builder, `caption_row`, for both). Refused: the moves at the far right (the eye is on the tabs;
   the right end is the stack's own, as a window's is).
   - **"+"** calls `View_Options.new_tab(data)` with the shown view's data: the program opens a new instance
     (`view_open` with a new name), often later (ocn asks a server for a shell; it answers frames later). So the "+"
     leaves its stack waiting (`View_Kind.tab_place`, `tab_wanted`, `tab_until`): the next instance of that kind that
     opens, during the call or after it, within `NEW_TAB_WAIT_MS` (10 s), joins this stack, its tab last (where the
     "+" was) and shown. One "+", one instance: each opening takes one. Later than the bound, or when that stack is
     gone, it opens where its memory says. Why a time and not "until the user does something else with the stack": a
     click elsewhere does not make the shell asked for less wanted there, and no act of the user's says the request is
     abandoned; a time does, for a server that never answers (its instance, opened a minute later from elsewhere,
     must not jump into a stack). The same act is the first item of the band's menu and a
     palette command ("New terminal": `new_tab_label`, else "New tab"), for each kind with `new_tab` that has a view
     open. Refused: the toolkit making the instance's name or data (the program's: a shell's id).
   - **Words are the program's source words**: `title`, `new_tab_label` and `Views_Options.labels` are kept as given
     (English, `i18n.later`) and translated when shown, at each build. Refused: translating at registration (the
     words stayed in the language of the start).
   - **Maximise**: the stack takes the whole dock space for a while: the other zones are not built, the program's
     content is laid out at no size (built, its state kept, not seen). Maximise again, or Escape with the focus in it,
     restores. Not remembered across runs: a program that starts with its content hidden looks broken.
   - **Minimise**: the zone collapses; a click on a tab, or the button again, restores. Remembered per zone
     (`bottom.min=1` in the space's line). A side zone's Minimise and Restore are the manual acts of its fold
     ([side-panels.md](side-panels.md)): they hold until the space's width next crosses the zone's threshold
     (`left.min=1 left.narrow=1`: both bits of its `Side_Fold`).
     - At the top and the bottom it collapses to its strips (each stack's strip, no body, no handle).
     - **At the left and the right it collapses to a rail** (`view_zone_rail`): a column one strip wide, with a Restore
       button at its top, then one button per view (its icon, its title as the tooltip), the stacks one after the
       other. A click on a view restores the zone with that view shown. A strip is no narrower than a side zone, so a
       side zone collapses to something else: a column of icons, as an editor's side bar.
     - **A view's own compact form** (`View_Options.rail_em`, `View.rail`): a view that states a rail width keeps that
       column when its zone collapses (by Minimise or a narrow space), and is built in it with `View.rail` set: it
       draws its compact form itself (opencode native's sidebar: a column of the sessions' marks with rich tooltips).
       The toolkit draws nothing else in that column: the view places the zone's Restore itself (the fold button,
       below). A zone holding several such views takes the widest. A view without one keeps the icons' rail. Refused:
       the toolkit drawing a view's compact form from its title (an icon says less than a list of marks), and a second
       view registered for the compact form (two views of one list would drift).
       **Why it changed.** The side zones had no Minimise (refused: "the handle makes a side zone narrow"). The user
       lost the way to fold opencode native's side panel (`/btw`) that its own pane had before it moved to the views:
       the handle narrows it, never folds it.
     - **The fold button, placed by the view** (`view_fold_button(v)`): a view in a side zone calls it in its own build,
       in a row it already has; it draws the zone's Minimise when the zone is expanded and its Restore when it is
       collapsed: the same small icon button (`PANEL_LEFT_CLOSE` and `PANEL_LEFT_OPEN`, `RIGHT` at the right), its
       tooltip `labels.minimize` or `labels.restore`. It acts as the strip's Minimise and the rail's Restore: one
       transition (`view_stack_minimise`), remembered (`left.min=1`). Elsewhere (a zone at the top, the bottom or the
       centre, a dialog, a window) it builds nothing. A view with `rail_em` must call it in its compact form: the
       toolkit's rail draws no Restore for it (a debug assertion says so). Expanded, a view that called it in its last
       build has no Minimise on its stack's strip (said once); the icons' rail (`rail_em = 0`) keeps the toolkit's own
       Restore, and its views their strip's Minimise. A right click on it opens the view's menu (rule 3, Minimise and
       Maximise included), and its tooltip says so after its act (`View_Labels.menu_hint`): a lone panel's strip waits for a
       rest at its top edge (rule 2), the menu is at the button the pointer is on.
       opencode native puts it at the start of its servers' row expanded and at the top of its rail minimised, at the
       same pixel in both states: the button stays under the pointer when the person folds and unfolds.
       **Why it changed (0.304, the head of 0.300 refused).** The toolkit drew the Minimise in a row of its own above
       the body, at the rail's Restore's place. The row was empty but for the button: a band across the sidebar that
       the user saw as a strange black line. The view knows its rows; the toolkit does not.
       Refused: the head row (an empty band); a button in the window's title bar (there is no place for it with the
       system's title bar); the button at the far end of a row (it jumps when the zone folds: the rail is narrower than
       the zone); the button over the body's top corner (it lies over the body's controls, as the 0.267 icons did).
     - **The rail keeps the zone's edge line** (`view_zone_handle`): a side zone collapsed (both rails) keeps its
       handle, so the line between it and the content is the expanded zone's: one splitter, one colour, one width, one
       side, and `view_dock_line` says where it is in both states. **Why.** The user: the rail had no line against the
       content, unlike every other zone and panel. Refused: a border drawn by the rail (a second drawing of one line).
     - **Pulling the rail opens the zone** (one state machine with Minimise): the zone's handle is `side_handle`
       ([side-panels.md](side-panels.md), the handle and the pull). Under the rail's width plus `SIDE_PULL_EM` the
       zone is collapsed, past it expanded, its width the raw one held to `DOCK_MIN_EM` and the space less the
       content's minimum. So a pull outward from the rail past the threshold restores the zone and the zone follows
       the pointer from there, and the width let go is remembered; a pull inward, or less than the threshold, does
       nothing. The same drag from an expanded zone down to the rail folds it, and its extent stays the one it had at
       the press (Restore brings it back). Each change of state goes through `view_stack_minimise`, as the buttons
       do. The keys on the handle keep the width's limits and never fold. **Why.** The user: pulling the rail must
       bring the zone back. Before, a drag under the minimum stopped at it and the collapsed zone had no handle.
       Refused: a threshold of its own for the fold (two thresholds on one drag are two state machines).
     - **A side zone folds itself when the space is too narrow** (the rule of [side-panels.md](side-panels.md)): when
       the space less the zone's extent leaves the content less than `DOCK_MIN_EM`, the zone folds to its rail; once
       it leaves `DOCK_MIN_EM` plus `SIDE_FOLD_GAP_EM`, it opens again. A Minimise or a Restore holds until the next
       crossing, either way: a zone opened while narrow opens over the content's minimum until the space is wide,
       and a zone minimised while wide comes back when the space has been narrow and is wide again. Only where the
       centre is the program's content (`views_dock` without `content` never folds by width). **Why it changed
       (0.313).** A Minimise was kept forever and a narrow fold was a second state outside the memory
       (`sp.folded`, `sp.unfolded`); see side-panels.md.
   - **Close** closes every view of the stack (each ends with `VIEW_CANCELLED`): it is the stack's button, beside the
     stack's Minimise and Maximise. One tab closes by Ctrl+W in it, its menu's Close or the palette. Refused: closing
     the shown tab only (two buttons at the right end would act on the stack and one on a tab).
   - **Every presentation where a strip shows**: a stack of panels only. An internal window and a window of its own
     hold one view each, with their header; a window holding several views does not exist.
2c. **A window of its own follows the program's decorations** (`window.system_title`, the program's own title bar or
   the system's: `platform.is_integrated_title` of the owner's window, read at the opening and at each step, so a
   change at run time applies to open view windows; on Windows the frame changes as the main window's does, on Wayland
   the xdg-decoration is negotiated again). With the program's own: the window has no system decoration, and the
   view's header is its title bar (`.Window_Caption`, not Clickable: the system drags it, a double click maximises it,
   snap layouts show over its maximise), with the window's minimise, maximise and close at its right end
   (`window_buttons`: the main window's code and look). That close is the system's close of the window: it
   re-attaches the view; the view's own Close stays in the header. With the system's: the system's title bar, and the
   header under it without the window's buttons. Refused: a title bar of the view windows' own (a second code of
   captions); the drag of the header onto the owner's dock targets with the program's decorations (the system moves
   the window there; the menu and the palette still dock it).
3. **The view's menu, on a right click** (`view_header_menu`): New tab (a kind with `new_tab`), Detach into a window,
   Open as a floating window, Dock left, Dock right, Dock bottom, Re-attach; then the presentation's size acts (a
   panel: its stack's Minimise, or Restore its zone folded, and Maximise, or Restore its stack maximised; a resizable
   dialog: Maximise or Restore); then Close. The same moves are palette commands, made by the toolkit for every
   registered view: "Open <title> in a window", "Float <title>", "Dock <title> to the left", "Dock <title> to the
   right", "Dock <title> to the bottom", "Re-attach <title>", "Close <title>". A program adds them to its palette with
   `views_commands` (step 3).
   - **Where it opens.** One builder for every place: a dialog's, a floating window's and a window's header; a stack's
     tab; the free part of a docked panel's top area (`view_panel_menu_press`), a maximised stack's included; the side
     zone's fold button (`view_fold_button`); a view's button on the icons' rail.
   - **One set of acts, absent where they do nothing.** `view_acts` says which moves apply to the view where it is: the
     palette lists them, the menu shows them, and each item runs the palette's command (`views_command_run`): no second
     path. An act that does nothing there is absent from the menu, never disabled, as the toolkit's menus and the
     palette do: Detach into a window while the program opens no windows (`views_windows_ready`), the Dock items with
     no frame space (`view_frame_built`) and the edge the panel is at, Float in a floating window, Re-attach at home.
     Minimise is absent at the centre (nowhere to fold to) and while the stack is maximised (two items would say
     "Restore"). Close keeps its presentation's path: a panel's menu is built after its body, so it closes as the
     palette does (`User_Close`); a dialog's or a window's is built before `view_build_ended`, which reads its flag as
     its close button's. Refused: disabled items (the menu said "you cannot" about an act the person had no reason to
     look for, and it disagreed with the palette, which never listed them); a menu builder per place (the fold
     button's had Maximise, the header's did not).
   - **The free part of a panel's top area.** The strip's free part when the strip shows (two tabs, `tabs_always`, a
     zone minimised, a lone panel's hover), else the band at the body's top where a rest brings the strip
     (`VIEW_HOVER_EDGE_EM`). The top area is the body's too (ocn's sidebar has its server tabs there, each with its own
     menu): the view's menu opens at the right press only when no clickable box lies under the press (the last
     layout's hit: a tab, a body's button, whose menus open at the release), the press is on the stack with nothing
     drawn over it, and nothing took it in that build (`context_take`: a body's block, a field's menu). It is read after
     the stack's strip and body are built, so the body always asks first. Refused: opening it after any body's build
     regardless (it replaced the tab's menu, which opens at the release); a box of the band's own (it would cover the
     body's controls for clicks); the whole body (a right click in a list is the list's, and a body without a menu of
     its own would show the view's in the middle of its content).
4. **Dragging starts from the existing header.** A panel with a title moves by its title. A panel without a title (a
   sidebar) shows no grip: it detaches by its strip on hover (rule 2), its menu or the palette.
5. **Dialogs keep their look.** The header strip, the title and the close cross stay as `dialog_header` drew them. The
   only additions are one small Detach icon and, on a resizable dialog, Maximise (section 2.9), next to the close
   cross, in the same weak colour. Dragging the header also detaches the dialog (it becomes Internal, section 2.6).

The toolkit draws the header of a Dialog, of an Internal window and of an External window. The build procedure draws
only the body. The header is built in two steps: its box is made before the body with empty slots, then the slots are
filled after it. So `view_title` and `view_header_tools` in the body change this frame's header. The title is never
cut (today's `dialog_header` rule).

| Presentation | Where the header is | What it holds, in order |
|---|---|---|
| Dialog | the strip at the dialog's top (today's `dialog_header`) | icon, title, tools, Detach (small, weak), Maximise or Restore (resizable only, section 2.9), the close cross in the corner |
| Internal | the internal window's title strip | icon, title, tools, Re-attach, Detach, Close |
| External, the program's decorations | the header is the window's title bar (rule 2c) | icon, title, tools, Re-attach, Close view, then the window's minimise, maximise, close (close: re-attach) |
| External, the system's decorations | a strip under the system's title bar | icon, title, tools, Re-attach, Close view |
| Panel | none at rest (rule 1). With two views or more in its stack, `tabs_always`, or its zone minimised: the stack's strip (rule 2b) | tabs, "+", moves, tools, then Minimise, Maximise, Close of the stack; a lone panel: the same strip after a rest at its top edge, the body pushed down, until the pointer leaves the panel (rule 2) |

The attachment acts. Each is absent where it does nothing:

| Act | Icon | Does | Absent in |
|---|---|---|---|
| Re-attach | `lucide.UNDO_2` | `view_reattach`: back to its home | its home presentation |
| Detach | `lucide.PICTURE_IN_PICTURE_2` | Internal (from a Dialog or a Panel); External from an Internal window | External |
| Open in a window | `lucide.EXTERNAL_LINK` | External (the menu and the palette) | External |
| Dock left, right, bottom | `lucide.PANEL_LEFT`, `PANEL_RIGHT`, `PANEL_BOTTOM` | Panel at that edge of the frame (the menu and the palette) | at that place |
| Close view | `lucide.X` | ends the view, `VIEW_CANCELLED` | never |

Step 2 makes the Dialog's Detach icon active (it opens the view as an internal window at the dialog's rect). The
header is built in two steps (`view_header_begin`, `view_header_end`): the icon and the title before the body, the
buttons after it. The box of the program's tools is made only when the body calls `view_header_tools`: a header with
no tools has no tools box.

The header's right-click menu is the view's menu of rule 3, in every presentation: each move present only where it
does something (`view_acts`, the palette's set), never inactive.

**The close of an external window is re-attach.** The system's close (the system title bar's close button, Alt+F4,
the compositor, the taskbar's "Close window") acts on the window, not on the view. It brings the view back to its home,
open. Close view, in the header, ends the view. The integrated title bar of an external window shows Re-attach and
Close view, and no third close button. The reasons:

- A system close comes from the window manager. It can come from a gesture made for windows in general (closing all
  windows of a workspace). It must not lose a question or a tool's state.
- The two acts have two buttons with two icons and two tooltips ("Back to the main window", "Close"). No button means
  two things.
- A Dialog, a Panel and an Internal window have no system close. The rule only adds a way back for the External one.

### 2.6 Dragging

The user drags the header (Dialog, Internal, External), the tab (a Panel in a zone of two or more), or the title of a
panel alone in its zone (the program's own title, which the view marks with `view_drag_handle`, step 3). A panel
without a title has no grip (section 2.5, rule 4). The drag starts past `DOCK_DRAG_EM`, as the dock's.

| Dragged | Over what | On release |
|---|---|---|
| a Dialog's header | the owner window | it becomes Internal at once, under the pointer (it leaves the scrim) |
| an Internal window's header | the owner window | it moves |
| an Internal window's header, a Panel's tab | a dock target (the dock's squares, edges and strips) | Panel at that target |
| a Panel's tab | the owner window, no target | Internal, under the pointer, as large as the panel was (at most `DOCK_FLOAT_DEFAULT_EM`) |
| any | outside the owner window | Windows and X11: External, at the pointer's screen position. Wayland: Internal, kept inside the window (no release outside is reported). |
| an External window's header | the owner window's dock targets | Windows and X11: Panel at that target. Wayland: not possible; the Dock menu does it. |
| any | Escape during the drag | nothing moves (the dock's rule) |

The drop targets show in the owner window while something is dragged: the frame's edges, the stacks of the frame's
panels, and the dock spaces built this frame. The content of the frame is not a target for "into", only for its sides.

### 2.7 Ready-made views

`ui.confirm`, `ui.prompt`, the palette, the shortcuts sheet and the setup dialog become views, home Dialog. Their
procedures register the view the first time and clone what they are given.

```odin
// All of them are views of views(): the Views of the window being built.
// A question (pattern A). Its options are cloned: the strings and the lines can be temporary.
confirm_open   :: proc(id: string, o: Confirm_Options, instance := "")
confirm_answer :: proc(id: string, instance := "") -> Confirm_Answer   // .None until answered, once

// A typed answer (pattern B). `field` is the program's, valid until the answer: the secret stays in its memory only.
prompt_open   :: proc(id: string, field: ^Line_Edit, o: Prompt_Options, instance := "")
prompt_answer :: proc(id: string, instance := "") -> Confirm_Answer

// The palette (pattern C), fed by sources (palette.md).
palette_open     :: proc(p: ^Command_Palette, typed := "")
palette_commands :: proc(p: ^Command_Palette, commands: []Command, disabled: []bool, o := Palette_Commands_Options{})
palette_chosen   :: proc(p: ^Command_Palette) -> (c: Palette_Choice, ok: bool)

// The sheet of the keys (pattern D).
shortcuts_sheet_open :: proc(sheet: ^Shortcuts_Sheet, commands: []Command, title := "", version: u64 = 0)

// The setup dialog (pattern E): its events stay setup.update's.
setup.open :: proc(d: ^setup.Dialog, o: setup.Setup_Options, logo: Maybe(setup.Logo) = nil)
```

`Confirm_Answer` stays: `.None`, `.Confirmed`, `.Cancelled`. `confirm_answer` maps `VIEW_CANCELLED` to `.Cancelled`.

The palette reads its Up, Down, Page Up and Page Down keys inside its view. Outside a Dialog, the keys reach it only
while it has the focus (section 3.5).

### 2.8 Names

- `View_Options`, `Views_Options`, `View_Dock_Options`, with the parameter `o`.
- `views_init` and `views_destroy` for the struct that the program owns.
- `view_*` for one view, `views_*` for the set.
- "Presentation": Dialog, Panel, Internal, External. "Internal window" and "external window" in prose.
- "Home": the presentation that re-attach brings back. "Re-attach": back to home, the view open. "Close": the view
  ends.
- "Place": a dock space and an edge. "Dock space": a place where panels dock (the frame, or one of `views_dock`).
- "Owner": the window that opened a view.

### 2.9 A dialog maximised

**Purpose.** A viewer in a dialog (a diagram, a picture, a diff) needs the whole window for a while: to zoom and pan a
diagram, to read a long diff. Every program's resizable dialog has the same need, so the toolkit gives it once.

**What it is.** A resizable view shown as a Dialog has a Maximise button in its header, just left of the close cross
(`lucide.MAXIMIZE_2`; `lucide.MINIMIZE_2` and Restore once maximised). A double click on the header's free part does
the same. Maximised, the dialog takes the window's whole room minus `MODAL_MARGIN_EM` on each side: the margin every
dialog keeps from the window's edges (`modal`'s `hi`). It is computed at each build from the window's size, so a
window resized keeps it filling. Its grips are not built: nothing resizes it. Restore gives back the size it had.

**Decisions.**

1. **The flag is the opening's, not the memory's** (`View_Record.maximised`, reset at each opening). Maximise is a look
   for a while (a diagram to zoom), as the stack's Maximise of a panel (rule 2b) is not remembered either. A viewer
   that opened maximised once and then always opened over the whole window would hide the program each time. A
   program that wants a viewer to open maximised says so at each opening: `view_maximise(vs, id, true)` after
   `view_open`.
2. **The size is not touched.** The maximised size is computed, never written in `View_Record.size`: the remembered
   `dialog=` stays the user's own size, and Restore is only the flag going off. Refused: saving the size before and
   putting it back (two copies of one size, and the grips' memory write would have seen the maximised one).
3. **Only in the Dialog presentation.** The flag goes off when the view leaves it (Detach, a move, a drag). An
   internal window has its own size and its grips; an external window has the system's maximise; a panel has its
   stack's. Detach of a maximised dialog opens the internal window at its default place, not at the window's size.
4. **The words are the labels'** (`View_Labels.maximize`, `restore`): one pair of words for the strip's Maximise and
   the dialog's. Refused: a second pair for dialogs (two words to translate for one act).
5. **Resizable dialogs only get the button.** A dialog sized by its words (a question) has nothing to show bigger.
   `view_maximise` still acts on any dialog: the program knows its view.

**Subtle points.**

- The button is built before the close cross (`modal_end` builds the cross last): the cross stays the last Tab stop.
- The double click is the header's own box (Clickable): its buttons take their own presses. Its first press is the
  start of a drag as before; a drag past `DOCK_DRAG_EM` still detaches a dialog that is not maximised. A maximised
  dialog's header does not detach by a drag: it fills the window, and a floating window of the window's size under the
  pointer would cover the program; Restore first, or Detach.
- A dialog that opens maximised is measured unseen at its maximised size: its first frame drawn is the maximised one.
- `top` (a palette held at a share of the window's height) has no effect while it is maximised: it fills the window.

---

## 3. The state machine of a view

### 3.1 The states

One machine per instance (id and instance). It is a pure value: `view_step(m, event) -> (View_Machine, View_Effects)`.
The toolkit's builds and windows apply the effects. The tests drive the machine with no State and no window.

```odin
View_State :: enum u8 { Closed, Opening, Shown, Moving, Dragged }

View_Machine :: struct {
	state:      View_State,
	as:         View_Presentation,   // Opening, Shown, Dragged: where it is. Moving: where it goes.
	from:       View_Presentation,   // Moving: where it still shows. Dragged: where a cancel puts it back.
	place:      View_Place,          // with .Panel
	home:       View_Presentation,   // View_Options.home: what Reattach goes back to
	home_place: View_Place,
	answer:     Maybe(int),          // Closed: an answer not taken yet
}

View_Event :: struct { kind: View_Event_Kind, as: View_Presentation, place: View_Place, code: int }
View_Effects :: bit_set[View_Effect]
view_step :: proc(m: View_Machine, e: View_Event) -> (View_Machine, View_Effects)
```

The machine does not hold the steps of the first-frame rule (`Modal_Show`, section 3.4): each presentation's builder
measures its own layout and sends `Settled`. `Open` carries the presentation to open in: the caller resolves the
memory, `first` and the home, so `view_step` reads nothing but its arguments. An event that a state does not take
returns the machine unchanged and no effect.

- **Closed**: not built. It can hold an answer that the program did not take.
- **Opening**: built unseen in its presentation until its layout settles. Nothing of it is drawn.
- **Shown**: built and drawn in one presentation.
- **Moving**: it shows in `from`, and it is built unseen in `as`. When `as` settles, `from` goes in the frame where `as`
  shows. The user never sees a frame with the view in neither place, or in both.
- **Dragged**: its header or its tab is held past the threshold. It is drawn as an Internal window under the pointer
  (a Panel's tab, a Dialog), or it is an External window that the system moves.

### 3.2 The events and the transitions

| From | Event | To | Effects |
|---|---|---|---|
| Closed | `Open` (program) | Opening (memory, else `first`, else home) | answer dropped; the focus kept to give back; External: open the window, hidden |
| Opening | `Settled` (two layouts agree, or six builds) | Shown | Dialog: fade in. External: draw, then show. Internal, Panel: show. The focus goes to the view. |
| any but Closed | `Open` again | the same state | raise the window, show the panel's tab, bring the internal window to the front, or focus the dialog |
| Shown | `Present(q, place)` (a button, the Dock menu, `view_present`) | Moving (`from` = current, `as` = q) | remember q; External: open the window, hidden |
| Shown (not home) | `Reattach` (the button, `view_reattach`, External's system close) | Moving (`as` = home, `place` = home place) | remember home |
| Moving | `Settled` | Shown (`as`) | the old presentation goes; the focus moves (section 3.5); box state carried (section 4.4); `moved` called |
| Moving | `Present(r)` or `Reattach` | Moving (`as` = r, or home) | the unfinished target is dropped |
| Shown | `Drag_Start` (header or tab past `DOCK_DRAG_EM`) | Dragged (`as` = Internal, or External for an external window) | a Dialog leaves its scrim; it holds no keys any more |
| Dragged | `Drop(target)` (section 2.6) | Shown (Panel at the target, or Internal where it is) | remember the presentation and the place, at once (same State: no unseen build) |
| Dragged | `Drop_Outside(at)` (Windows, X11) | Moving (`as` = External at `at`) | open the window at `at`, hidden |
| Dragged | `Drag_Cancel` (Escape) | Shown (where it was) | nothing remembered |
| Opening, Shown, Moving, Dragged | `End(code)` (`view_end`) | Closed, answer = code | windows closed; focus given back in the owner |
| Opening, Shown, Moving, Dragged | `User_Close` (Close view, Escape, the scrim, Ctrl+W) | Closed, answer = `VIEW_CANCELLED` | as `End` |
| Opening, Shown, Moving, Dragged | `Program_Close` (`view_close`) | Closed, no answer | as `End`, with no answer |
| Opening (External), Moving (to External) | `Window_Refused` (no surface) | Opening (Internal), or Shown (`from`) | announce "No window: the renderer refused it"; the memory is not changed |
| any but Closed | `Owner_Gone` (its owner window closed) | Closed, answer = `VIEW_CANCELLED` | its windows closed |
| any | `Quit` (`views_destroy`) | Closed, no answer | windows closed; `open` and the presentation remembered (section 3.6) |

Each row is a table test (section 7.4). Rules that the table makes explicit:

- The remembered presentation changes on `Present`, `Reattach` and `Drop`. A close of any kind does not change it.
- The system's close of an external window is `Reattach`, never `User_Close` (section 2.5).
- A move inside one State (Dialog, Internal, Panel, from one to another by a drag) is done in the frame of the drop,
  with no unseen build: the pointer drives it, and a settle lags behind the pointer. A move by a button, or to another
  State, has the unseen builds of Moving.
- A program that closes a view gets no answer. It knows why it closed it.
- A view whose build calls `view_end` is not built again, in this frame or after it.
- A Panel whose dock space is not built in a frame (inspecteur's Services section while another section shows) is not
  built in that frame. It stays Shown and keeps its state.

### 3.3 Views that open views

A view opened inside a view's build has the State of that build as owner. So the kill confirmation opened from
Properties in an external window is a dialog of that window. Opened from Properties in a panel or an internal window,
it is a dialog of the main window. When an external window closes for good (`Owner_Gone`), the views it owns end with
`VIEW_CANCELLED`. When it re-attaches, its views move with it: their owner is the view, and the State follows it.

### 3.4 Animations and the first frame (no flash)

The rule of `Modal_Show` applies to every presentation. Nothing shows until its layout is the same two frames in a
row, or after six builds (`MODAL_MEASURES_MAX`). Each unseen build comes at once (`anim_busy`).

| Presentation | Unseen builds | The first frame shown |
|---|---|---|
| Dialog | today's `Measuring`, `Ready`, `Showing`, `Shown`, with `modal_layout_signature`; none for a dialog of a known size, unless it is not ready (below) | the scrim and the panel fade in together, `MODAL_FADE_MS` (120 ms; `quick`: 70 ms), at once with the animations off. What had the focus loses it on that frame. |
| Internal | built in its floating frame at its place, `transparency = 1` | it shows at once, above the content |
| External | built in the window's State, offscreen: the window is open but not shown. With no remembered size, the window takes the content's natural size (`natural_width`, `modal_content_height`), clamped to the work area. | the first picture is drawn at the settled size, then the window is shown (`host_show`) |
| Panel | built in a floating box of the dock area's size, unseen, in the owner's State | the dock area is inserted and the panel shows in the same frame |
| Moving | built unseen in the new presentation while the old one shows | the old one goes and the new one shows in one frame |
| a drag inside one State | none | the drop's frame |

No presentation has a fade out. A view closes at once.

#### A dialog that appears at once, with its content

The palette (Ctrl+K) stuttered as it opened, at under 4 ms a frame on the GPU: the fault was in the opening's logic,
not in its cost. Measured in classeur, headless, on the GPU: three or four frames unseen (50 to 65 ms at 60 Hz) though
its size was known; a fade that started before its rows had come from the workers (its rows came the frame after);
a late frame that moved the 120 ms fade by a third or a half; and a first unseen frame that redrew the whole window.
Four rules make it come at once and whole:

1. **A dialog of a known size has nothing to measure.** Resizable (its size is the person's or the asked one: width
   and height given) or maximised, its rects do not depend on what is in it. It shows in its first build: its
   layout of that build is the one drawn. A dialog as wide or as tall as what is in it keeps its unseen builds.
   (`Modal_Open.sized`; Showing goes to Shown with no second layout to compare.)
2. **A dialog whose content waits for an answer does not show before it.** The view's build calls `view_not_ready(v)`
   while what it shows is not there (the palette: until the first ranking of the question being asked comes). The
   dialog stays unseen, built each frame, for at most `MODAL_READY_WAIT_MS` (100 ms) from its opening; then it shows
   whatever it holds, so a worker that never answers cannot hide it. A known-size dialog shows in its first build
   unless that build said not ready; then that build is made unseen again (its scrim and panel transparent), as one
   whose layout moved is.
   Refused: `View_Options.ready`, a value fixed at registration that cannot say when an answer came; a procedure the
   toolkit calls to ask, an indirection where the build already knows.
3. **The fade's step is bounded.** A late frame (the scheduler, a busy core) moved `tween` by its whole `dt`: one frame
   of 50 ms was a third of the fade. The dialog's fade advances by at most `MODAL_FADE_STEP_MAX_MS` (25 ms, a frame
   and a half at 60 Hz) a frame (`tween`'s `step_max_ms`). A dialog summoned by a key and left as fast
   (`View_Options.quick`: the palette) fades in over `MODAL_QUICK_FADE_MS` (70 ms) instead of 120 ms.
   The toolkit's own dialogs that a key summons are `quick` from their registration: the palette, the keyboard
   shortcuts' sheet (F1), a question to type (`prompt`: Rename, F2), the file browser (Ctrl+P) and the key recorder.
   A program cannot reach their options, and they open at a key every time. A confirmation keeps 120 ms: it interrupts,
   nobody summons it.
   **A size asked while opening holds the dialog.** `view_size` in the view's build, with a size other than the one
   asked so far, while the dialog has not shown yet: that build is laid out at the old size, so the dialog is made not
   ready (`modal_not_ready`), and the next build, at the new size, is the first drawn. Without it, a known-size
   dialog showed one frame at its old size, and a program kept the last size it asked to work around it (opencode
   native's image viewer, `Image_Viewer.asked`).
4. **What cannot be seen damages nothing.** A box with `transparency` 1 is not drawn: it has no part for the partial
   redraw. Drawn at alpha 0, the scrim of a dialog still unseen was a part the size of the window, and its first
   unseen frame redrew all of it. Its parts come in the frame it shows.

### 3.5 Focus and keyboard

| Case | Dialog | Internal | External | Panel |
|---|---|---|---|---|
| It opens or moves here | its first Tab stop, on the first frame shown | its first stop; it comes to the front | the window is activated (Wayland: `raise_window_token` with the owner's last input token); its first stop | its first stop; its tab shown |
| It closes | the focus goes back to what had it in the owner, unless something else took it since (`modals_settle`) | the same | the owner window is activated, then the same | the same |
| Escape not taken inside | closes the view | closes the view | closes the view | the focus goes back to the content; the panel stays |
| Ctrl+W | closes the view | closes the view | closes the view | closes the view |
| Tab | round the dialog's stops | round the internal window's stops | round the window's stops | through the content and the panels in tree order |
| F6, Shift+F6 | none | to the next or previous area | none | to the next or previous area: the content, each dock area, each internal window |
| The owner's keys | held (`keys_held_by_dialog`) | not held | not held (another window) | not held |
| Its own keys | all of its State's while on top | only while the focus is inside it | its window's | only while the focus is inside it |

Only the Dialog presentation is modal. An internal window, an external window and a panel never block the owner
window, even for a question. The program checks its data when it takes an answer (section 8.1).

**Keys typed right after an opening are the view's, in every presentation, at once.** The rule: every view is built in
the frame it opens. Then the focus its first build gives (a field) is there before the next frame's keys, and nothing
is held.

- A dialog is built at `end_build`, as before.
- An internal window opened after `views_frame` (or with no `views_frame`) is built at `end_build` of that frame:
  `views_build_internals` builds each one not built yet in the build.
- A panel opened after its space was built is built at `end_build` of that frame, unseen, at the place it will have
  (`views_build_late_panels`). Its body's key is its name's alone (`State.key_rooted`), not its parent's: what is under
  it has the same keys in its zone from the next frame, and the focus stays.
- A panel whose place is a dock space of the program's (`views_dock`) that is not built in this frame (a section not
  shown) **waits there**: it is not built, not shown, and no key is held for it; it shows when its space is built
  again (section 8.2, decision 2). A panel whose place is the window's frame, in a window that builds no
  `views_frame`, floats: it is built as an internal window at once (there is no frame to wait for), and goes to the
  frame from the build after the frame's. Every frame shows a view in one place at most. No key waits for a view
  that is not built.
- A view in a window of its own is the only one whose keys wait: between `view_open` and the window's first frame
  shown, the keys reach its owner (the window is hidden). They are held for it (`views_hold_input`, at the owner's
  `begin_build`) and given first to its first shown build, in its window's State (`view_input_arrive`). A refusal ends
  the wait too: the floating window it falls back to gets them. Only an opening as External holds keys.

Refused: holding every view's keys until its build has the focus. The keys a dialog or the page must have at once
(Escape, Enter, Tab) waited, and the bounds (builds, frames) were guesses. Only an
opening holds keys: a move carries the focus (`state_carry`).

When the focus moves with a view (Moving), the focused box's key is carried over: the view's root key is the same in
every State (section 4.4).

`views_hold_keys` answers what programs compute today from their own booleans: inspecteur's `free_keys`
(`view.odin:47`), ocn's `overlay_open` (`commands.odin:138`). These booleans go.

### 3.6 What is remembered, and where

In a `gt:store` file in the program's state folder. The program gives the path in `Views_Options.path`, beside its
other stores (as ocn's `stores.odin:37`). One line per view id, and one per dock space:

```
props	v1 as=external open=0 dialog=58x40 internal=120,80,700,480 window=1180x760 at=212,96,0
sidebar	v1 as=panel open=1 dock=:left:18.5
#mission	v1 dock1 x0.500([*mission/machine] [mission/cpu]) ...
```

| Field | What | Written when |
|---|---|---|
| `as` | the last presentation | `Present`, `Reattach`, `Drop` |
| `open` | it was open when the program quit (`view_was_open`) | `Quit` |
| `dialog` | the dialog's size in ems (today's `Modal_Options.size`) | its grip is let go |
| `internal` | the internal window's rect, logical pixels from its owner's top left | it is let go after a move or a resize |
| `window` | the external window's size, logical pixels | it closes or re-attaches, or its border is let go |
| `at` | the external window's place (`platform.Placement`: left, top, maximized) | as `window`. Windows and X11 only. |
| `dock` | the place (space, edge) and the extent in ems | a drop, `Present`, its handle let go |
| `#<space>` | the dock space's layout (`dock_format`, the views named `id` or `id/instance`) | the dock's `on_save` |

- An absent field means the default of `View_Options`.
- **An instance has a line of its own** (`<id>/<instance>`): its presentation, its place, whether it was open at the
  quit. The sizes stay the id's. At the quit, a line is written for each instance open and removed for each one
  closed (the memory does not grow with every journal ever opened). `view_restored_instances(vs, id)` lists the
  instances open at the last quit: the program reopens each with its own data (a journal per service, a terminal per
  shell), and each opens where it was. Refused: a list of names in the id's line (a name may hold any character but a
  line break; one line per instance keeps each one's place too).
- Instances use their id's line for the sizes. A second external window of one id is placed by the system, not over the first.
  An instance in a dock space's layout is named `id/instance` (ocn's terminals, inspecteur's journals).
- An internal rect is clamped into the owner window when it is used: the window can be smaller.
- A line that does not parse is ignored. Its id gets the defaults.
- This file replaces ocn's `layout.dialogs` and `layout.dock`, inspecteur's `mission.windows` and Mission layout,
  classeur's `inspector.width` and sidebar width, cliche's `history.preview_width`, inspecteur's
  `services.details_height`, and the `size` fields of every dialog.

The store writes on its own thread (`tk_store`), after the changes rest. No disk call runs on the interface thread
after `views_init`.

### 3.7 Tested without a window

- The machine: `view_step` table tests, one per row of section 3.2. No State, no window.
- The memory: `views_format` and `views_parse` round trips, refused texts, a store in memory (`path = ""`).
- The builds: `testkit/session` with a headless host (`Open_Options.headless`). Internal windows and panels are built
  in the owner's State. The External presentation uses a backend for tests: it opens offscreen windows
  (`open_window_offscreen`) with their own State. A flag of this backend says "no drop outside" to test Wayland's rule.
- A program's own test (`session.attach` of an app on `gt:host`, its window offscreen) keeps the program's backend:
  `host.view_windows` opens its windows offscreen when the owner's is (section 4.1, decision 18), and
  `session.view_window` gives each one as a session of the attached app. Refused: a test backend per program (ocn's
  `Aside_Window` built the window's frames by hand, and missed what the host does: the step's close, the hooks given).

---

## 4. External windows

### 4.1 One backend for every program

`ui` cannot open a window: it does not know the renderer's surfaces or the host's loop. The `Views` get a backend:

```odin
// What opens and closes an external window. host.view_windows gives it for a host.Host program.
View_Windows :: struct {
	open:  proc(user: rawptr, o: View_Window_Ask) -> (state: ^State, win: ^platform.Window, handle: rawptr),  // hidden; nil: refused
	show:  proc(user: rawptr, handle: rawptr),
	close: proc(user: rawptr, handle: rawptr),
	no_positions: bool,   // a test's: as Wayland, whatever the system says
	user:  rawptr,
}
View_Window_Ask :: struct { title: string, size: [2]int, at: Maybe([2]int), owner: ^platform.Window, under_children: bool }
```

**Decisions of step 4.**

1. **Never in a build.** An effect that opens or closes a window (`Open_Window`, `Close_Windows`, `Retire_Old` from
   External) only marks the record. `views_windows_step(s)` does the system's part between two frames: the backend
   calls it after the owner's frame, then makes the frames of the windows. A build never enters the system: a window's
   creation would select another State in the middle of the owner's build.
2. **The order of a move to a window (no flash, no frame in two places or none).** The view is built unseen in the
   window's State while the window is hidden; when two layouts in a row agree (or after `MODAL_MEASURES_MAX`), the step
   shows the window and the backend draws its first picture; the owner's next settle sees that picture (the window's
   State built after its show) and the old place goes in that build. For one frame of the owner both show: the old
   place is never gone before the new one is on the screen.
3. **Positions, at run time.** `platform.positions_known(w)` says whether the system gives a window its place and the
   pointer's (Windows, X11, offscreen: yes; Wayland: no). With it: a drag released outside the owner (its position
   outside the client area: the pointer is captured, or grabbed) opens the window there; a drag of an external
   window's header moves it (`move_window`) and shows the owner's dock targets under the pointer. Without it: neither;
   the Detach button and the menu do it, and the system's title bar moves the window.
4. **What follows the view.** Its data (the program's). Its box state: `state_carry(from, from_root, to, to_root)`
   pairs the named boxes of both subtrees by name (a name found twice in either is left alone) and copies the scroll
   and the focus. The presentations wrap the body differently (a dialog's body is its panel's children, an internal
   window's is in `view_body`): a walk side by side would pair the wrong boxes. Refused too: one root key for every
   presentation (`key_from_string(0, ...)`): in a move inside one State both places are built in one frame, and the
   second would take a salted key. An unnamed box keeps no state across a move.
5. **The system's close re-attaches.** The window's close is `view_window_close_asked(state)`: `Reattach`. "Close view"
   in its header, Escape and Ctrl+W close the view.
6. **The parent hint and the least size** (`set_window_owner`, `set_min_size`) are not in step 4: the view's window is a
   window of its own for the system. They come with the first program that needs them (Wren's developer tools).
7. **What is remembered.** `window=` (logical size) when it closes or re-attaches; `at=left,top` (physical, the
   screen's) where `positions_known`.
8. **Its dialogs are its window's.** A view opened during an external view's build has that window's State for owner
   (`view_open`'s rule): a question asked from the window shows over the window.
9. **A view's window follows its owner.** A program that hides its main window (papier hides it instead of closing
   it) makes no frames of it, so no step and no frame of its views' windows: one left on the screen would be frozen.
   `views_windows_follow(owner, shown)` hides the windows of the views it owns when it hides, and shows them again
   when it shows (where they were: Windows and X11 keep the place, Wayland's compositor places them anew). The host's
   `host_hide` and `host_show` call it; the test session's `hide` and `show` too. While its owner is hidden, a window
   whose layout settles is not shown: it waits for the owner. The backend's `hide(user, handle)` takes it off the
   screen, its State kept.
10. **A view's window builds when its owner builds.** The backend makes a frame of each window of a window's views
    after each frame of that window, unconditionally (`host_views_frames`; the test session's `windows_frames`): what
    woke the owner (a sample posted to it) is in the views that show it, wherever they are. A program never wakes a
    view's window by hand (inspecteur's `views_follow` did, believing they built on their own wake only). No cost when
    nothing changed: the owner frames only when something is due, and a view's window redraws what changed (partial
    redraw). Refused: a "data changed" signal per view (the program would have to say which view shows what; the
    owner's frame already says that something changed). Its own input or wake also frames it (`hosts_due` counts it).
    A test pins the rule (`a_view_s_window_builds_with_its_owner`). One exception, the frame of the owner that came
    only from the pointer moving or the wheel (no key, no press, no posted call, no zoom: `pointer_only_build`): it
    changes nothing another window shows, and ocn's main window makes one per pointer move. The view's windows skip it
    unless due on their own (`view_window_due`). A frame with no input at all is not skipped: a wake or an animation
    of the owner may be the program's data changing. Refused: a still frame per view window decided by the program
    (each program would write the same test), and a skip of every frame the view did not ask for (rule 10 again).
11. **A view's window looks like its owner, by itself.** `State.style_owner` (set when the window opens): at the start
    of each of its builds it takes the owner's settings (`style_follow`), the owner's base style (the program's
    `Build_Params.base`, kept as `State.base_style`: font, size, row height, paddings, radius) instead of its backend's,
    and the owner's theme and fonts (pointers: shared). Its families are not copied: `state_families(s)` reads the
    root owner's map, and `set_family` given to a view's window writes there (a copied map was freed twice, ocn).
    Refused: the backend copying the program's `params` hook (its `user` was the backend's, the hook read the wrong
    data) and the step alone (a change showed one frame late, and nothing of the base style followed).
12. **Its zoom keys zoom the program.** Ctrl+=/-/0 and Ctrl+wheel in a view's window set the root owner's zoom (every
    window follows it). Before, the owner's zoom overwrote the window's at the next step: the keys seemed dead. The
    owner's `disable_zoom` holds in it (`State.zoom_keys_off`).
13. **Its chrome follows its owner's window.** The title bar's dark or light is what the program gave its own window
    (`platform.is_dark_title`), taken at the opening and at each step; the host backend gives it the owner Host's
    `background`, `after_input`, `partial_redraw` and `input` at each frame, and the owner's `user` (the hooks read the
    program's data; `Host.owner` says it is a view's window). ocn did this by hand after each change of theme.
14. **`moved` at a direct opening into a window.** Opening → Shown as External calls it as Moving → Shown does: the
    program's native child (made in the owner's window) goes to the view's window either way.
15. **Floating views over a native child.** `view_occluders(v)` and `views_floating_rects(vs, s)`: the rects of the
    internal windows and dialogs shown over the view (or the content), bottom to top, as last laid out. The toolkit
    cannot draw over a web view; the program moves it aside or clips it. Refused: the toolkit moving the child window
    itself (it does not own it, and clipping a child window is per system).
16. **A record stays while its window is open.** `view_close` (and `view_ended`, any sweep) frees the records closed
    with no answer, but the window of one is closed by the next step (decision 1): a record freed before it lost the
    window's handle, the backend's `close` never came, and the window and its State stayed (ocn's /btw panel closed in
    its own window). `views_sweep` keeps a record whose window is open (`w_state`) until the step closed it; that step's
    own sweep frees it. A view opened again in between finds its record and keeps its window.
17. **The program's overlays in every view's window.** A program builds its overlays at the end of its main window's
    build (a context menu, a chip); a menu opened in a view's window is that window's State's (its menus, its
    selection), so it is built only in that window's build. `views_set_window_end(vs, end, user)` sets one hook for the
    program: `end(user, v)` at the end of each build of each view's window, after the view, in its State (`v` the view
    it shows; dialogs come after it, in end_build). Refused: each view's build calling the overlays (a view in a dialog
    or a panel would build them twice, and every view had to know it), and a hook per kind (the overlays are the
    program's, not a view's).
18. **Offscreen with its owner.** A view's window of an offscreen owner (a test's app on `gt:host`) is offscreen too
    (`Open_Options.headless` for a window that is not the first: no surface; the owner's scale). It builds and draws no
    picture: the offscreen renderer has one target, the first window's, which a test reads. Its State keeps its
    owner's clock (`set_clock` of the root owner, read through `style_owner`: a test's `advance` moves a tooltip there
    too). Its show activates it and its close gives the owner the activation back, as a test backend's.

`src/host/views.odin` implements it:

- `host.view_windows(sh: ^Shared) -> ui.View_Windows`: one backend for every window of the program, set once. The ask
  names the owner State (`View_Window_Ask.owner_state`); the backend finds that Host among `Shared.hosts` and makes
  the view's window's frames after its frames. Refused: a backend per owner window (`view_windows(owner)`): a program
  of several owner windows (cliche) had to set it again at the top of each window's build.
- Each external window is a `host.Host` on the program's `Shared`, as ocn's `Detached` is. It has its own `ui.State` and
  its own `render.Surface`.
- Its `build` calls `ui.view_window_build(vs, v)`: the title bar, the body, and the dialogs whose owner is this window.
- Its frames come after its owner's frame, inside the owner's `host_frame`. `hosts_due` and `hosts_wait` count the
  external windows of the hosts they get. The program's loop does not change.
- Its `still` hook is ocn's `detached_still`. Its `params` hook copies the owner's style (section 4.3).
- Its `close_asked` hook sends `Reattach` (section 2.5).

Wren has its own loop. It implements `View_Windows` with its own windows. This is the only part of the views that
Wren writes for itself.

ocn's `detached.odin`, inspecteur's `journal_window.odin` and `mission_window.odin`, and Wren's
`devtools_window.odin` go. Their panels are views, and their windows are this backend's.

### 4.2 Platform limits

| What | Windows | X11 | Wayland |
|---|---|---|---|
| Place a window | `set_placement`: kept and given back | `move_window`, `set_placement`: kept and given back | Not possible. The compositor places it. `at` is not written. |
| A drag released outside the owner | known (the pointer is captured) | known (the pointer is grabbed) | not reported: a drag out stays an Internal window |
| An external window dragged onto the owner's targets | the toolkit reads the pointer during the system's move (`WM_MOVING`) | the toolkit moves the window itself and reads the pointer | not possible: the Dock menu does it |
| Parent hint | owner window (`GWLP_HWNDPARENT`) | `WM_TRANSIENT_FOR` | `xdg_toplevel.set_parent` (in `wl_protocol_linux.odin:305`) |
| Least size | `WM_GETMINMAXINFO` | `WM_NORMAL_HINTS` | `xdg_toplevel.set_min_size` |
| Activation | `SetForegroundWindow` with the input rules | `_NET_ACTIVE_WINDOW` | `xdg-activation-v1` with the owner's last input token |

New platform procedures:

```odin
set_window_owner :: proc(w, owner: ^Window)          // the parent hint of each system
set_min_size     :: proc(w: ^Window, size: [2]int)   // logical pixels
pointer_screen   :: proc(w: ^Window) -> (pos: [2]int, ok: bool)   // during a drag; ok false on Wayland
```

No external window is modal, so xdg-dialog-v1 is not needed.

### 4.3 Scale, theme and style per window

- **Scale**: each window has its own `dpi_scale` (its monitor's), in its `Build_Params`. The sizes in ems follow it.
- **Theme**: one `ui.Theme` for the program (`Shared.theme`). Each window gets `platform.set_dark_title` from it.
- **Style**: zoom, density, rounding, scrollbars, feel, animations, smooth scroll, fonts and families come from the
  owner's State at each frame. This is ocn's `detached_style` (`detached.odin:48`), moved into the toolkit as
  `ui.style_follow(dst, src: ^State)`. inspecteur's `window_params` does the same work; it goes too.
- **Inactive**: an external window that is not the active window is built with `Build_Params.inactive`.

### 4.4 What moves with a view

The program's data does not move: the view holds a pointer.

The State's box state moves: scroll offsets, animations, the focused key. The view's root key is the same in every
State and in every presentation: `key_from_string(0, "###view_<id>/<instance>")`, not derived from its parent's key.
So each box under it has the same key everywhere. A move inside one State keeps all of it. A move to another State
copies the persistent fields of these boxes, and the focus if it was inside (`state_move_subtree(from, to, root)`).

A native child window (ocn's Preview) follows by `View_Options.moved`: the toolkit calls it with the new OS window
after each move to another State. ocn's `preview_move` becomes this procedure.

ocn's terminals read their keys through the host's `input` hook (`detached.odin:178`: `s.only`, `s.focused`). As a
view, a terminal's build reads the events of the State it is built in. The program's keyboard owner (`terms.focused`)
is the terminal whose view has the focus.

---

## 5. Internal windows

- **Its own builder, not the dock's floating panel.** The first plan put an internal window in the frame's dock space
  as a `dock_float`. Refused in step 2: the dock space of the frame is step 3's, an internal window must work in a
  program that never docks, and a dock's floating panel is built inside the program's layout, while an internal window
  is a layer above it. The builder (`views.odin`, `view_internal_build`) takes the dock's look: the `floating` tags, the
  frame with its shadow, `DOCK_FLOAT_MIN_EM`, the corner grip (`resize_grip_paint`). Step 3 docks it through the same
  machine (`Drop` on a dock target), not through `dock_float`.
- Internal windows are built at the end of the build (`end_build`), before the dialogs: above the content and the
  panels, below the dialogs, the menus and the toasts. So in step 2 the content reads its keys before them; step 3's
  `views_frame` builds them before the content (section 6.5).
- It moves by its header. It resizes by its edges and its corners: the side held moves, the other stays (a dialog
  keeps its centre; an internal window does not). It stays inside the owner window; a smaller window moves it in, and
  the remembered rect is not changed.
- Its rect is in logical pixels from the owner's top left (`internal=` in the memory), written when a move or a resize
  is let go. With no rect remembered, it opens where the dialog was (Detach, or a drag of the dialog's header), else
  centred over the program's content (`view_content_area`: the content leaf of the window's `views_frame`, its last
  layout; the whole window without a frame), across and down, as wide as what is in it asks (`width_em` at least), as
  tall as what is in it: its height is taken from its first settled layout. Its unseen builds centre it again once
  its width and its height are known, so the frame that shows it is where it stays. Refused: a fixed share of the
  window's height (VIEW_INTERNAL_TOP, 15 %: it covered the page's heading) and the whole window's centre (it covered
  the panels).
- **Its least width is what is in it on one line** (`view_internal_fit`, each build before the layout: the dialog's
  measure, `natural_width`, kept as `View_Record.inatural`). One that opened with no rect grows to it, centred, during
  its unseen builds (`ifit`); any other rect (the memory's, the dialog's or the panel's it came from) is widened to it;
  the grips stop there. A label the user must read is never cut (the showcase's Colour window cut "Saturation" at
  `width_em` 19). Decided: width only. Its height is the user's, what does not fit is clipped and the program's scroll
  regions scroll: a whole height as a floor would forbid a small window over a long list. Refused: making the body a
  scroll region (a view that fills the window, a terminal, would then be as tall as its content).
  **A content that comes late** (a plugin's first display list, after its runtime started on its own thread): its
  height settled at the first layout, a line of "Starting…", and the content that came was cut under it, buttons
  included. Two rules, as for a dialog: `view_not_ready` holds its unseen builds too (`MODAL_READY_WAIT_MS` at most),
  and `view_refit` asks for its height again: its next build is as tall as what is in it (a height of 0), the one
  after keeps the height that build was laid out at. A window the person resized keeps theirs (`isized`, set by a
  grip's drag; a rect from the memory is not the person's in this run). Refused: an internal window always as tall as
  what is in it, while the person has not resized it: it has no grips then, and a content that grows pushes its
  bottom out of the window. The root of that
  cut was also `form_row`'s label, 34 % of the row with no least: its words on one line are now its least, so the
  measure sees them and the widget gives way.
- Several internal windows float at once. A press on one brings it to the front, before its boxes are built (in front
  this frame). The order is a stamp per view (`View_Record.z`), the topmost last.
- Focus: when it shows, the focus goes to its first stop; what had the focus is kept, and gets it back when it closes,
  if the focus was inside it. Escape and Ctrl+W close it while the focus is inside it. It holds no key of the content.
- Its header holds: the icon, the title, the program's tools, Re-attach (absent at home), Detach into a window
  (inactive without a backend of windows) and Close. Its right-click menu is the header's menu of every presentation (section 2.5,
  rule 3).

The moves of step 2, and why each is built as it is:

| Move | How | Unseen builds |
|---|---|---|
| Dialog → Internal by the Detach icon or `view_present` | `Moving`: the dialog shows; the internal window is built unseen at the dialog's rect until its layout settles; then the dialog goes in the frame the window shows | the internal window's (two or three) |
| Dialog → Internal by a drag of the header past `DOCK_DRAG_EM` | `Drag_Start`: at once an internal window at the dialog's rect, moved by the pointer; the press goes on in its header (`press_hand`); `Drop` at the release | none: the pointer drives it |
| Internal → Dialog by Re-attach | `Moving`: the internal window shows; the dialog is measured unseen (`Modal_Show`); then the window goes in the frame the dialog shows | the dialog's |
| Escape during the header's drag | `Drag_Cancel`: back to the dialog | the dialog's opening |

In a `Moving` frame the body is built twice, once in each place. That is the design's price for no frame with the view
in neither place (section 3.1). The body's boxes have other parents in each place: no key collides. The settle is
decided once per frame for every view, before any is built (`views_settle`), so the old place and the new never show
in one frame.
- Layers, from the bottom: the content, the panels, the internal windows, the dialogs, the menus and popups, the
  toasts.
- It is not modal: no scrim, the content stays usable. Its keys follow the panel's rule (section 6.5).
- It is drawn by the toolkit inside the owner window, so it works the same on every system.
- A double click on its header docks it at its last panel place, else its home place (the dock's rule for floating
  panels).

---

## 6. Panels and dock spaces

### 6.1 The frame provides the dock areas

Programs do not add a dock to their layout. `views_frame` makes the owner window's dock space:

```odin
build :: proc(h: ^host.Host, size: host.Vec2) {
	app := (^App)(h.user)
	if ui.views_frame(&app.views) {
		// the program's content, as today: its title bar, its body, its status bar
	}
	// (views_frame_end: the dialogs, over everything)
}
```

**Decision of step 3: zones, not the dock's tree.** A dock space has four zones, one per edge (left, right, top,
bottom), around its content. Each zone is one stack of views. The first plan laid out a `Dock` (`dock_model.odin`)
with the content as a fixed leaf. Refused: a dock leaf always draws its tab strip and its menu button (rule 1 forbids
both for a lone panel), its drags know only its own tabs (a dialog or an internal window dropped on it must dock), and
it has no fixed leaf. A zone has what the chrome rules need and nothing else. The `Dock` widget stays for a program's
own docking inside a view (Wren's developer tools).

**Splits inside a zone (after papier, before inspecteur's Mission Control).** A zone holds one stack or several, in a
row along its axis: one above the other (`.Y`, the left, right and centre zones by default) or side by side (`.X`,
the top and bottom zones by default). Each stack has its own tabs (none for a lone view: rule 1 holds per stack), and a
`splitter` between two stacks. A view's place says its stack: `View_Place.stack`, a rank in its zone. Refused: a tree
of splits in a zone (any split in any direction). A row along one axis is what Mission Control's eight panels need
(a column at the left, a row at the bottom, a column in the centre), it keeps the targets few, and its memory is a
list of shares. A zone's axis is set by the first split of its one stack; with two stacks or more only that axis
splits it.

**A space without content has a centre zone.** `views_dock(vs, name, {})` (no `content`) lays out a fifth zone,
`.Center`, which fills what the edges leave: its views are the space's main area (Mission Control). A space with
content (the frame, `{content = true}`) has none: its centre is the program's.

`views_frame` does this, in order:

1. It settles the views of its State (`views_settle_all`, once per build): a dialog, an internal window or a panel
   that opens or moves is decided before anything of this frame is built.
2. It lays out the frame's space: the top zone, then the left zone, the content, the right zone, then the bottom
   zone, each zone with its handle (the `splitter` of `split.odin`) on its content side. A zone with no view is not
   built: a window with no panel has its content and one box around it.
3. It builds the panels into their zones, then the internal windows. Their code runs before the content's code, so
   they read keys first (section 6.5). The internal windows are children of the root, after the program's first box:
   they draw over the whole frame.
4. It returns true with the content's box as the parent. The program builds its content there.
5. `views_frame_end` ends the content. The dialogs and the drop targets are `end_build`'s, over everything. A program
   that forgets `views_frame` still gets its dialogs and its internal windows; its panels float until a space is built.

The window's title bar stays the program's, inside the content. A panel at the top goes under it.

**Panels show at once.** A panel's size is its zone's, not its content's: it has no unseen builds. A view that opens
or moves into a zone settles in the settle pass and is built there in the same frame. Its content may measure itself
on the last layout, as in any layout.

### 6.2 Dock spaces of the program

`views_dock(vs, name, o)` is the same machinery inside the content: Mission Control's space (`"mission"`, panels only),
inspecteur's Services section (`"services"`, with the list of services as its content). A view whose home place
names a space docks there. A panel whose space is not built **waits there** (section 8.2, decision 2): not built,
not shown, no key held, shown when its space is built again. Only a panel of the window's frame, in a window with no
`views_frame`, floats (there is no space of the program's to wait for). An earlier rule floated every panel whose
space was not built: inspecteur's Services details, restored at start, then covered Mission Control as a big
floating window while the Services section was not shown. Refused too: floating a panel the person just opened in a
hidden space. The program knows where the view lives and shows its section when it opens it there (inspecteur opens
Services with the service's details); the toolkit cannot tell an explicit opening from a restore. Without `content`,
the centre of the space is its `.Center` zone (empty until a view docks there).

A view docked in a space can be dragged to another space or to the frame's edges. Its home place does not change.

### 6.3 Sizes

- A zone's extent (its width at the left and right, its height at the top and bottom) is the space's: the memory's
  line `#<space>` (`views_space_format`: `v1 left=18.0 right=20.0`, ems), else the first view's `extent_em`, else
  `width_em` (left, right) or `height_em` (top, bottom), else `VIEW_ZONE_EM`.
- The handle between a zone and the content is a `splitter`. The content keeps `DOCK_MIN_EM` at least. Its extent is
  written when the handle is let go (`Splitter_Result.finished`).
- The stacks of a zone share its length: each stack but the last has a share (a fraction of the zone's length), the
  last takes the rest; a handle between two stacks moves the share of the one before it. The space's line keeps each
  zone's axis and shares: `v1 left=18.0 left.axis=y left.shares=0.400,0.350` (`views_space_format(View_Space_Memory)`).
- **A zone's extent in ems or as a share of its space.** A zone sized by a share (`View_Dock_Options.extent_frac`
  for a space's zone, `View_Options.extent_frac` for a view's) is a fraction of its space's width (left, right) or
  height (top, bottom): it follows the window. The user's drag is remembered in the zone's own unit: a share stays a
  share (`left.frac=0.300`), ems stay ems (`left=18.0`). Refused: always ems (Mission Control's zones would stop
  following the window), always shares (a sidebar of a fixed width would grow with the window). The order at first:
  the space's (`View_Dock_Options.extent_frac`, `extent_em`, per edge), then the first view's (`extent_frac`,
  `extent_em`, `width_em`/`height_em`), then `VIEW_ZONE_EM`. A share is laid out as a strict percentage of the space
  (`pct(frac, 1)`): it follows a resize in the same layout, with no frame of lag; the handle converts the drag back
  to a share of the space's last rect. A share stays below 0.95 (the content keeps `DOCK_MIN_EM`).
- **The layout as at first** (`views_space_reset(vs, name)`): the space's zones, axes, shares and tabs shown go back to
  the defaults (its memory line goes), and every open view docked there or homed there goes back to its home place
  (`Reattach`): a view the user moved out comes back, one moved in goes home. Refused: zones only (the panels would
  stay where the user put them, which is not the layout at first).
- The view's own line keeps its place (`dock=<space>:<edge>:<extent>:<stack>`; a line of three fields is stack 0).
- A stack inserted before others moves their ranks up by one: the places of the views there change, and their lines
  are written again. The ranks are made compact (0, 1, 2...) before each insertion, so a zone has at most
  `VIEW_STACKS_MAX` (8) stacks.

### 6.4 Several panels

- Views at different places: each has its stack. A view alone in its stack has no tab strip and no border (section
  2.5, rule 1): its body's first box starts at the stack's top edge.
- Views at the same place (zone and stack): tabs of one stack. The tab strip appears with the second view (or the
  first, `tabs_always`; section 2.5, rule 2b for what it holds). The tab shown is the last
  one opened, docked or clicked. A tab dragged past `DOCK_DRAG_EM` leaves the zone as an internal window under the
  pointer.
- A lone panel moves by its title when the program marks its title box (`view_drag_handle(v, box)`); one without shows
  no grip and moves by its strip on hover (rule 2), its menu or the palette (rule 4).

### 6.4b Drops

While any view of a State is dragged (a dialog's header, an internal window's header, a panel's tab or title), each
space built this frame shows four targets, one square at the middle of each edge (a fifth at its centre, in a space
without content whose centre zone is empty), and the preview of the zone it would land in. Over a stack, a cross of
squares shows at its middle: the centre one makes the view a tab of that stack; the ones on its sides split it, the
view in a new stack before or after it (along the zone's axis; the four sides when the zone has one stack, the side
chosen setting the axis). An edge square of a zone that exists makes the view a tab of its first stack. Released over
a target, the view becomes a Panel there (`Drop`); released elsewhere, it stays an internal window. The targets show
only during a drag.

### 6.5 A panel's keys share the main window

Panels and internal windows are not modal. Their keys and the content's keys come from one event list.

1. **They are built before the content.** So their code reads keys first.
2. **They take keys only while the focus is inside them.** Inside their build, `key_press`, `key_take` and
   `command_pressed` return nothing unless the focused box (of the last build) is under the view's root.
3. **A key that they do not take goes on to the content.** Ctrl+K opens the palette from a focused panel if the
   panel's code does not read Ctrl+K.
4. **Escape that a panel does not take gives the focus back to the content** (section 3.5).

A panel sees the program's state as the last frame left it: the content of this frame is built after it.

Rule 2 is the State's `view_keys_root`: set while a panel's or an internal window's body is built, `key_press` and
`key_take` read nothing unless the focused box is under it. A dialog keeps its own rule (`keys_held_by_dialog`).
Ctrl+W closes a panel or an internal window that has the focus. F6 and Shift+F6 move the focus to the first stop of
the next or the previous area: the content, each stack, each internal window. They are read last, at `end_build`,
only when nothing of the build took them. Refused: reading them in `views_frame`, before the content: a program's own
binding of F6 had to be read before `views_frame` to win. With the toolkit last, a program reads its command keys
where it builds, and its bindings win.

A program asks whether the focus is in a view (`view_has_focus`, `views_focus`) instead of guessing it from the places
it is not (classeur's first form: "not under the content, the top row, the sidebar or the inspector").

**The first start.** `view_restore(vs, id, data, first_start_open)` opens a view at start-up when it was open at the
last quit, or when the memory has no line for it and `first_start_open` asks. Refused: `View_Options.open_at_first_start`
with the toolkit opening it: an opening needs the program's data, which `view_register` does not have. A view opened
in a run gets its line at the quit even when it was closed again, so the user's "closed" holds.

### 6.6 The palette's commands

The views' commands live in memory of their own: `views_commands_update(&vc, vs)` makes them again only when
`views_version` (an opening, a close, a move, a title) or the language changed. The command palette's moves source
follows them by itself ([palette.md](palette.md)); a program no longer adds them to its table.

`views_commands(vs)` gives a `Command` per act of each open view, in the language in use: "Open <title> in a window"
(with a backend of windows), "Float <title>", "Dock
<title> to the left", "... to the right", "... to the bottom", "Re-attach <title>", "Close <title>" (an act that does
nothing where the view is is absent). `views_command_run(vs, c)` does it. `views_version(vs)` changes when an act or
an opening changes the list.

---

## 7. Migration and order of work

### 7.1 Dialogs: the old forms and the new forms

**A question (pattern A).** classeur `src/dialogs.odin:69`.

Old:

```odin
confirm_delete :: proc(app: ^App, paths: []string, ...) { ...; c.open = true }

confirm_build :: proc(app: ^App, em: f32) {           // each frame, after the page
	c := &app.confirm
	if ui.confirm("confirm_delete", &c.open, {title = title, note = note, lines = names, act = act}) == .Confirmed {
		job_add(app, .Delete, c.paths[:])
	}
}
```

New:

```odin
confirm_delete :: proc(app: ^App, paths: []string, ...) {
	...   // the paths kept in app.confirm, as today
	ui.confirm_open("confirm_delete", {title = title, note = note, lines = names, act = act})
}

dialogs_answers :: proc(app: ^App) {                  // each frame, anywhere in the owner's build
	if ui.confirm_answer("confirm_delete") == .Confirmed { job_add(app, .Delete, app.confirm.paths[:]) }
}
```

The title and the note are made once, when the question opens.

**A question with the program's own answers (pattern A, F).** classeur `src/dialogs.odin:102`, the conflict. (The
examples below use the program's shared Views, `app.views`, given to its windows with `set_views`; a program of one
window can use `ui.views()` instead.)

```odin
ui.view_register(&app.views, "conflict", conflict_view, {title = i18n.later("A name is taken"), icon = lucide.FILES, width_em = CONFLICT_WIDTH_EM})

conflict_view :: proc(v: ^ui.View, c: ^Conflict_View) {
	ui.view_title(v, fmt.tprintf(i18n.tr("%s is already in %s"), ...))
	if ui.dialog_body("body") { ... }
	if ui.dialog_buttons("buttons") {
		if ui.button("skip", i18n.tr("Skip")).clicked { ui.view_end(v, int(Conflict.Skip)) }
		...
	}
}

// each frame: the job asks, or it does not (pattern F: the program opens and closes it)
if job := job_asking(app); job != nil && !ui.view_is_open(&app.views, "conflict") {
	app.conflict.job = job
	ui.view_open(&app.views, "conflict", &app.conflict)
} else if job == nil {
	ui.view_close(&app.views, "conflict")
}
if code, ok := ui.view_ended(&app.views, "conflict"); ok {
	job_answer(app.conflict.job, code == ui.VIEW_CANCELLED ? .Cancel : Conflict(code))
}
```

**A typed answer (pattern B).** cliche `src/editor.odin:2133`, the size of the picture.

```odin
ui.view_register(&app.views, "editor_size", editor_size_view, {title = i18n.later("Resize the picture"), icon = lucide.SCALING, width_em = 24})

editor_size_dialog_open :: proc(ed: ^Editor, margins: bool) {
	ed.size_dialog = {margins = margins, ...}   // filled as today
	ui.view_open(&ed.app.views, "editor_size", &ed.size_dialog, instance = ed.name)   // the editor's window is the owner
}

editor_size_view :: proc(v: ^ui.View, d: ^Size_Dialog) {
	if d.margins { ui.view_title(v, i18n.tr("Add margins to the picture")) }
	if ui.dialog_body("size_body") { ... }   // the fields, as today
	if ui.dialog_buttons("size_buttons") {
		if ui.button("size_apply", i18n.tr("Apply"), o = {intent = .Primary}).clicked || ui.key_press(.Return) { ui.view_end(v, 0) }
	}
}

// in the editor's build
if code, ok := ui.view_ended(&app.views, "editor_size", ed.name); ok && code != ui.VIEW_CANCELLED { editor_size_apply(ed) }
```

**A chooser (pattern C).** papier `src/actions.odin:213`.

```odin
ui.palette_commands(&app.palette, ACTIONS[:], disabled, {version = app.can_version})   // the commands source (palette.md)
ui.palette_keys(&app.palette)   // Ctrl+K
if c, ok := ui.palette_chosen(&app.palette); ok {
	if i, is := ui.palette_chosen_command(&app.palette, c); is { action_run(app, Action(i)) }
}
```

**A viewer (pattern D).** papier `src/qr.odin:51`.

```odin
ui.view_register(&app.views, "qr", qr_view, {title = i18n.later("QR code"), icon = lucide.QR_CODE})

qr_view :: proc(v: ^ui.View, q: ^Qr) {
	room := ui.view_room(v)   // the room of this presentation, not app.room: a panel or a window is not the main window
	side := clamp(min(room.x, room.y) * 0.6, ...)
	...
}
```

**A long-lived tool (pattern E).** inspecteur `src/props_view.odin:21`.

- `props_build` becomes `props_view :: proc(v: ^ui.View, pp: ^Props)`.
- The guard `if !app.menu.confirm.open && !app.affinity.open && !ui.menu_any_open() { props_keys(app) }` goes. Its
  keys reach it while it has the focus, in every presentation.
- `pp.size` goes. `free_keys` in `view.odin:47` goes; `ui.views_hold_keys` answers it.

**Wren's request prompts (pattern F).** `fs_shell.odin:134`: the head of the queue opens the view with the request as
data, `instance` = the browser window's id. When the page ends its request, the shell calls `view_close`. The answer
goes to the page when the shell takes it (`view_ended`).

**opencode native's dialogs.** `Dialog`, `App_Context.open`, `DIALOGS_SIZED`, `DIALOG_PREFERRED_EM`,
`DIALOG_MIN_EM`, `dialog_options` and `dialogs_track` go. Each dialog of `views.odin:44`–`61` is a `view_register` at
start-up, with its sizes in its `View_Options`. `overlay_open` is `ui.views_hold_keys` and the menus' state. The
debug assertion of `views.odin:64` goes: a view cannot be built without being open.

### 7.2 Panes and windows: the old forms and the new forms

**A side pane.** classeur `src/view.odin:372`, the sidebar.

Old:

```odin
if app.sidebar {
	ui.next({width = ui.px(app.sidebar_px * scale), height = ui.fill()})
	sidebar_build(app, em)
	ui.splitter("###side_split", .X, &app.sidebar_px, SIDEBAR_MIN_PX, SIDEBAR_MAX_PX, {...})
}
```

New:

```odin
ui.view_register(&app.views, "sidebar", sidebar_view, {title = i18n.later("Places"), icon = lucide.FOLDER_TREE,
	home = .Panel, home_place = {edge = .Left}, extent_em = 16, min_width_em = SIDEBAR_MIN_EM})
ui.view_restore(&app.views, "sidebar", app, first_start_open = true)   // at start-up: open at the first start, then as the user left it
// the command "Show the sidebar": open it, or close it
```

`app.sidebar`, `app.sidebar_px` and their preferences go. The inspector (`inspector.odin:304`) is the same, at the
right: its `ui.Pane` and `inspector.width` go, and it reads the current tab's selection through its data.

**A program's dock.** ocn `src/preview.odin:564`.

- The conversation is the frame's content. `Panel`, `dock_setup`, `DOCK_DEFAULT`, `layout.dock`, `panel_title`,
  `panel_closable` and `dock_save` go.
- `"preview"`, `"stats"` and `"terminal"` (an instance per shell) are views, home Panel at the frame's right. Their
  first default layout is their home places; the memory's `#` line keeps what the user made.
- The strip's look (`strip_look`, `panel_tab`) becomes the build's `view_header_tools` and the theme's.
- `detached.odin` goes: "Open in a window" is the External presentation. `output_view.odin`'s `in_window` path goes.
- `preview_move` becomes the Preview's `moved` procedure.

**A dock space inside a section.** inspecteur `src/mission_control.odin:119`.

```odin
for p in Mission_Panel {
	ui.view_register(&app.views, mission_view_id(p), mission_view, {title = MISSION_TITLES[p], home = .Panel, home_place = {space = "mission"}})
}
// in build_mission, in place of dock_begin ... dock_end
if ui.views_dock(&app.views, "mission", {}) {}
```

`mission_window.odin` and `mission.windows` go. The Mission layout's text goes into the views' memory. The services'
details pane (`services_view.odin:57`) is `"service"` in the space `"services"`, with the list as its content.

**A window of its own.** inspecteur `src/journal_window.odin`.

- `Journal_Window` keeps its `Journal_View`, its manager and its name. It loses its `host.Host` and its title bar code.
- `journal_window_open` becomes `ui.view_open(&app.views, "journal", w, instance = name)`, with
  `home = .Panel, home_place = {edge = .Bottom}, first = .External`.
- Its system close re-attaches it at the bottom of the main window, as tabs per service.

**Wren's developer tools.** `"devtools"`, an instance per browser window, home Panel at the bottom. The
`pane_split` of `devtools.odin:554` and the docking code of `main.odin:1117`–`1129` go; the left, right and bottom
choices are the frame's edges. `devtools_window.odin` goes: External is Wren's `View_Windows`.

### 7.3 Order of work

Each step ships as a toolkit version, and each step leaves every program working.

1. **Toolkit, model and Dialog** (written): `View_Machine`, `view_step` with the whole table, the memory, `Views`,
   `view_register`, `view_open`, `view_close`, `view_ended`, `view_present`, `view_reattach`. Views are built in
   `views_frame_end` through the private modal code (the no-flash rule kept). `confirm`, `prompt`, the palette, the
   sheet, `setup` and `prefs_page.install` are views. `ui.modal`, `Modal_Options`, `dialog_header`, `modal_corner` and
   `Dialog_Header_Options` are private. Panel, Internal and External are states of the machine; their builders are
   stubs that build the view as a Dialog. `examples/showcase` and `examples/fidget` moved. Tests of section 7.4, items
   1, 4, 5 (Dialog), 6 and 7 (Dialog).
2. **Toolkit, Internal** (written): the internal window's builder (section 5), the Detach icon of the dialog active,
   the drag of a dialog's header, the header's right-click menu, the two-step header (no tools box when the program
   gives no tools), the remembered internal rect. Tests of section 7.4, items 1, 3 (Internal), 7 (detach), 10.
3. **Toolkit, Panel** (written): `views_frame` and `views_dock` (zones, section 6.1), the key rule, F6, the hover
   icons, the Dock items of the menu, the palette's commands (`views_commands`), `view_drag_handle`, the drops on a dock
   target and the tab dragged out, the remembered zones (`#<space>`). `examples/docking` and `examples/panes` move to
   views. Tests of section 7.4, items 9, 11, 15, 17.
4. **Toolkit, External** (written): `View_Windows`, `host.view_windows`, the hosts loop (`views_windows_step`),
   `ui.style_follow`, `state_carry`, `moved`, the drags out and in where `platform.positions_known`, the test
   backend (`session.view_windows`). The parent hint and the least size wait (section 4.1, decision 6).
5. **papier**: three dialogs. The smallest program checks the API.
6. **classeur**: its dialogs, its sidebar and its inspector.
7. **cliche**: several owners (editors, history), instances, the preview pane.
8. **inspecteur**: nested views, Mission Control's space, the Services space, the journal.
9. **opencode native**: its dialogs, its sidebar, its dock, `detached.odin`.
10. **Wren**: its dialogs, its developer tools, its own `View_Windows`.

Each program changes in one release: all its dialogs and panes move together.

### 7.4 Tests to write

In `tests/views` (the toolkit). Each test that builds runs with `ODIN_TEST_THREADS=1`.

1. **The machine**: one table test per row of section 3.2.
2. **One build, four presentations**: the same build procedure in each. Its body's boxes exist, its title is in the
   header, the attachment buttons are those of section 2.5.
3. **Re-attach**: from Internal and from External, back to the home presentation and place, the view open, no
   answer. The system's close of an external window does the same. Close view ends it with `VIEW_CANCELLED`.
4. **The answer**: `confirm_open`, a click on the act, then `confirm_answer` is `.Confirmed` once and `.None` after it,
   in each presentation. The test waits for the answer with a bound of frames.
5. **The answer of a close**: Escape (Dialog, Internal, External), Ctrl+W, the owner window closed. Each gives
   `VIEW_CANCELLED` once. `view_close` gives none. Escape in a panel gives the focus to the content and no answer.
6. **The memory**: the presentation, the sizes, the internal rect, the dock place and `open` survive a quit and a start.
   Format and parse round trip. A line that does not parse is ignored.
7. **No flash**: a view whose layout moves for three builds. No frame draws it before it settles. The first frame drawn
   has the final rects. Dialog: the fade starts there. External: the window is not shown before its first picture.
   Panel: the dock area and the panel come in the same frame.
8. **Moving**: Dialog → Internal → Panel → External → Dialog by buttons. In each frame the view is drawn in exactly one
   place. A scroll offset and the focused field survive each move.
9. **Drags**: a dialog's header dragged becomes Internal under the pointer; dropped on an edge target it is a Panel; a
   panel's tab dragged to no target becomes Internal; released outside the window it is External (backend with
   `drop_outside`), or stays Internal (backend without it); Escape during the drag moves nothing.
10. **Internal windows**: two float; a press brings the one under it to the front; neither blocks the content; a
    smaller owner window moves them in without changing the memory.
11. **Keys of a panel and of an internal window**: with the focus in its field, the field takes the letters and the
    content's shortcut still works. With the focus in the content, the view's code gets no key.
12. **Cross-window state**: a view in an external window changes the program's data on a click. The owner's next build
    sees it, and that build comes at once.
13. **Nested**: a confirmation opened from a view in an external window is a dialog of that window. The window's
    re-attach brings both to the main window.
14. **Instances**: two instances of one id in two places. Each has its own answer. They share the memory; in a dock
    space's layout each has its own name.
15. **Dock spaces**: a view homed in a space that is not built is not built, and keeps its state when the space comes
    back.
16. **A window refused**: the backend returns nil. The view opens as Internal, the memory is not changed.
17. **No chrome at rest**: a panel alone in its zone adds no tab strip and no extra border: its body's first box starts
    at the zone's top edge, and no box of the dock is drawn between them. Its strip shows only after a rest at its top
    edge (rule 2), and pushes the body down: no control of the panel over the body's (a strip's arrow in the body keeps
    its click: tests/views/panel_test.odin, a_strip_in_a_panel_s_band_keeps_its_scroll). A pointer that goes down
    across the band to a control near the top (the fold button) moves nothing on its way and clicks that control
    (a_pointer_travelling_to_the_fold_button_moves_nothing). A dialog's header has the title, the Detach icon and the
    close cross, and nothing else.

Each program adds tests for its own views: the answer acts (classeur deletes, inspecteur kills), the pattern F views
close when their request ends, the side panes reopen at start.

---

## 8. Risks and open questions

### 8.1 Risks

- **One frame of latency for answers.** A dialog's answer comes one frame later than today. The toolkit asks that
  frame at once. Test 4 waits for it with a bound.
- **Temporary memory across windows.** Each window frees its temporary allocator at the end of its frame. Data in
  temporary memory, given to `view_open`, is gone when an external window builds. The ready-made views clone what they
  get. A debug build asserts that `data` is not in the temporary allocator's arena.
- **Box state across States.** `state_move_subtree` copies scroll, animations and focus. Each widget that keeps other
  state in its boxes must be checked once. Test 8 covers the common ones.
- **No modality outside the Dialog presentation.** While a question waits in a panel or a window, the thing it asks
  about can change: a file deleted, a tab closed. The program checks its data when it takes the answer. Pattern F
  views already close themselves when their request ends.
- **Panels and internal windows are built before the content.** They see the state that the last frame left. A pane
  that needs this frame's content (classeur's inspector, the current tab's selection made this frame) shows it one
  frame late.
- **Drags across OS windows.** Windows and X11 need the pointer's screen position during a drag and during the
  system's move of a window. Each system's code is new.
- **Native child windows.** ocn's Preview moves its web view by `moved`. A web view that cannot change its parent
  window loses its page.
- **Wren's own loop.** Wren writes `View_Windows` itself. If its loop cannot build an external window after its owner,
  the rule of section 2.3 fails there.

### 8.2 Decisions

1. **What stays content.** papier's list and view, classeur's folder columns, inspecteur's navigation sidebar and ocn's
   conversation stay content. They are not views.
2. **Re-attach to a hidden dock space.** A view homed in a program's dock space (Mission Control, Services) re-attaches
   to that space even when the space is not shown. It is not built until the space shows, then it is built there.
3. **The chrome.** The docking machinery must not invade the screens: section 2.5 gives the five rules.
