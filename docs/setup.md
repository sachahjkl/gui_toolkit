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
