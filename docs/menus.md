# Menus (`src/ui/popups.odin`)

A menu is a floating panel of rows, opened at a point (`ctx_menu_open(key, pos)`) or under a rect
(`ctx_menu_open_rect(key, rect)`), and built while it is open:

```odin
if ui.ctx_menu(key) {
    if ui.menu_item("Copy", "Ctrl+C").clicked { ... }
    ui.menu_separator()
    if ui.menu_submenu("Show as") {
        if ui.menu_item("QR code", "Ctrl+Shift+Q").clicked { ... }
    }
}
```

## Its width

A menu is as wide as its widest row: the icon column, the label, the shortcut or a submenu's arrow, and their padding. One
procedure gives a row's width from the same numbers the row is laid out with, in the window's style (the menu's rows
are built in it, whatever the style where `ctx_menu` is called): a theme of a wider `text_pad` makes the menu wider, never a
label cut.

- `ctx_menu(key, width)` and `menu_nested(key, width)`: `width` is a minimum (a drop-down's list is as wide as its button
  at least). A row wider than it widens the menu.
- A menu wider than the window is as wide as the window. Only then is a label cut ("..."), and its row shows the whole label
  as a tooltip when the pointer rests on it (0.5 s).
- A submenu, a nested menu and a `dropdown`'s list follow the same rule.
- The command palette is as wide as the person makes it (`modal_sized`): a line it cuts shows its whole text as a tooltip
  in the same way.

## The menu of a text field

`field_menu(key, target, owner, secret, read_only)` builds the menu of a text field, `key` its menu: Undo, Redo, Cut, Copy,
Paste, Delete and Select all, each with its keys and its Lucide icon, and the search band of every context menu. `target`
is an `Edit_Target`: a `line_edit`'s `^Text_Field` or a `text_edit`'s `^Text_Area`; each edit goes through its own edit
history, as its keys do. `owner` is the field's widget, which a paste's text comes to (`field_paste`). A `secret` is
neither copied nor cut; a field `read_only` is only copied and selected.

`line_edit` and `text_edit` open it on a right press, the field taking the keyboard (their `menu`, true by default; false:
the program has its own).
