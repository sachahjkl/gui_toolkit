package tk_release

import "core:fmt"
import "core:strings"
import toolbox "../toolbox"

// What a release asks for: "patch", "minor" or "major" (the next one after the last published version), or an exact
// "x.y.z", which must come after it. Two sessions that publish at the same time each take their own number this way.
version_next :: proc(last, asked: string) -> (version: string, ok: bool) {
	wanted := strings.trim_prefix(asked, "v")
	n, has_last := semver(last)
	if !has_last { n = {0, 0, 0} }
	switch wanted {
	case "patch": return fmt.tprintf("%d.%d.%d", n[0], n[1], n[2] + 1), true
	case "minor": return fmt.tprintf("%d.%d.0", n[0], n[1] + 1), true
	case "major": return fmt.tprintf("%d.0.0", n[0] + 1), true
	}
	if _, exact := semver(wanted); !exact { return "", false }
	if has_last && !semver_newer(last, wanted) { return "", false }
	return wanted, true
}

// The highest version among the tags v<x.y.z> of `tags` (git tag --list output); "" when there is none.
version_highest :: proc(tags: string) -> string {
	best := ""
	rest := tags
	for line in strings.split_lines_iterator(&rest) {
		v := strings.trim_prefix(strings.trim_space(line), "v")
		if _, ok := semver(v); !ok { continue }
		if best == "" || semver_newer(best, v) { best = v }
	}
	return best
}

// The files of a release, written for one version. It returns the paths to commit and the commit's subject, or why
// it cannot (the checkout is then reset to HEAD).
Release_Writer :: #type proc(version: string, user: rawptr) -> (paths: []string, subject: string, why: string)

Publish :: struct {
	dir:     string,         // the checkout; "": the current folder. Any branch, a worktree or a detached HEAD
	asked:   string,         // "patch", "minor", "major" or "x.y.z" (version_next)
	floor:   string,         // the version of the sources, when no tag says more (a project's first release)
	write:   Release_Writer, // writes the release's files for a version
	user:    rawptr,
	branch:  string,         // the branch the release goes to on origin; "": master
	no_push: bool,           // stop after the tag, to look at the commit (git tag -d, git reset --hard HEAD~1 undo it)
	tries:   int,            // how many times origin may move under it; 0: 3
}

// Publishes a release: fetches origin, merges its branch into HEAD when HEAD lacks some of it, takes the next number, writes and commits the
// release, tags it v<version> (annotated) and pushes the commit to the branch with the tag in one atomic push, so a
// tag never goes out without its commit. When origin moved meanwhile, the push is refused: the commit and the tag
// are undone and it starts again from the fetch, with the next number. The working tree must be clean.
publish :: proc(p: Publish) -> (version: string, why: string) {
	branch := p.branch != "" ? p.branch : "master"
	tries := p.tries > 0 ? p.tries : 3
	git :: proc(dir: string, args: ..string) -> bool {
		command := make([dynamic]string, context.temp_allocator)
		append(&command, "git", "-C", dir != "" ? dir : ".")
		append(&command, ..args)
		return toolbox.run(command[:])
	}
	git_quiet :: proc(dir: string, args: ..string) -> bool {
		_, ok := git_out(dir, ..args)
		return ok
	}
	git_out :: proc(dir: string, args: ..string) -> (string, bool) {
		command := make([dynamic]string, context.temp_allocator)
		append(&command, "git", "-C", dir != "" ? dir : ".")
		append(&command, ..args)
		out, code := toolbox.capture(command[:])
		return out, code == 0
	}

	if out, ok := git_out(p.dir, "status", "--porcelain"); !ok || strings.trim_space(out) != "" { return "", "the working tree is not clean" }
	for attempt in 0 ..< tries {
		if !git(p.dir, "fetch", "-q", "--tags", "origin", branch) { return "", "git fetch failed" }
		// (HEAD has origin's commits already: nothing to do; else they are merged in, so a branch's own merges stay as they
		// are, which a rebase would flatten and conflict on again)
		upstream := fmt.tprintf("origin/%s", branch)
		if !git_quiet(p.dir, "merge-base", "--is-ancestor", upstream, "HEAD") {
			if !git(p.dir, "merge", "-q", "--no-edit", upstream) {
				_ = git(p.dir, "merge", "--abort")
				return "", fmt.tprintf("HEAD does not merge with %s: resolve that first", upstream)
			}
		}
		tags, _ := git_out(p.dir, "tag", "--list", "v*")
		last := version_highest(tags)
		if last == "" || semver_newer(last, p.floor) { last = p.floor }
		ok: bool
		version, ok = version_next(last, p.asked)
		if !ok { return "", fmt.tprintf("%s is not patch, minor, major or a version after %s", p.asked, last) }

		paths, subject, wwhy := p.write(version, p.user)
		if wwhy != "" {
			_ = git(p.dir, "reset", "-q", "--hard", "HEAD")
			return "", wwhy
		}
		add := make([dynamic]string, context.temp_allocator)
		append(&add, "add", "-A", "--")
		append(&add, ..paths)
		if !git(p.dir, ..add[:]) { return "", "git add failed" }
		if !git(p.dir, "commit", "-q", "-m", subject) { return "", "git commit failed" }
		tag := fmt.tprintf("v%s", version)
		if !git(p.dir, "tag", "-a", tag, "-m", subject) { return "", "git tag failed" }
		if p.no_push { return version, "" }

		if git(p.dir, "push", "-q", "--atomic", "origin", fmt.tprintf("HEAD:refs/heads/%s", branch), fmt.tprintf("refs/tags/%s", tag)) {
			return version, ""
		}
		// (origin moved: someone published or pushed meanwhile; nothing went out)
		_ = git(p.dir, "tag", "-d", tag)
		_ = git(p.dir, "reset", "-q", "--hard", "HEAD~1")
		fmt.eprintfln("release: origin/%s moved during %s (try %d of %d): again with the next number", branch, version, attempt + 1, tries)
	}
	return "", fmt.tprintf("origin/%s kept moving: nothing was published", branch)
}
