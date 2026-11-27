// The rules of .gitignore files (fsx.Ignore): what git ignores, ignored; what it keeps, kept. What breaks first: a "*"
// that crosses a "/", a pattern with a "/" read as a name, "!" that takes nothing back, a nested file's rules applied
// outside its folder.
package fsx_test

import "core:testing"
import "gt:fsx"

@(test)
gitignore_rules_ignore_what_git_ignores :: proc(t: ^testing.T) {
	ig: fsx.Ignore
	defer fsx.ignore_destroy(&ig)
	fsx.ignore_add(&ig, "", "# a comment\n\nbuild/\n*.log\n!keep.log\n/top.txt\ndocs/*.tmp\n**/cache\nout/**\n\\#hash\nfile[0-9].txt\n")
	fsx.ignore_add(&ig, "src", "gen\n/local.odin\n")
	cases := []struct { rel: string, dir: bool, want: bool }{
		{"build", true, true},
		{"build", false, false},            // (a trailing "/": folders only)
		{"src/build", true, true},           // (no "/" inside: any depth)
		{"a.log", false, true},
		{"deep/b.log", false, true},
		{"keep.log", false, false},          // ("!" takes it back)
		{"top.txt", false, true},
		{"sub/top.txt", false, false},       // (a leading "/": the file's folder only)
		{"docs/x.tmp", false, true},
		{"docs/sub/x.tmp", false, false},    // ("*" takes no "/")
		{"a/b/cache", true, true},
		{"cache", true, true},
		{"out/x/y", false, true},
		{"#hash", false, true},
		{"file7.txt", false, true},
		{"filex.txt", false, false},
		{"src/gen", true, true},
		{"gen", true, false},                // (src's rules stay in src)
		{"src/local.odin", false, true},
		{"src/ui/local.odin", false, false},
		{"readme.md", false, false},
	}
	for c in cases {
		testing.expectf(t, fsx.ignore_match(&ig, c.rel, c.dir) == c.want, "%q (folder %v): ignored should be %v", c.rel, c.dir, c.want)
	}
	testing.expect(t, fsx.glob_match("a?c", "abc"))
	testing.expect(t, !fsx.glob_match("a?c", "a/c"))
	testing.expect(t, fsx.glob_match("[!a]x", "bx"))
	testing.expect(t, !fsx.glob_match("[!a]x", "ax"))
	testing.expect(t, fsx.glob_match("a/**/b", "a/b"))
	testing.expect(t, fsx.glob_match("a/**/b", "a/x/y/b"))
	testing.expect(t, !fsx.glob_match("a/**/b", "a/xb"))
	testing.expect(t, fsx.glob_match("[]a]x", "]x"))
	testing.expect(t, fsx.glob_match("[a-c]x", "bx"))
	testing.expect(t, !fsx.glob_match("[a-c]x", "dx"))
	testing.expect(t, fsx.glob_match("a[", "a["))
	testing.expect(t, fsx.glob_match("*.txt", ".txt"))
	testing.expect(t, !fsx.glob_match("*", "a/b"))
	testing.expect(t, fsx.glob_match("**", "a/b"))
}

// The order of git's rules: the last that matches decides; a deeper file's rules come after its parents' (they win);
// "!" takes back, and a later pattern ignores again; a folder-only rule never ignores a file of that name.
@(test)
gitignore_order_negation_and_nesting :: proc(t: ^testing.T) {
	ig: fsx.Ignore
	defer fsx.ignore_destroy(&ig)
	fsx.ignore_add(&ig, "", "*.log\n!important.log\ndebug*.log\ncache/\n")
	fsx.ignore_add(&ig, "sub", "!keep.log\n/only_here\n")
	fsx.ignore_add(&ig, "sub/deeper", "*\n!*.md\n")
	cases := []struct { rel: string, dir: bool, want: bool }{
		{"a.log", false, true},
		{"important.log", false, false},
		{"debug-important.log", false, true},   // (a later pattern ignores again)
		{"sub/keep.log", false, false},          // (the deeper file takes it back)
		{"keep.log", false, true},               // (sub's "!" stays in sub)
		{"sub/other.log", false, true},
		{"sub/only_here", false, true},
		{"sub/x/only_here", false, false},       // (anchored to sub)
		{"sub/deeper/x.txt", false, true},
		{"sub/deeper/x.md", false, false},
		{"cache", false, false},                 // (a file named as a folder-only rule)
		{"x/cache", true, true},
	}
	for c in cases {
		testing.expectf(t, fsx.ignore_match(&ig, c.rel, c.dir) == c.want, "%q (folder %v): ignored should be %v", c.rel, c.dir, c.want)
	}
}

// A hostile .gitignore cannot stop a walk: a pattern of many stars against a long name answers at once (a matcher that
// backtracks over each star takes the name's length to the power of the stars, and this test's whole time bound).
@(test)
glob_many_stars_stay_linear :: proc(t: ^testing.T) {
	name := make([]u8, 4000, context.temp_allocator)
	for &c in name { c = 'a' }
	testing.expect(t, !fsx.glob_match("*a*a*a*a*a*a*a*a*a*a*a*a*b", string(name)))
	testing.expect(t, !fsx.glob_match("**a**a**a**a**a**a**a**a**b", string(name)))
	testing.expect(t, fsx.glob_match("*a*a*a*a*a*a*a*a*a*a*a*a*a", string(name)))
}
