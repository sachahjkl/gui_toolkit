# setup: a program installs itself

`import setup "gt:setup"` (the package is named `tk_setup`). A program downloaded as one file installs itself for the
user from a dialog of its own: Install, Repair, Upgrade, Update the shortcuts, Uninstall, Open the installed copy. It is
the layer over [desktop.md](desktop.md): the state of the install, what Install and Uninstall do, and the dialog.

```odin
cfg := setup.Config{
	identity = identity(),          // desktop.Identity: names, marks, manifest, uninstall_arguments ("--setup")
	version  = APP_VERSION,
	install_folder = "papier",      // beside the default parent ("": the desktop package's default)
	prepare  = proc(o: ^desktop.Options, user: rawptr) {   // the program's own parts of an install
		o.autostart, o.autostart_arguments = true, "--hidden"
		o.add_to_path = true
	},
}
d: setup.Dialog

// at a start: the dialog when there is something to do, unless the user answered already
if setup.wanted(setup.facts(cfg), APP_VERSION, saved_choice) { setup.open(&d, cfg) }

// each frame
switch setup.dialog(&d, cfg, em, logo) {
case .Installed:       saved_choice = setup.CHOICE_INSTALLED
case .Kept_Standalone: saved_choice = setup.CHOICE_STANDALONE
case .Dismissed:       saved_choice = setup.choice_dismissed(APP_VERSION)
case .Launched:        quit()   // the installed copy runs
case .Uninstalled, .None:
}

// at the end of the process
setup.finish(&d, cfg)
setup.destroy(&d)
```

The dialog says where everything is: the installed program, the menu's entry, the system's record, this copy. A path
that does not fit is cut; the pointer over it shows it whole, and a click on it or on the copy button after it puts it on
the clipboard.

The dialog opens at 36 by 27 em; its edges and its corner resize it (`Dialog.size`, logical pixels: the program may keep it
between starts). What it says scrolls when it is made small; its buttons stay under it.

## A screen of the program's own

A program that wants another layout keeps the `Dialog` and its machinery and draws the rest: it calls `update` each frame
instead of `dialog`, and the actions from its own buttons. The state, what is offered and the work (on the dialog's
thread, the install watched) are the same as in the dialog, which calls the same procedures.

```odin
ev := setup.update(&d, cfg)                       // each frame, open or not: the work that ended, the install read again
if d.open && ui.modal_sized("my_setup", ...) {
	title, badge := setup.headline(d.facts, cfg)   // "Install Classeur", "Not installed"
	words, tone := setup.state_words(d.facts, cfg) // the state in a sentence, its tone
	ui.checkbox("###shortcut", "Shortcut on the Desktop", &d.shortcut)   // d.choices[i]: Config.choices
	if setup.can_uninstall(&d) && my_button("Uninstall") && !setup.busy(&d) { setup.start_uninstall(&d, cfg) }
	how := setup.closing(&d, cfg)                  // Close, Not_Now or Keep_Standalone
	if my_button(...) { ev = setup.close(&d, how) }
	if d.installed != "" && my_button("Open the installed copy") { ev = setup.open_installed(&d) }
	if label := setup.install_label(&d, cfg); label != "" && my_button(label) && !setup.busy(&d) { setup.start_install(&d, cfg) }
}
// Escape or a click outside closed it: setup.close(&d, .Close) gives the event to keep
```

| | |
|---|---|
| `update(d, c) -> Event` | each frame: collects the work that ended, reads the install again when it changed, stops watching once closed |
| `headline(f, c)`, `state_words(f, c)` | what the screen offers and the state in a word; the state in a sentence and its tone |
| `install_label(d, c)` | Install, Repair, Upgrade to …, Go back to …, Replace the installed copy, Update the shortcuts; "": none |
| `can_uninstall(d)`, `busy(d)` | something of an install is there; Install, Uninstall or the picker is at work |
| `closing(d, c) -> Closing` | `Close`, `Not_Now` (an upgrade) or `Keep_Standalone` (no install, another copy) |
| `start_install`, `start_uninstall`, `pick_folder` | the work, on the dialog's thread (nothing while work is out) |
| `open_installed(d)` | starts `Dialog.installed`: `Launched`, the program then ends |
| `close(d, how)` | closes it: `Kept_Standalone`, `Dismissed` (Not now, or no answer), or `None` (nothing to remember) |

`Dialog.facts`, `known` (read once), `shortcut`, `choices`, `folder`, `note` / `note_good`, `installed` and `confirm`
are what such a screen shows and sets.

## The program's look

The dialog is drawn with the theme's widgets. A program with a look of its own gives `Config` three procedures (each may be
nil, and `Config.user` is passed to them):

| | |
|---|---|
| `backdrop(user)` | drawn first in the dialog: what lies behind it (a blur of the window, a dim of its own); nil: the theme's scrim |
| `button(id, label, kind, em, user) -> bool` | each button, `kind` one of `Button_Kind` (`Normal`, `Accent`: what installs or opens, `Danger`: Uninstall); clicked: true |
| `close(id, em, user) -> bool` | the close control in the dialog's top right corner: build its box with `ui.modal_corner(flags, id)`, which gives its place, its size and its radius ([modals](modals.md)); nil: the toolkit's ghost × |

## The states

| State | When | The dialog offers |
|---|---|---|
| `Not_Installed` | nothing of an install | Install, Keep standalone |
| `This_Copy` | the running program is the installed copy, every piece there | Update the shortcuts, Uninstall, Close |
| `Repair` | a launcher, the record, the manifest or a file is missing | Repair, Uninstall |
| `Other_Copy` | a copy is installed elsewhere (`is_upgrade`: an older one) | Replace (Upgrade to …), Uninstall, Keep standalone (Not now) |
| `Removal_Scheduled` | uninstalled while it runs | Close: the file goes when the process ends |
| `Nix_Package` | the copy runs from the Nix store | nothing: Nix installs it |

`wanted(facts, version, choice)` opens the dialog at a start for an upgrade (unless closed for this version), for no
install or one to repair (unless the user chose `standalone`, or closed it for this version); never for a copy of the
Nix store. The program keeps the choice between starts: `CHOICE_INSTALLED`, `CHOICE_STANDALONE`,
`choice_dismissed(version)`.

## Install and Uninstall

`install(cfg, desktop_shortcut)` copies the running program into the install folder (`desktop.files_install`; on NixOS
it is made to run by itself), writes its launchers and `Config.prepare`'s parts (`desktop.install`) and the system's
record (`desktop.record_install`: on Windows, Settings > Apps, whose Uninstall runs `<exe> <uninstall_arguments>`).
`uninstall(cfg)` takes it all away; what the running copy holds (Windows) is in its leftovers, which `finish` hands to
`desktop.cleanup_later` at the end of the process. After an install from another copy, the dialog offers to open the
installed one (`Launched`): the program ends then.

## After an update

When `update.Updater` has put a new program in place of the installed copy (`docs/update.md`), `updated(cfg, version)`
makes the install say it: the install manifest names the new version, and so does the system's record (Settings > Apps on
Windows). For a program that is not the installed copy (a build, an unzipped folder), it does nothing and returns ok.
