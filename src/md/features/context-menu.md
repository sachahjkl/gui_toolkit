# System shell context menu (`gt:desktop`)

Every file manager and file browser needs the system's third-party context-menu actions (on Windows: 7-Zip, Git, VS Code,
Send to, TortoiseGit; on Linux: KIO service menus, Nemo actions, Thunar custom actions) without freezing the interface
when a slow shell extension loads.

## Irreducible constraints

- **Never block the interface thread.** Windows shell extensions load COM DLLs and touch disk during `QueryContextMenu`
  (50–300 ms). The program's menu must open at once with its own commands; the system's items appear when ready.
- **COM STA affinity on Windows.** `IShellFolder::GetUIObjectOf`, `IContextMenu::QueryContextMenu`,
  `IContextMenu2/3::HandleMenuMsg`, `InvokeCommand`, and `Release` must all run on the same STA thread, and the
  `IContextMenu` and `HMENU` must stay alive between query and invoke.
- **Stale answers dropped.** If the user opens another menu before a query returns, the older answer is ignored and its
  shell session is released.
- **No duplicate built-in verbs.** Programs already provide Open, Cut, Copy, Paste, Delete, Rename, and Properties. The
  caller supplies `exclude_verbs` so the toolkit stays generic.

## Design (`desktop.Context_Menu`)

A `desktop.Context_Menu` owns one lazy-started background worker thread (STA on Windows) and one active shell session:

1. **Idle**: no thread until the first `context_menu_query`.
2. **Querying (`serial N`)**: `context_menu_query(m, target, on_ready, user)` increments `serial`, stores the newest
   request (superseding any older queued query), and wakes the worker.
3. **Active (`serial N`)**: the worker builds a plain value tree `[]Context_Item` (labels with `&` mnemonics stripped,
   excluded verbs removed, empty submenus and redundant separators trimmed), keeps the live native session tagged with
   `serial`, and calls `on_ready(user, serial, items)` on the worker thread. The caller posts the result to the UI thread
   (`ui.post`) and owns `items` (`context_items_destroy`).
4. **Invoking**: `context_menu_invoke(m, serial, id, window)` queues invocation on the worker. If `serial` no longer
   matches the active session, the invocation is ignored.
5. **Clearing / Stopping**: `context_menu_clear(m)` releases the held native session when the menu closes;
   `context_menu_destroy(m)` stops and joins the worker.

## Per-system backends

- **Windows (`context_menu_windows.odin`)**: `SHParseDisplayName` + `SHBindToParent` + `IShellFolder::GetUIObjectOf`
  for selected items (or `SHBindToObject` + `CreateViewObject` for folder background), `CreatePopupMenu`,
  `QueryContextMenu`, `IContextMenu2/3::HandleMenuMsg(WM_INITMENUPOPUP)` before walking submenus (bounded by
  `CONTEXT_MENU_MAX_DEPTH`), `GetCommandString(GCS_VERBW)` for canonical verb filtering, and `InvokeCommand` on click.
- **Linux (`context_menu_linux.odin`)**: reads declarative file-manager action files on the worker using `xdg_roots()`
  and `mime_cache`:
  - KIO service menus (`<data>/kio/servicemenus/*.desktop` and `<data>/kservices5/ServiceMenus/*.desktop`),
  - Nemo actions (`<data>/nemo/actions/*.nemo_action`),
  - Thunar custom actions (`<config>/Thunar/uca.xml`).
  Matching actions are expanded into `[]string` command lines stored per item id in the active session and launched via
  `platform.launch_detached` on invoke.
- **Other systems (`context_menu_other.odin`)**: returns an empty slice immediately.

## Refused alternatives

- **Querying on the interface thread**: blocks menu open whenever a slow shell extension loads.
- **One thread per query**: breaks Windows STA lifetime between `QueryContextMenu` and `InvokeCommand`, and pays COM
  initialization on every right click.
- **Showing a native `TrackPopupMenuEx`**: breaks theme consistency, `ui.menu` type-to-filter, and seamless integration
  with the program's own commands.
- **Loading Linux `.so` file-manager plugins (Nautilus/Caja/Thunar C extensions)**: pulls GTK/Qt into a native Wayland
  process and risks crashes.

## Subtle points

- Windows menu labels use `&` for keyboard accelerators (`&Extract Here`, `Cut && Paste`). `context_menu_strip_mnemonic`
  removes single `&` and turns `&&` into `&`.
- Filtering verbs can leave leading, trailing, or consecutive separators, or submenus whose children were all removed.
  `context_items_prune` strips empty submenus first, then trims redundant separators.
- Windows `IContextMenu` items from different parent folders (e.g., flat search results) cannot share one
  `IShellFolder::GetUIObjectOf` call: only paths sharing the first item's parent folder are passed together.
