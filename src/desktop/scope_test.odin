package tk_desktop

import "core:testing"

// The elevated verb's arguments are a closed set: a word, then one 0 or 1 per box. Anything else is no command.
@(test)
the_elevated_verb_takes_no_path :: proc(t: ^testing.T) {
	args := system_arguments(.Install, {true, false, true})
	testing.expect_value(t, len(args), 3)
	testing.expect_value(t, args[0], SYSTEM_FLAG)
	testing.expect_value(t, args[1], "install")
	testing.expect_value(t, args[2], "101")
	testing.expect_value(t, len(system_arguments(.Uninstall, {true})), 2)
	choices, ok := system_choices("101", 3)
	testing.expect(t, ok && choices[0] && !choices[1] && choices[2])
	_, ok = system_choices("10", 3)
	testing.expect(t, !ok, "one per box")
	_, ok = system_choices("1x1", 3)
	testing.expect(t, !ok, "0 or 1 only")
	_, ok = system_choices("C:\\evil", 8)
	testing.expect(t, !ok, "never a path")
	_, ok = system_choices("", 0)
	testing.expect(t, ok, "a program with no box")
}

// A user install writes every part; a system install's call writes the parts of its half, and the two halves make
// the whole.
@(test)
each_half_writes_its_own_parts :: proc(t: ^testing.T) {
	o := Integration_Options{scope = .User}
	for p in Part { testing.expect(t, touches(&o, p)) }
	o.scope = .System
	machine, person: Parts
	for p in Part {
		o.machine_half = true
		if touches(&o, p) { machine += {p} }
		o.machine_half = false
		if touches(&o, p) { person += {p} }
	}
	testing.expect_value(t, machine & person, Parts{})
	testing.expect_value(t, machine | person, Parts(~Parts{}))
	testing.expect_value(t, machine, machine_parts())
	testing.expect(t, .Desktop_Shortcut in person && .Autostart in person && .File_Manager in person, "the person's choices")
	when ODIN_OS == .Linux || ODIN_OS == .Windows {
		testing.expect(t, .Launcher in machine && .Path in machine, "the menu and the PATH are every account's")
		testing.expect_value(t, supported_scopes(), Scopes{.User, .System})
	}
}

// A system install goes to its system's place for every account, whatever a person chose: a test's machine root
// stands for the machine.
@(test)
a_system_install_goes_to_the_system_s_place :: proc(t: ^testing.T) {
	o := Integration_Options{identity = test_identity(), scope = .System, machine_root = "/scratch/machine", install_dir = "/home/someone/evil"}
	o.identity.name, o.identity.vendor, o.identity.vendor_key = "Papier", "Froment Software", "FromentSoftware"
	when ODIN_OS == .Linux {
		testing.expect_value(t, system_install_dir(&o), "/scratch/machine/opt/FromentSoftware/Papier")
		testing.expect_value(t, default_install_dir(&o), "/scratch/machine/opt/FromentSoftware/Papier")
	}
	when ODIN_OS == .Windows {
		testing.expect_value(t, system_install_dir(&o), "/scratch/machine\\Program Files\\Froment Software\\Papier")
	}
	o.identity.name = "../etc"
	testing.expect_value(t, system_install_dir(&o), "")
}
