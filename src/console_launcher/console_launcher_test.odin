package tk_console_launcher

import "core:testing"

@(private = "file")
expect_plan :: proc(t: ^testing.T, rules: Rules, args: []string, mode: Mode, forwarded: []string) {
	p := decide(args, rules)
	testing.expectf(t, p.mode == mode, "%v: mode %v, want %v", args, p.mode, mode)
	testing.expectf(t, len(p.args) == len(forwarded), "%v: forwarded %v, want %v", args, p.args, forwarded)
	if len(p.args) == len(forwarded) {
		for a, i in forwarded { testing.expectf(t, p.args[i] == a, "%v: forwarded %v, want %v", args, p.args, forwarded) }
	}
}

// A browser's rules: its window by default; its console commands as the first word, its flags anywhere.
@(private = "file")
browser :: proc() -> Rules {
	r, _ := rules_parse("detach", "ctl,help,version,--desktop-integration,--version,-V,--help,-h,-?")
	return r
}

// A clipboard manager's: its commands wait; no argument, its start hidden and its toggle may become the running one.
@(private = "file")
clipboard :: proc() -> Rules {
	r, _ := rules_parse("wait", "(none), toggle, --hidden")
	return r
}

@(test)
a_window_detaches :: proc(t: ^testing.T) {
	r := browser()
	expect_plan(t, r, {}, .Detach, {})
	expect_plan(t, r, {"https://example.org/"}, .Detach, {"https://example.org/"})
	expect_plan(t, r, {"--profile", "p", "--pref", "x=y"}, .Detach, {"--profile", "p", "--pref", "x=y"})
}

@(test)
a_word_counts_first_a_flag_anywhere :: proc(t: ^testing.T) {
	r := browser()
	expect_plan(t, r, {"ctl", "help"}, .Wait, {"ctl", "help"})
	expect_plan(t, r, {"--new-window", "ctl"}, .Detach, {"--new-window", "ctl"})
	expect_plan(t, r, {"./ctl"}, .Detach, {"./ctl"})
	expect_plan(t, r, {"--profile", "p", "--help"}, .Wait, {"--profile", "p", "--help"})
	expect_plan(t, r, {"-?"}, .Wait, {"-?"})
	expect_plan(t, r, {"--desktop-integration=status"}, .Wait, {"--desktop-integration=status"})
	expect_plan(t, r, {"--desktop-integration", "remove"}, .Wait, {"--desktop-integration", "remove"})
	expect_plan(t, r, {"--desktop-integrations"}, .Detach, {"--desktop-integrations"})
}

@(test)
no_argument_can_be_named :: proc(t: ^testing.T) {
	r := clipboard()
	expect_plan(t, r, {}, .Detach, {})
	expect_plan(t, r, {"toggle"}, .Detach, {"toggle"})
	expect_plan(t, r, {"--hidden"}, .Detach, {"--hidden"})
	expect_plan(t, r, {"list", "20"}, .Wait, {"list", "20"})
	expect_plan(t, r, {"set", "picker.theme", "Nord"}, .Wait, {"set", "picker.theme", "Nord"})
}

@(test)
cli_flag_forces_the_wait_and_is_not_forwarded :: proc(t: ^testing.T) {
	expect_plan(t, browser(), {"--cli"}, .Wait, {})
	expect_plan(t, browser(), {"https://example.org/", "--cli"}, .Wait, {"https://example.org/"})
	expect_plan(t, clipboard(), {"--cli", "toggle"}, .Wait, {"toggle"})
}

@(test)
rules_read_from_the_build :: proc(t: ^testing.T) {
	_, ok := rules_parse("sometimes", "")
	testing.expect(t, !ok, "a default that is neither")
	r, rok := rules_parse("wait", " a , ,-b ")
	testing.expect(t, rok)
	testing.expect_value(t, len(r.others), 2)
}

@(test)
target_is_the_exe_beside_the_com :: proc(t: ^testing.T) {
	p, ok := target_of(`C:\Users\a b\Programs\Papier\papier.com`)
	testing.expect(t, ok)
	testing.expect_value(t, p, `C:\Users\a b\Programs\Papier\papier.exe`)
	p, ok = target_of(`D:\x\PAPIER.COM`)
	testing.expect(t, ok)
	testing.expect_value(t, p, `D:\x\PAPIER.exe`)
	_, ok = target_of(`C:\x\papier.exe`)
	testing.expect(t, !ok, "an .exe would start itself")
	_, ok = target_of(`C:\x.y\papier`)
	testing.expect(t, !ok, "no extension")
	_, ok = target_of(`C:\x\.com`)
	testing.expect(t, !ok, "no name")
}
