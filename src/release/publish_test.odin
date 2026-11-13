package tk_release

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "../testkit"
import toolbox "../toolbox"

@(test)
the_next_version_follows_the_last :: proc(t: ^testing.T) {
	v, ok := version_next("0.247.0", "patch")
	testing.expect(t, ok && v == "0.247.1", v)
	v, ok = version_next("0.247.3", "minor")
	testing.expect(t, ok && v == "0.248.0", v)
	v, ok = version_next("0.247.3", "major")
	testing.expect(t, ok && v == "1.0.0", v)
	v, ok = version_next("0.247.3", "v0.250.0")
	testing.expect(t, ok && v == "0.250.0", v)
	_, ok = version_next("0.247.3", "0.247.3")
	testing.expect(t, !ok, "a version already published")
	_, ok = version_next("0.247.3", "next")
	testing.expect(t, !ok, "a word it does not know")
	v, ok = version_next("", "minor")
	testing.expect(t, ok && v == "0.1.0", v)
	testing.expect_value(t, version_highest("v0.9.0\nv0.10.0\nv0.10.0-rc\nnot-a-tag\nv0.2.1\n"), "0.10.0")
}

@(private = "file")
Race :: struct {
	ours:   string, // the clone that releases
	other:  string, // a second clone, which publishes while the first one is releasing
	writes: int,
}

@(private = "file")
git_in :: proc(dir: string, args: ..string) -> bool {
	command := make([dynamic]string, context.temp_allocator)
	append(&command, "git", "-C", dir, "-c", "user.name=test", "-c", "user.email=test@example.invalid")
	append(&command, ..args)
	return toolbox.run(command[:])
}

// Another session publishes v0.2.0 between our fetch and our push. The atomic push is refused, nothing of ours goes
// out, and the release starts again on top of theirs with the next number: no tag without its commit, no lost commit.
@(test)
a_release_raced_by_another_takes_the_next_number :: proc(t: ^testing.T) {
	root := testkit.temp_folder(t)
	origin := fmt.tprintf("%s/origin.git", root)
	ours := fmt.tprintf("%s/ours", root)
	theirs := fmt.tprintf("%s/theirs", root)
	if !toolbox.run({"git", "init", "-q", "--bare", "-b", "master", origin}) { testing.fail_now(t, "git init") }
	seed := fmt.tprintf("%s/seed", root)
	testing.expect(t, toolbox.run({"git", "clone", "-q", origin, seed}))
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/VERSION", seed), "0.1.0\n") == nil)
	testing.expect(t, git_in(seed, "add", "-A") && git_in(seed, "commit", "-q", "-m", "first") && git_in(seed, "tag", "-a", "v0.1.0", "-m", "v0.1.0"))
	testing.expect(t, git_in(seed, "push", "-q", "origin", "master", "v0.1.0"))
	testing.expect(t, toolbox.run({"git", "clone", "-q", origin, ours}))
	testing.expect(t, toolbox.run({"git", "clone", "-q", origin, theirs}))
	for dir in ([]string{ours, theirs}) {
		testing.expect(t, git_in(dir, "config", "user.name", "test") && git_in(dir, "config", "user.email", "test@example.invalid"))
	}

	race := Race{ours = ours, other = theirs}
	write :: proc(version: string, user: rawptr) -> (paths: []string, subject: string, why: string) {
		r := (^Race)(user)
		r.writes += 1
		if r.writes == 1 {
			// (the other session publishes now, after our fetch)
			_ = os.write_entire_file(fmt.tprintf("%s/VERSION", r.other), "0.2.0\n")
			_ = git_in(r.other, "commit", "-q", "-am", "0.2.0") && git_in(r.other, "tag", "-a", "v0.2.0", "-m", "v0.2.0")
			_ = git_in(r.other, "push", "-q", "--atomic", "origin", "HEAD:refs/heads/master", "refs/tags/v0.2.0")
		}
		_ = os.write_entire_file(fmt.tprintf("%s/VERSION", r.ours), fmt.tprintf("%s\n", version))
		p := make([]string, 1, context.temp_allocator)
		p[0] = "VERSION"
		return p, version, ""
	}
	version, why := publish({dir = ours, asked = "minor", write = write, user = &race})
	testing.expect_value(t, why, "")
	testing.expect_value(t, version, "0.3.0")
	testing.expect_value(t, race.writes, 2)

	tags, _ := toolbox.capture({"git", "-C", origin, "tag", "--list"})
	testing.expect_value(t, version_highest(tags), "0.3.0")
	testing.expect(t, !strings.contains(tags, "v0.2.0\nv0.2.0"), "one v0.2.0")
	log, _ := toolbox.capture({"git", "-C", origin, "log", "--format=%s", "master"})
	testing.expect_value(t, strings.trim_space(log), "0.3.0\n0.2.0\nfirst")
	tagged, _ := toolbox.capture({"git", "-C", origin, "rev-list", "-n", "1", "v0.3.0"})
	head, _ := toolbox.capture({"git", "-C", origin, "rev-parse", "master"})
	testing.expect_value(t, strings.trim_space(tagged), strings.trim_space(head))
}

// A checkout with something not committed publishes nothing.
@(test)
a_dirty_checkout_does_not_publish :: proc(t: ^testing.T) {
	root := testkit.temp_folder(t)
	testing.expect(t, toolbox.run({"git", "init", "-q", "-b", "master", root}))
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/loose", root), "x") == nil)
	write :: proc(version: string, user: rawptr) -> (paths: []string, subject: string, why: string) { return nil, "", "never" }
	_, why := publish({dir = root, asked = "patch", write = write})
	testing.expect_value(t, why, "the working tree is not clean")
}
