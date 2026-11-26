package tk_setup

import "core:strings"
import "core:testing"
import cli "../cli"

// What the facts of an install make of it.
@(test)
the_state_of_an_install :: proc(t: ^testing.T) {
	testing.expect_value(t, state_of({}), State.Not_Installed)
	testing.expect_value(t, state_of({start_lnk = true}), State.Repair)   // (no program, its launcher left)
	testing.expect_value(t, state_of({desk_lnk = true}), State.Repair)
	testing.expect_value(t, state_of({exe_there = true}), State.Repair)   // (no manifest)
	testing.expect_value(t, state_of({exe_there = true, manifest = true}), State.Other_Copy)
	whole := Facts{exe_there = true, manifest = true, running_it = true, start_lnk = true, record = true}
	testing.expect_value(t, state_of(whole), State.This_Copy)
	missing := whole
	missing.missing = 1
	testing.expect_value(t, state_of(missing), State.Repair)
	no_menu := whole
	no_menu.start_lnk = false
	testing.expect_value(t, state_of(no_menu), State.Repair)
	// a copy of the Nix store: the package's, whatever an earlier install left; an installed copy is still one
	testing.expect_value(t, state_of({from_nix = true}), State.Nix_Package)
	left := Facts{from_nix = true, record = true}
	testing.expect_value(t, state_of(left), State.Nix_Package)
	testing.expect(t, leftover(left), "its icons are left")
	testing.expect(t, !leftover({from_nix = true}), "nothing left")
	testing.expect_value(t, state_of({from_nix = true, exe_there = true, manifest = true}), State.Other_Copy)
}

// A box tied to parts starts from what the install has; a box of no part, or no install, keeps its value.
@(test)
a_choice_of_a_part_shows_the_system_s_truth :: proc(t: ^testing.T) {
	o := Setup_Options{choices = []Choice{{label = "PATH", on = true}, {label = "File manager", on = false, parts = {.File_Manager}}, {label = "Mine", on = true}}}
	choices := []bool{true, false, true}
	choices_from_facts({exe_there = false, parts = {.File_Manager}}, o, choices)
	testing.expect(t, choices[0] && !choices[1] && choices[2], "no install: the values stay")
	choices_from_facts({exe_there = true, parts = {.File_Manager}}, o, choices)
	testing.expect(t, choices[1], "the part is there: on")
	testing.expect(t, choices[0] && choices[2], "a box of no part keeps its value")
	choices_from_facts({exe_there = true, parts = {.Path}}, o, choices)
	testing.expect(t, !choices[1], "the part is not there: off")
	choices_from_facts({exe_there = true}, o, choices[:1])   // (fewer boxes than choices: nothing out of bounds)
}

// Versions compare number by number; one that does not read as a version is never older.
@(test)
versions_compare_by_number :: proc(t: ^testing.T) {
	testing.expect(t, version_older("0.5.6", "0.6.0"))
	testing.expect(t, version_older("0.9.0", "0.10.0"), "by number, not by text")
	testing.expect(t, version_older("1.2", "1.2.1"), "a missing number is 0")
	testing.expect(t, !version_older("0.6.0", "0.6.0"))
	testing.expect(t, !version_older("0.6.1", "0.6.0"))
	testing.expect(t, !version_older("", "0.6.0"))
	testing.expect(t, !version_older("dev", "0.6.0"))
}

// A start opens the dialog for an older install (unless closed for this version), for no install or one to repair (unless
// the user keeps this copy standalone), never for a copy of the Nix store.
@(test)
a_start_offers_the_dialog_when_there_is_something_to_do :: proc(t: ^testing.T) {
	older := Facts{state = .Other_Copy, version = "0.0.1"}
	testing.expect(t, wanted(older, "0.2.0", ""), "older")
	testing.expect(t, wanted(older, "0.2.0", CHOICE_STANDALONE), "standalone was said of no install, not of an older one")
	testing.expect(t, wanted(older, "0.2.0", CHOICE_INSTALLED))
	testing.expect(t, !wanted(older, "0.2.0", choice_dismissed("0.2.0")), "closed for this version")
	testing.expect(t, wanted(older, "0.2.0", choice_dismissed("0.1.0")), "closed for another version")
	testing.expect(t, wanted({state = .Not_Installed}, "0.2.0", ""))
	testing.expect(t, !wanted({state = .Not_Installed}, "0.2.0", CHOICE_STANDALONE))
	testing.expect(t, wanted({state = .Repair}, "0.2.0", CHOICE_INSTALLED))
	testing.expect(t, !wanted({state = .This_Copy}, "0.2.0", ""))
	testing.expect(t, !wanted({state = .Other_Copy, version = "0.3.0"}, "0.2.0", ""), "a newer copy is installed")
	testing.expect(t, !wanted({state = .Not_Installed, from_nix = true}, "0.2.0", ""), "a copy of the Nix store")
	testing.expect(t, !wanted({state = .Not_Installed, machine_copy = true}, "0.2.0", ""), "a task manager's machine copy")
	testing.expect(t, !wanted({state = .Nix_Package}, "0.2.0", ""))
}

// The install's options come out of the arguments, the others stay in their order; the last one given wins.
@(test)
the_command_line_of_the_install :: proc(t: ^testing.T) {
	c, rest := command_of({"--install"})
	testing.expect_value(t, c, Command.Install)
	testing.expect_value(t, len(rest), 0)
	c, rest = command_of({"a.txt", "--uninstall", "--hidden"})
	testing.expect_value(t, c, Command.Uninstall)
	testing.expect_value(t, len(rest), 2)
	testing.expect_value(t, rest[0], "a.txt")
	testing.expect_value(t, rest[1], "--hidden")
	c, rest = command_of({"--setup"})
	testing.expect_value(t, c, Command.Setup)
	testing.expect(t, !command_alone(.Setup) && command_alone(.Status), "--status runs without a window")
	c, rest = command_of({"--status"})
	testing.expect_value(t, c, Command.Status)
	// what scripts read: the state in a word, then "running: true" when a copy runs; 0 installed, 2 to repair, 1 not
	text := status_text({state = .Other_Copy, exe_there = true, exe = "/x/app", version = "1.0"}, {identity = {name = "App"}, version = "1.1"}, true)
	testing.expectf(t, strings.has_prefix(text, "App: installed (another copy)\n"), "%s", text)
	testing.expectf(t, strings.contains(text, "  running: true\n") && strings.contains(text, "  version: 1.0\n"), "%s", text)
	testing.expect_value(t, status_exit(.Other_Copy), cli.Exit.Done)
	testing.expect_value(t, status_exit(.Repair), cli.Exit.Failed)
	testing.expect_value(t, status_exit(.Not_Installed), cli.Exit.Failed)
	c, rest = command_of({"--installer", "install"})
	testing.expect_value(t, c, Command.None)   // (a word, or an option that only begins like one, is not it)
	testing.expect_value(t, len(rest), 2)
	testing.expect_value(t, command_run(.None, {}, nil), cli.Exit.Done)
}

// --quit runs without a window; --status says whether it can end the copy that runs (an installer reads `quit: yes`
// before it asks); a program that does not run is done at once, one that runs and cannot be asked fails at once.
@(test)
the_quit_of_the_copy_that_runs :: proc(t: ^testing.T) {
	c, _ := command_of({"--quit"})
	testing.expect_value(t, c, Command.Quit)
	testing.expect(t, command_alone(.Quit), "--quit runs without a window")
	no := status_text({state = .Not_Installed}, {identity = {name = "App"}, version = "1.1"}, false)
	testing.expectf(t, strings.contains(no, "  quit: no\n"), "%s", no)
	asks := proc() -> bool { return true }
	yes := status_text({state = .Not_Installed}, {identity = {name = "App"}, version = "1.1", quit = asks}, false)
	testing.expectf(t, strings.contains(yes, "  quit: yes\n"), "%s", yes)
	quiet :: proc(text: string) {}
	testing.expect_value(t, command_run(.Quit, {identity = {name = "App"}}, quiet), cli.Exit.Done)
	testing.expect_value(t, command_run(.Quit, {identity = {name = "App"}, running = proc() -> bool { return false }, quit = asks}, quiet), cli.Exit.Done)
	testing.expect_value(t, command_run(.Quit, {identity = {name = "App"}, running = proc() -> bool { return true }}, quiet), cli.Exit.Failed)
	testing.expect_value(t, command_run(.Quit, {identity = {name = "App"}, running = proc() -> bool { return true }, quit = proc() -> bool { return false }}, quiet), cli.Exit.Failed)
}

// What Windows gives a task manager's replacement (taskmgr's path, then its options) is taken away; nothing else is.
@(test)
task_manager_arguments_are_taken_away :: proc(t: ^testing.T) {
	rest, from := task_manager_arguments({`C:\WINDOWS\system32\Taskmgr.exe`, "/4"})
	testing.expect(t, from && len(rest) == 0, "taskmgr's path and its options")
	rest, from = task_manager_arguments({`C:\Windows\System32\taskmgr.exe`, "/7", "/startup"})
	testing.expect(t, from && len(rest) == 0, "the Startup apps' link")
	rest, from = task_manager_arguments({"taskmgr", "/4"})
	testing.expect(t, from && len(rest) == 0, "cmd's taskmgr, as typed")
	rest, from = task_manager_arguments({"TASKMGR"})
	testing.expect(t, from && len(rest) == 0, "any case")
	rest, from = task_manager_arguments({"--section", "services"})
	testing.expect(t, !from && len(rest) == 2, "the program's own")
	rest, from = task_manager_arguments({`C:\tools\nottaskmgr.exe`})
	testing.expect(t, !from && len(rest) == 1, "another program's path")
	rest, from = task_manager_arguments(nil)
	testing.expect(t, !from && len(rest) == 0, "no argument")
}

// --task-manager on|off is the elevated command, alone; without one of its values it is left for the program to refuse.
@(test)
the_task_manager_command :: proc(t: ^testing.T) {
	c, rest := command_of({"--task-manager", "on"})
	testing.expect_value(t, c, Command.Task_Manager_On)
	testing.expect_value(t, len(rest), 0)
	c, rest = command_of({"--task-manager=off"})
	testing.expect_value(t, c, Command.Task_Manager_Off)
	testing.expect(t, command_alone(c), "no window")
	c, rest = command_of({"--task-manager", "maybe"})
	testing.expect_value(t, c, Command.None)
	testing.expect_value(t, len(rest), 2)
	testing.expect(t, !command_alone(.Setup) && !command_alone(.None), "the window's")
}
