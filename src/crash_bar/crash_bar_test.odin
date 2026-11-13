package tk_crash_bar

import "core:strings"
import "core:testing"

// The kind of a report is its file's name; its reason is the header's line, never one of a section.
@(test)
what_the_report_says :: proc(t: ^testing.T) {
	testing.expect_value(t, kind_of("/s/crashes/crash-20261113-170300-4242.txt"), Kind.Crash)
	testing.expect_value(t, kind_of(`C:\s\crashes\unclean-20261113-170300-4242.txt`), Kind.Unclean)
	testing.expect_value(t, kind_of("exit-20261113-170300-4242.txt"), Kind.Exit)
	report := "gt-crash-report: 1\nprogram: fidget\nreason: segmentation fault (an invalid memory access)\n[log]\n  reason: not this\n[end]\n"
	testing.expect_value(t, reason_of(report), "segmentation fault (an invalid memory access)")
	testing.expect_value(t, reason_of("gt-crash-report: 1\n[log]\n  reason: no\n"), "")
}

// The issue's address escapes what a URL cannot hold and stays under GitHub's limit, the report cut on a line.
@(test)
the_issue_holds_the_report :: proc(t: ^testing.T) {
	testing.expect_value(t, url_escape("a b&c=d/é~"), "a%20b%26c%3Dd%2F%C3%A9~")
	short := issue_url("owner/app", "App 1.0 stopped", "program: app\nreason: x\n")
	testing.expect(t, strings.has_prefix(short, "https://github.com/owner/app/issues/new?title=App%201.0%20stopped&body="), short)
	testing.expect(t, strings.contains(short, "reason%3A%20x"), "the report is in the body")
	b := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< 5000 { strings.write_string(&b, "  #00\t0x55D0C0DE1234\tfidget\t0x1234\t?\n") }
	long := issue_url("owner/app", "App stopped", strings.to_string(b))
	testing.expect(t, len(long) <= ISSUE_URL_MAX, "the address fits")
	testing.expect(t, strings.has_suffix(long, url_escape("?\n\n```\n")), "the report is cut after a whole line")
}
