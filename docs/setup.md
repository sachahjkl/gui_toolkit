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

// at a start, in a build: the dialog when there is something to do, unless the user answered already
if setup.wanted(setup.facts(cfg), APP_VERSION, saved_choice) { setup.open(&d, cfg, logo) }
// a logo made later (from a task's answer): set_logo, never Dialog.logo itself; shown from the next frame
setup.set_logo(&d, logo)
// the vendor signs the header: "By <mark> <identity.vendor>", the name a link to cfg.vendor_url ("": the name alone).
// logo_make makes a mark (or the logo) from a PNG's bytes; logo_destroy frees it before the renderer goes.
mark, _ := setup.logo_make(&renderer, #load("../assets/froment-software-64.png"), {16, 16})
setup.set_vendor_mark(&d, mark)   // or setup.open(&d, cfg, logo, mark); prefs_page.Install.vendor_mark for the page too

// each frame
switch setup.update(&d, cfg) {
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

The dialog is the view `setup.VIEW` ("setup", home Dialog, [views](views.md)): its header ("<name> Setup", the close
cross) is the toolkit's. It opens at 46 by 34 em; its edges and its corner resize it, and the views remember its size.
What it says scrolls when it is made small; its buttons stay under it. Escape, the close cross or a press outside give
`Dismissed` through `update`, unless there is nothing to ask.

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
`Setup_Options.prepare` asked). `Facts.parts` has every part of the integration that is there and runs the installed
copy.

## For me or for everyone

The dialog and the page offer the scope of the install as two radios under "Install for": "Only me" (the person's
profile, no administrator) and "Everyone on this computer" (Program Files or `/opt`, an administrator allows it). Each
says under it what it means on this system. The reasons are in
[src/md/features/install-scope.md](../src/md/features/install-scope.md).

```odin
cfg := setup.Setup_Options{
	// ...
	scopes = {},        // {}: every scope this system has (the default); {.User}: the program stays the person's
}
ok, exe := setup.install(cfg, shortcut, choices, scope = .System)   // what the dialog's Install does with Dialog.scope
```

- `Facts.scope` is the scope of the install that is there (else the one asked: `facts(o, choices, scope)`);
  `Facts.other_scope` says that an install of the other scope is there too; `Facts.system_refusal` says why "Everyone"
  cannot be offered (`desktop.System_Refusal`): NixOS (the Nix package is the install for everyone), or no administrator
  can be asked. The radio is then greyed, and the reason is under it.
- `Dialog.scope` is the scope asked of Install, from the facts when they first come; `scope_set` changes it and reads
  the facts again.
- Install in the other scope than the install that is there is a move: the new install first, then the old one goes
  (`install_label`: "Install for everyone", "Install for me only"). Declined by the administrator, both stay, and
  Uninstall removes both.
- An install for everyone starts the elevated verb once (`--system install <choices>`, from this copy), then writes this
  person's half (the desktop shortcut, the start with the session). Uninstall starts `--system uninstall` from the
  installed program. A test's scratch roots set `machine_root` (and `machine_registry_root` on Windows): the machine
  half is then written in the test's process.
- The install folder field is offered only for "Only me": an install for everyone goes to its system's place.
- `updated` refuses an install for everyone: its update is an elevated step (not written yet). Until then the
  updater of a copy for everyone is `Administered` ([update.md](update.md)): it checks and downloads nothing, and says
  that an administrator updates the program.
- Moving from one scope to the other writes the person's half again once the old install is gone: the desktop
  shortcut, the start with the session and the defaults have the same names in both scopes, and the removal of the old
  install takes them.
- Windows: Uninstall of an install for everyone leaves the program's file until the next restart (the elevated verb
  runs from it). `Facts.at_restart` is then set with `Removal_Scheduled`, and the dialog says "deleted at the next
  restart", not "when this window closes".

## The program's options

`Setup_Options.choices` are the program's own options of an install, a box each; `prepare` receives their values in
their order. A `Choice` tied to parts (`parts = {.File_Manager}`) stands for what the system has: when the install's
facts first come and a program is installed, its box starts on when those parts are all in `Facts.parts`, off
otherwise, whatever its `on` says (`choices_from_facts`). Before an install, the box starts from `on`. A file manager
offers "open folders with it" this way, and the box never claims a part that someone took away.

A PDF reader offers its documents the same way ([desktop.md](desktop.md#a-handler-of-document-types)). It gives the
types whatever the boxes say, so that removal takes them away. The default's box exists only where the system has the
part:

```odin
PDF := [?]desktop.Document_Type{{".pdf", "application/pdf", "PDF Document"}}

choices = {
	{label = i18n.later("Open PDF files with Feuille"), on = true, parts = {.Documents}},
	{label = i18n.later("Make Feuille the default PDF reader"), on = false, parts = {.Default_Documents}},
},
prepare = proc(o: ^desktop.Integration_Options, choices: []bool, user: rawptr) {
	o.document_types = PDF[:]
	o.open_documents, o.default_documents = choices[0], choices[1]
},
```

On Windows the second box has no part (`supported_parts()` lacks `Default_Documents`): give it `parts = {}` there. Its
Install then opens Settings at the program's page, where the person makes it the default.

A task manager offers to take the place of the system's the same way, on Windows only (`Part.Task_Manager`,
[desktop.md](desktop.md#the-default-task-manager)). The part is the machine's: only an install for everyone has it, and
its Debugger runs the installed program in Program Files. Under "Only me" its box is off, and the dialog and the page say
why (`choice_note`, `choice_possible`).

```odin
choices = {
	{label = i18n.later("Open Ctrl+Shift+Esc and Task Manager with the program"), on = false, parts = {.Task_Manager}},
},
prepare = proc(o: ^desktop.Integration_Options, choices: []bool, user: rawptr) { o.task_manager = choices[0] },
```

The Debugger runs the program with taskmgr's path and options. Before anything else of its start, the program calls
`task_manager_start`:

```odin
args := setup.task_manager_start(os.args[1:])   // without taskmgr's path and options: the plain start
```

`task_manager_arguments(args)` is its pure part: the arguments without taskmgr's, and whether they were there. It
restricts an elevated process first (`base.restrict_if_elevated`, [base.md](base.md#restricted-processes)): an
administrator's Ctrl+Shift+Esc starts the program elevated. A restricted process installs, uninstalls and updates
nothing, and is never offered the install: `install`, `uninstall` and `updated` return `restricted_words()`, which the
dialog and the page show in place of their buttons. Its `launch` starts only a program of an administrator's folder.

```odin
choices = {
	{label = i18n.later("Put the program on the PATH"), on = true, parts = {.Path}},
	{label = i18n.later("Open folders with the program"), on = false, parts = {.File_Manager}},
},
prepare = proc(o: ^desktop.Integration_Options, choices: []bool, user: rawptr) {
	o.add_to_path, o.default_file_manager = choices[0], choices[1]
},
```

## The command line

The same options in every program, listed in its table of options (`setup.COMMAND_OPTIONS` for [cli.md](cli.md)):

| Option | What it does |
|---|---|
| `--install` | installs this copy in the scope of the install that is there (else for the user), as the Install button does (`install`), each box tied to parts as the system has it (`choices_from_facts`): no window |
| `--uninstall` | removes the installed copy (`uninstall`, then `remove_later` for what the running copy holds; Windows, an install for everyone: its program goes at the next restart, and the line says it); the user's settings and data stay: no window |
| `--status` | says the state in a word, then a fact a line (the program, for whom (`for: me` or `everyone`), its version, this copy, the menu entry, the start with the session, the PATH, `running: true` when a copy runs: `Setup_Options.running`, the program's single-instance check; `quit: yes` when `--quit` can end it: `Setup_Options.quit`); exit code 0 installed whole (a Nix package too), 1 not installed or to repair (`status_exit`; the words say which): no window |
| `--quit` | asks the copy that runs to end (`Setup_Options.quit`, its single instance: `instance.MESSAGE_QUIT`), then waits until its instance is gone and no process runs the installed copy's file, at most `QUIT_WAIT` (10 s); exit code 0 ended or not running, 1 still running or cannot be asked: no window |
| `--setup` | starts the program with the install shown (`prefs_page.install_open`); Settings > Apps' Uninstall runs it (`Identity.uninstall_arguments = "--setup"`) |
| `--system install <choices>`, `--system uninstall` | the machine half of an install for everyone, which Install and Uninstall start as an administrator (`desktop.machine_install`, `machine_remove`): `<choices>` is one `0` or `1` per box of `Setup_Options.choices`, nothing else; hidden from the help; no window |

A program gives `running` and `quit` from its single instance ([instance.md](instance.md), "The messages every program
understands"): `quit` sends `instance.MESSAGE_QUIT`, and the handler of the copy that runs closes its window. A program
without `quit` answers `quit: no`, and `--quit` fails at once when it runs: an installer then ends its process by other
means (`process.processes_of`, `process.signal_process`).

```odin
cmd, rest := setup.command_of(os.args[1:])
if setup.command_alone(cmd) { cli.exit(setup.command_run(cmd, setup_options(), process.console_write)) }   // install, uninstall, status, quit
// ... the window; then for .Setup: prefs_page.install_open(&app.install)
```

`command_run` says what happened on one line, in English (a script reads it): `<name>: installed: <exe>`, `<name>:
uninstalled (your settings and data stay)`, or why it failed; it ends with a `cli.Exit`, `.Done` or `.Failed`.
`--status` is `status_text` and `status_exit`: `.Done` for an install there whole, `.Failed` for none or one to repair
(its words say which). It reads and writes the disk: call it before the window, never from a frame. These are the
program's one install command line.

## A screen of the program's own

A program that wants another layout keeps the `Dialog` and its machinery and draws the rest in a view of its own: it
calls `start` in place of `open`, `update` each frame, and the actions from its own buttons. The state, what is offered
and the work (on the dialog's thread, the install watched) are the same as in the toolkit's view, which calls the same
procedures.

```odin
setup.start(&d, cfg); ui.view_open(ui.views(), "my_setup", &d)   // opening, in a build
ev := setup.update(&d, cfg)                       // each frame, open or not: the work that ended, the install read again
my_setup_view :: proc(v: ^ui.View, d: ^setup.Dialog) {   // registered with ui.view_register
	title, badge := setup.headline(d.facts, cfg)   // "Install Classeur", "Not installed"
	words, tone := setup.state_words(d.facts, cfg) // the state in a sentence, its tone
	ui.checkbox("###shortcut", "Shortcut on the Desktop", &d.shortcut)   // d.choices[i]: Setup_Options.choices (set from the facts)
	if setup.can_uninstall(&d) && my_button("Uninstall") && !setup.busy(&d) { setup.start_uninstall(&d, cfg) }
	how := setup.closing(&d, cfg)                  // Close, Not_Now or Keep_Standalone
	if my_button(...) { ev = setup.close(&d, how) }
	if d.installed != "" && my_button("Open the installed copy") { ev = setup.open_installed(&d) }
	if label := setup.install_label(&d, cfg); label != "" && my_button(label) && !setup.busy(&d) { setup.start_install(&d, cfg) }
}
// Escape or a click outside ended the view (ui.view_ended): setup.close(&d, .Close) gives the event to keep
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

The dialog is drawn with the theme's widgets. A program with a look of its own gives `Setup_Options` two procedures (each may be
nil, and `Setup_Options.user` is passed to them). The header and its close cross are the views' ([views](views.md)):

| | |
|---|---|
| `backdrop(v, user)` | drawn first in the view, under its header: what lies behind it (a blur of the window, a dim of its own); nil: the theme's scrim. `v.presentation` says where it is: paint a scrim only as `.Dialog` (floating, docked or in a window of its own, it has none) |
| `button(id, label, glyph, intent, em, user) -> bool` | each button: its words, a Lucide glyph and a `ui.Intent` (`Success`: what installs or opens, `Danger`: Uninstall, `Cancel`: what closes, `Primary`: Choose); clicked: true |

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

## An earlier name

A program that changes its name (opencode native becomes Tower) takes over what its earlier name left: its install, its
menu entry and the other parts, and its folders. The reasons are in
[src/md/features/identity-change.md](../src/md/features/identity-change.md).

```odin
// the identity the installs of the earlier name carry, as that program made it
earlier_identity :: proc() -> desktop.Identity {
	id := desktop.identity_of("Froment Software", "Opencode Native", "opencode-native")
	id.manifest_name = "opencode-native-install.txt"
	id.cleanup_name = "opencode-native-uninstall"
	return id
}

cfg := setup.Setup_Options{
	identity       = identity(),                      // Tower's
	install_folder = "Tower",
	program_folder = "FromentSoftware/Tower",         // platform.USER_DIR_SEPARATOR between them
	earlier        = EARLIER[:],                      // {{identity = earlier_identity(), install_folder = "OpencodeNative",
	                                                  //   program_folder = "FromentSoftware/OpencodeNative"}}
	// ...
}

// at the start, before the log, the settings and any window
a := setup.adopt_earlier(cfg)
defer setup.adoption_destroy(&a)
if a.relaunch != "" { setup.launch(a.relaunch, os.args[1:]); return }   // this copy was the earlier install's file
if a.stop { words, _ := setup.adoption_words(a); say(words); return }   // the earlier folders are not moved yet: the next start adopts
// ... the log, the settings, the window; then, once:
if a.news { words, bad := setup.adoption_words(a); toast(words, bad) }
```

- `Earlier` is an identity, its install folder, its folder in its vendor's, and the kinds of folders that move (`{}`: every
  kind but the runtime one). The parts are the program's own (`prepare`): the two identities differ by names and marks.
- `adopt_earlier(o, exe = "", wait = ADOPT_WAIT)` does it once, one start at a time (a lock beside the record; a start
  that finds it held ends: `Busy`). `exe` is the running program for every step (default: this process's file).
- The folders move by one rename per kind, tried again until `wait` ends; a new folder there already stays, and the
  earlier one stays too (`Kept_Both`). A folder that cannot move ends the start (`Failed`, `stop`): the program must
  not make new folders beside the earlier ones. After `ADOPT_TRIES` such starts, the next one copies the folder and
  leaves the earlier one (`Copied`).
- The install moves only from the copy that the update placed in the earlier folder: the new install with the earlier
  one's choices and desktop shortcut, then the earlier one goes by its own marks. Another copy installs nothing; the
  setup offers the install, and the earlier install goes at the first start after it. An install for everyone is an
  administrator's (`Administered`); a copy of the Nix store installs nothing (`Managed`).
- `stop`: an earlier program still runs (`Running`), another start adopts (`Busy`), or a folder did not move
  (`Failed`). The program says the words and ends.
- `adopt_plan(earlier_facts, adopted_there)` is its pure part: what happens to an install.
- A record beside the state folder (`<state>/<program_folder>.adoption`) keeps each step: an interrupted start resumes,
  and each result is said once (`Adoption.news`).
- An earlier program that runs from another place (a Nix package, a portable copy) is not waited for: what it saves
  after the move stays in the earlier folder.
- `adoption_words(a)` says it in the language in use: what moved, a folder left and where, the new console command, a
  taskbar pin to make again (Windows, `desktop.taskbar_pinned`).
- An install several versions late arrives by the earlier feed ([update.md](update.md#a-product-that-changes-its-name)).
