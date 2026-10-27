# Accessibility (screen readers)

The toolkit exposes its windows to assistive technologies (NVDA, Narrator, JAWS, Windows magnifier, voice control):
each frame, the boxes of `ui` become an accessibility tree, and [AccessKit](https://github.com/AccessKit/accesskit)
turns it into UI Automation on Windows. AT-SPI (Linux) and NSAccessibility (macOS) have AccessKit adapters too:
`native/a11y` can wrap them later behind the same API (`platform/a11y_stub.odin` until then).

## Turning it on

The adapter is Rust (AccessKit), linked statically:

```
powershell -NoProfile -File tools\build_a11y.ps1           # -> build\a11y\gt_a11y.lib (pinned crates, --locked)
odin build examples/fidget -define:A11Y_ACCESSKIT=true ...
```

A program that has a Rust static library of its own builds `native/a11y` into it (a dependency: its `gt_a11y_*`
functions stay exported; one Rust library per program, as each carries Rust's standard library) and builds with
`-define:A11Y_ACCESSKIT=true -define:A11Y_NATIVE_LINK=false` (Wren: the `a11y` feature of its assembly crate `native/wren_native`).
The crate is an `rlib` in `Cargo.toml` for that; `tools\build_a11y.ps1` asks for the static library alone (`cargo rustc
--crate-type staticlib`), since rustc skips the profile's fat LTO whenever an `rlib` is among the crate types (4.8 MB
with LTO, 16.9 MB without).

Without the define, `platform.a11y_available()` is false and nothing is built.

## Cost

Nothing is built while no assistive technology reads the window. The first time one asks for the window's tree
(`WM_GETOBJECT`), the adapter answers with a placeholder and wakes the loop (an `.Accessibility` event); the next build
makes the whole tree. After that each build makes the tree again (it is an immediate-mode interface) but only the nodes
that changed go to the adapter (`platform.A11y_Diff`: a hash per node). Once a client asked, the tree is kept up to date
(`UiaClientsAreListening` only tells of clients subscribed to events: one that only asks, as Inspect or a test does,
would read a tree left behind).

At rest nothing happens: the adapter wakes the loop only when a reader asks for the tree or for an action, so a window
a reader has read makes no frame and sends no update while nothing changes (`tests/a11y`, `two_windows_read_apart`).
In a build that makes the tree, `ui.a11y_cost(s)` gives its nodes and the milliseconds spent making it, comparing it
and sending the difference.

The adapter makes each update safe for AccessKit before it sees it: the tree's structure is checked against a mirror
(a node no parent reaches, a missing or duplicate child: refused, `.Invalid`, and the next build sends a whole tree), a
text run always has a value and character lengths that cover it, a text selection that does not point into the node's
runs is dropped. A panic inside AccessKit would leave the window unreadable for good (`.Failed`), never crash the
program.

## What the tree is made of

- A box is a node when it has a role (given by its widget, or by the app) or when it shows text (a static text: role
  `Label`). Layout boxes are not nodes: their nodes hang under the nearest node above them.
- A node's id is its box's `Key` (stable across frames), its bounds its rect (window pixels), its parent the nearest
  node above it. The root is the window (role `Window`).
- Leaf roles (button, check box, tab, menu item, list option, field, slider...) do not expose the boxes inside them:
  their text is their name ("presentational children", as in ARIA).
- The focus is the focused box (or the nearest node above it), the selected item of an open menu, or the item a
  focused container is on (`active_descendant`: a list's selected row).

What the widgets say:

| Widget | Role | Name, states |
|---|---|---|
| `button`, `button_icon` | Button | its text |
| `icon_button` | Button | the id until the app names it (`ui.a11y({name = ...})`) |
| `checkbox`, `radio`, `toggle` | CheckBox, RadioButton, Switch | label, checked |
| `slider`, `range_slider`, `rating` | Slider | value, min, max, step, value text |
| `stepper` | SpinButton | value, min, max |
| `progress` | ProgressIndicator | percent (busy when indeterminate) |
| `segmented` | RadioGroup of RadioButtons | selected, "2 of 3" |
| `chips` | Buttons | toggled |
| `dropdown` | ComboBox | value, expanded, has popup |
| `tabs` | TabList of Tabs | selected, "2 of 3" |
| `line_edit`, `text_edit` | TextInput, MultilineTextInput | value, placeholder, text runs (caret, selection) |
| `list`, `vlist` | ListBox of ListBoxOptions | selected, "3 of 120" (virtual lists too) |
| menus | Menu, MenuItem, MenuItemCheckBox, MenuBar | shortcut, expanded submenus |
| `tooltip` | Tooltip | its text |
| toasts | Alert (warn, bad) / Status | live region: announced when they appear |
| `modal` | Dialog | modal |
| `splitter` | Splitter | size, min, max |
| `accordion` | Button | expanded |
| `card`, `form_row` | Group (named by the title); a form row's label names its widget |
| `title_bar`, `window_buttons` | TitleBar; Buttons (`set_window_button_names` translates them) |
| `status_bar` | Status | |
| `label`, `paragraph` | Label | the text |
| `rich_paragraph` | Label, or Paragraph with Label and Link parts | links: click, focus, URL |

## The app's own boxes

```odin
ui.a11y({role = .Button, name = tr("Back"), shortcut = "Alt+Left"})   // the next box built
if ui.icon_button("back", ICON_BACK).clicked { ... }

b := ui.build_box({.Clickable, .Focusable}, "###tab_7")
ui.a11y_set(b, {role = .Tab, name = title, selected = active, position = 7, set_size = 12})
```

`A11y_Info` holds the role, name, description, value, placeholder, shortcut, role description, toggled, selected,
expanded, read only, required, multiselectable, modal, hidden (left out, with its subtree), busy, numeric value with
min / max / step, level, position and set size, orientation, live region, popup, current, extra actions,
labelled by / described by / controls (keys), active descendant, a graft (a tree of the app's own under the node, see
below), an editable text (`A11y_Text`: text runs for reading by character, word and line, caret and selection), parts
(nodes that are no boxes: the links of a paragraph), `ignore` (not a node: decoration), `no_children`, and `write` (a
callback adding properties of `platform.A11y_Prop_Kind`). `a11y` / `a11y_set` win over the widget's defaults
(`a11y_default`, for widget writers).

`ui.a11y_wanted()` says during a build whether the tree is made at its end: an app with content of its own to describe
does that work only then.

## Requests of assistive technologies

They come back as the same signals as the mouse and keyboard give, in the build after the request:

- Click (Invoke, Toggle, Select), Expand / Collapse: the box's `clicked` (and `pressed`); Expand on an expanded box
  does nothing.
- Focus: the keyboard focus (`set_focus`), scrolled into view. Blur, Scroll into view, Scroll up/down/left/right
  (a page or a few lines), Set scroll offset: scroll boxes.
- Show context menu: `right_clicked`.
- Set value, Replace selected text, Set text selection: `line_edit` and `text_edit`; Set value, Increment,
  Decrement: `slider`, `stepper`, `rating`, `splitter`. A widget of the app asks with `a11y_request(key, action)`
  (`a11y_numeric_request` for numbers).
- The rest (and every request for a grafted tree) waits in `a11y_requests()` for the app.

`a11y_inject` queues a request as if a screen reader had made it (tests, remote control).

## Trees of the app's own (documents)

A box whose `A11y_Info.graft` names a tree (`platform.A11y_Tree_Id`, 16 bytes, not zero) becomes the graft node of
that tree: the app sends the tree itself with `platform.a11y_send(window, &update)` (`update.tree` = the id; the first
update of a tree states its root with `tree_info`). Requests for its nodes come with `request.tree` set, in
`a11y_requests()`. A web browser grafts each page this way.

Send the grafted tree after `end_build` (the graft node must reach the adapter first), only in a build that made the
graft (else the adapter dropped the tree with its graft node: send it whole again). While the view has the keyboard,
`ui.a11y_focus_on(box)` puts the readers' focus on the graft node, so that the grafted tree's own focus counts; until
that tree's first update the adapter keeps the focus on the window's root, then moves it into the tree.

### Node by node

A document that knows what changed (a browser's DOM mutations) does not need to make its whole tree again:
`platform.a11y_diff_patch(&diff, &changed)` takes only the nodes that are new or changed (each complete: all its
properties and its children), sends those the adapter does not have as they are, and forgets the children a node lost
with everything under them (a node moved under another one in the same patch is kept). The first update of a tree is a
whole one (`a11y_diff`, or a patch holding the whole tree); `a11y_diff` and `a11y_diff_patch` can follow each other on
one `A11y_Diff`.

## Several windows

Each window has its adapter (`platform.Window.a11y`), each `ui.State` its tree: give every window its own State and
pass the window in `Build_Params.window`; each is read apart, and its requests come back to it. A State built for
another window than its last one sends that window a whole tree. A tree of the app's own can be grafted in any window
(the graft node and `a11y_send` of that window).

## Known limits

- **Linux and macOS**: stubs (`platform/a11y_stub.odin`); AccessKit has adapters for AT-SPI and NSAccessibility, the
  ABI of `native/a11y` would take them.
- **The toolkit's own tree is made again in each build that makes one** (an immediate-mode interface: there is no
  record of what changed); the diff then sends only what changed. Its cost grows with the nodes of the window, not with
  the changes (`a11y_cost`); a virtual list makes nodes for its visible rows only.
- **Documents grafted by the app** (a web page) are the app's: the toolkit gives the graft, the patches and the
  requests, not the content. What is not there yet in Wren's pages: iframes as subtrees of their own (a frame is a
  node named by its `title`), the caret and the selection in the page's fields and text (no character positions: the
  toolkit's `line_edit` and `text_edit` have them, through `A11y_Text`), the bounds of static text (its element's),
  updates from the DOM's mutations (the page's tree is made again, then compared), and the page's tree in a second
  window (it follows the main window's tab).
- What a reader says (wording, order, browse mode, braille) is checked by a person only.

## The platform layer

`platform/a11y.odin` is independent of the system: roles (`A11y_Role`, AccessKit's list), flags, actions, properties,
and an update writer (`a11y_node`, `a11y_bounds`, `a11y_children`, `a11y_str`, `a11y_num`, `a11y_int`, `a11y_ids`,
`a11y_bytes`, `a11y_floats`, `a11y_selection`, `a11y_graft`); `a11y_diff.odin` turns whole trees into incremental
updates, `a11y_diff_patch` node-by-node ones. `a11y_state(window)` (Off / Full / Incremental), `a11y_send`, `a11y_take_request`. The adapter
(`a11y_accesskit.odin`) answers `WM_GETOBJECT`, follows the window's focus, and checks each update against a mirror of
the tree before AccessKit sees it (an update that would break the tree is refused, `.Invalid`, instead of crashing).

## Tests (no screen reader)

- `tests/a11y` (in CI): the tree of a window of widgets (roles, names, states, values, focus, layout boxes left out),
  incremental updates, requests answered as input.
- With `-define:A11Y_ACCESSKIT=true` (CI too): a hidden window read by a UI Automation client on another thread
  (`tools/uia`): finds the widgets by control type and name, reads states and values, invokes, toggles, sets values,
  selects, focuses, and sees the window answer.
- `tools/uia_probe`: the same client as a command (`dump`, `find`, `wait`, `invoke`, `toggle`, `select`, `expand`,
  `collapse`, `focus`, `set-value`, `focused`) for end-to-end tests of applications.

What only a person can check: what NVDA and Narrator actually say (wording, order, verbosity), browse and focus modes,
braille, the speech when typing in a field.
