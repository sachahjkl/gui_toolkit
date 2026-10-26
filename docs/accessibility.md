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
`-define:A11Y_ACCESSKIT=true -define:A11Y_NATIVE_LINK=false` (Wren: the `a11y` feature of `native/media`).

Without the define, `platform.a11y_available()` is false and nothing is built.

## Cost

Nothing is built while no assistive technology reads the window. The first time one asks for the window's tree
(`WM_GETOBJECT`), the adapter answers with a placeholder and wakes the loop (an `.Accessibility` event); the next build
makes the whole tree. After that each build makes the tree again (it is an immediate-mode interface) but only the nodes
that changed go to the adapter (`platform.A11y_Diff`: a hash per node). Once a client asked, the tree is kept up to date
(`UiaClientsAreListening` only tells of clients subscribed to events: one that only asks, as Inspect or a test does,
would read a tree left behind).

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

## The platform layer

`platform/a11y.odin` is independent of the system: roles (`A11y_Role`, AccessKit's list), flags, actions, properties,
and an update writer (`a11y_node`, `a11y_bounds`, `a11y_children`, `a11y_str`, `a11y_num`, `a11y_int`, `a11y_ids`,
`a11y_bytes`, `a11y_floats`, `a11y_selection`, `a11y_graft`); `a11y_diff.odin` turns whole trees into incremental
updates. `a11y_state(window)` (Off / Full / Incremental), `a11y_send`, `a11y_take_request`. The adapter
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
