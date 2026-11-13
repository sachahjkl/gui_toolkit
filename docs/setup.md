# setup: a program installs itself

`import setup "gt:setup"` (the package is named `tk_setup`). A program downloaded as one file installs itself for the
user from a dialog of its own: Install, Repair, Upgrade, Update the shortcuts, Uninstall, Open the installed copy. It is
the layer over [desktop.md](desktop.md): the state of the install, what Install and Uninstall do, and the dialog.

```odin
cfg := setup.Setup_Options{
	identity = identity(),          // desktop.Identity: names, marks, manifest, uninstall_arguments ("--setup")
	version  = APP_VERSION,
	install_folder = "papier",      // beside the default parent ("": the desktop package's default)
	prepare  = proc(o: ^desktop.Integration_Options, user: rawptr) {   // the program's own parts of an install
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
case .Launched:        quit()   // then setup.launch(d.installed) once the window and the instance are gone
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

A program does not drive the dialog by hand: `prefs_page.Install` ([prefs_page.md](prefs_page.md), "The installation")
holds it, opens it at a start, keeps the answer and shows the Installation page of the settings. The calls below are
what that object makes.

## The page of the settings

`page(d, o, em) -> Event` draws the same `Dialog` in the flow of a page (the settings' Installation page): the program and
its state as a badge, the state in a sentence, a well that says where everything is (the installed program, the version
installed, this copy and whether it is the installed one, the menu's entry, Settings > Apps on Windows, the start with the
session, the PATH with its console launcher on Windows), before an install its folder and options, what the last action
said, then Install (Repair, Upgrade…), Open the installed copy and Uninstall (a second click does it). The first build
of the page opens the `Dialog` (its facts read on its thread, the places watched); `update` closes it again, with no
event, after a build that did not draw it (`Dialog.in_page`, `page_build`): leaving a page answers nothing.

`Facts.autostart` and `Facts.on_path` say whether the start with the session and the PATH are in place (what
`Setup_Options.prepare` asked).

## The command line

The same options in every program, listed in its table of options (`setup.COMMAND_OPTIONS` for [cli.md](cli.md)):

| Option | What it does |
|---|---|
| `--install` | installs this copy for the user, as the Install button does (`install`): no window |
| `--uninstall` | removes the installed copy (`uninstall`, then `remove_later` for what the running copy holds); the user's settings and data stay: no window |
| `--status` | says the state in a word, then a fact a line (the program, its version, this copy, the menu entry, the start with the session, the PATH, `running: true` when a copy runs: `Setup_Options.running`, the program's single-instance check); exit code 0 installed (a Nix package too), 2 to repair, 1 not installed: no window |
| `--setup` | starts the program with the install shown (`prefs_page.install_open`); Settings > Apps' Uninstall runs it (`Identity.uninstall_arguments = "--setup"`) |

```odin
cmd, rest := setup.command_of(os.args[1:])
if setup.command_alone(cmd) { os.exit(setup.command_run(cmd, setup_options(), process.console_write)) }   // install, uninstall, status
// ... the window; then for .Setup: prefs_page.install_open(&app.install)
```

`command_run` says what happened on one line, in English (a script reads it): `<name>: installed: <exe>`, `<name>:
uninstalled (your settings and data stay)`, or why it failed; its exit code is `COMMAND_DONE` (0) or `COMMAND_FAILED`
(1). `--status` is `status_text` and `status_code` (`COMMAND_REPAIR`, 2, for an install to repair). It reads and writes the disk: call it before the window, never from a frame. The flag of `desktop.parse_cli`
(`Identity.cli_flag`) stays for scripts and tests that want the integration alone.

## A screen of the program's own

A program that wants another layout keeps the `Dialog` and its machinery and draws the rest: it calls `update` each frame
instead of `dialog`, and the actions from its own buttons. The state, what is offered and the work (on the dialog's
thread, the install watched) are the same as in the dialog, which calls the same procedures.

```odin
ev := setup.update(&d, cfg)                       // each frame, open or not: the work that ended, the install read again
if d.open && ui.modal("my_setup", &d.open, {...}) {
	title, badge := setup.headline(d.facts, cfg)   // "Install Classeur", "Not installed"
	words, tone := setup.state_words(d.facts, cfg) // the state in a sentence, its tone
	ui.checkbox("###shortcut", "Shortcut on the Desktop", &d.shortcut)   // d.choices[i]: Setup_Options.choices
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
| `update(d, o) -> Event` | each frame: collects the work that ended, reads the install again when it changed, stops watching once closed |
| `headline(f, o)`, `state_words(f, o)` | what the screen offers and the state in a word; the state in a sentence and its tone |
| `install_label(d, o)` | Install, Repair, Upgrade to …, Go back to …, Replace the installed copy, Update the shortcuts; "": none |
| `can_uninstall(d)`, `busy(d)` | something of an install is there; Install, Uninstall or the picker is at work |
| `closing(d, o) -> Closing` | `Close`, `Not_Now` (an upgrade) or `Keep_Standalone` (no install, another copy) |
| `start_install`, `start_uninstall`, `pick_folder` | the work, on the dialog's thread (nothing while work is out) |
| `open_installed(d)` | `Launched` when there is a `Dialog.installed`: the program ends, then starts it with `launch` once its window is closed and its single instance released (`prefs_page.install_launch` does) |
| `close(d, how)` | closes it: `Kept_Standalone`, `Dismissed` (Not now, or no answer), or `None` (nothing to remember) |

`Dialog.facts`, `known` (read once), `shortcut`, `choices`, `folder`, `note` / `note_good`, `installed` and `confirm`
are what such a screen shows and sets.

## The program's look

The dialog is drawn with the theme's widgets. A program with a look of its own gives `Setup_Options` three procedures (each may be
nil, and `Setup_Options.user` is passed to them):

| | |
|---|---|
| `backdrop(user)` | drawn first in the dialog: what lies behind it (a blur of the window, a dim of its own); nil: the theme's scrim |
| `button(id, label, glyph, intent, em, user) -> bool` | each button: its words, a Lucide glyph and a `ui.Intent` (`Success`: what installs or opens, `Danger`: Uninstall, `Cancel`: what closes, `Primary`: Choose); clicked: true |
| `close(id, em, user) -> bool` | the close control in the dialog's top right corner, built in its header's block: build its box with `ui.modal_corner(flags, id)`, which gives its place, its size and its radius ([modals](modals.md)); nil: the toolkit's close button (`ui.dialog_header`'s `close`) |

## The states

| State | When | The dialog offers |
|---|---|---|
| `Not_Installed` | nothing of an install | Install, Do not install |
| `This_Copy` | the running program is the installed copy, every piece there | Update the shortcuts, Uninstall, Close |
| `Repair` | a launcher, the record, the manifest or a file is missing | Repair, Uninstall |
| `Other_Copy` | a copy is installed elsewhere (`is_upgrade`: an older one) | Replace (Upgrade to …), Uninstall, Do not install (Not now) |
| `Removal_Scheduled` | uninstalled while it runs | Close: the file goes when the process ends |
| `Nix_Package` | the copy runs from the Nix store | nothing: Nix installs it |

`wanted(facts, version, choice)` opens the dialog at a start for an upgrade (unless closed for this version), for no
install or one to repair (unless the user chose `standalone`, or closed it for this version); never for a copy of the
Nix store. The program keeps the choice between starts: `CHOICE_INSTALLED`, `CHOICE_STANDALONE`,
`choice_dismissed(version)`.

## Install and Uninstall

`install(o, desktop_shortcut)` copies the running program into the install folder (`desktop.files_install`; on NixOS
it is made to run by itself), writes its launchers and `Setup_Options.prepare`'s parts (`desktop.install`) and the system's
record (`desktop.record_install`: on Windows, Settings > Apps, whose Uninstall runs `<exe> <uninstall_arguments>`).
`uninstall(o)` takes it all away; what the running copy holds (Windows) is in its leftovers, which `finish` hands to
`desktop.cleanup_later` at the end of the process. After an install from another copy, the dialog offers to open the
installed one (`Launched`): the program ends, then starts it (`prefs_page.install_launch`).

## After an update

When `update.Updater` has put a new program in place of the installed copy (`docs/update.md`), `updated(o, version)`
makes the install say it: the install manifest names the new version, and so does the system's record (Settings > Apps on
Windows). For a program that is not the installed copy (a build, an unzipped folder), it does nothing and returns ok.

`launch(exe, args)` starts a copy of the program (the installed one after an install, the new one after an update or on
Restart), in its folder. Call it once the window is closed and the single instance released, as the process ends. On Windows
it allows the new process the foreground (`AllowSetForegroundWindow`): the click on Restart was this process's input, but its
window is gone, and without that grant the new window would open behind the others with its taskbar button flashing.
