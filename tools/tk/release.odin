package tk

import "core:fmt"
import "core:os"
import toolbox "../../src/toolbox"
import release "../../src/release"

// Publishes a version of gui_toolkit, on Windows or Linux (CONTRIBUTING.md, "Publishing a version"), from a clean checkout:
// any branch, a worktree or a detached HEAD. The version is "patch", "minor", "major" (the next after the last tag on
// origin) or an exact x.y.z. release.publish fetches origin, rebases on master and takes the number, then:
//   1. tools/changelog assembles the fragments of changelog.d into the version's CHANGELOG.md section, and writes the version in
//      ui/version.odin and the README's badge;
//   2. on Windows, the About picture (docs/screenshots/about.png shows the version) is taken again from fidget; elsewhere it stays;
//   3. that is committed as "<version>: <summary>" and tagged v<version> (annotated: signed tags need it);
//   4. unless -no-push: master and the tag are pushed at once (atomic); when origin moved meanwhile, it starts again with the
//      next number. Then the GitHub release is made with the section as its notes (gh).
// -no-push stops after the tag, to look at the commit (`git tag -d v<version>` and `git reset --hard HEAD~1` undo it).
Release_Job :: struct {
	root:      string,
	changelog: string,
	summary:   string,
}

run_release :: proc(args: []string) -> string {
	job := Release_Job{root = toolkit_root(), summary = toolbox.flag_value(args, "summary")}
	job.changelog = join({job.root, "build", "changelog.exe" when ODIN_OS == .Windows else "changelog"})
	if !toolbox.run({"odin", "build", join({job.root, "tools", "changelog"}), fmt.tprintf("-out:%s", job.changelog)}) { return "building tools/changelog failed" }
	if !toolbox.run({job.changelog, "-check"}, {dir = job.root}) { return "changelog.d has fragments to fix first" }

	version, why := release.publish({dir = job.root, asked = toolbox.plain_args(args)[0], write = release_write, user = &job, no_push = toolbox.has_flag(args, "no-push")})
	if why != "" { return why }
	tag := fmt.tprintf("v%s", version)
	if toolbox.has_flag(args, "no-push") { fmt.printfln("committed and tagged %s (not pushed)", tag); return "" }

	notes := join({job.root, "build", fmt.tprintf("gui_toolkit-%s-notes.md", version)})
	if !toolbox.run({job.changelog, "-section", fmt.tprintf("-version:%s", version), fmt.tprintf("-out:%s", notes)}, {dir = job.root}) { return "reading the CHANGELOG section failed" }
	defer os.remove(notes)
	if !toolbox.run({"gh", "release", "create", tag, "--title", fmt.tprintf("gui_toolkit %s", version), "--notes-file", notes, "--verify-tag", "--latest"}, {dir = job.root}) { return "gh release create failed" }
	fmt.printfln("released %s", tag)
	return ""
}

@(private = "file")
release_write :: proc(version: string, user: rawptr) -> (paths: []string, subject: string, why: string) {
	job := (^Release_Job)(user)
	if !toolbox.run({job.changelog, "-assemble", fmt.tprintf("-version:%s", version)}, {dir = job.root}) { return nil, "", "assembling the CHANGELOG failed" }
	if !toolbox.run({job.changelog, "-check", fmt.tprintf("-release:%s", version)}, {dir = job.root}) { return nil, "", "the release is not consistent" }
	when ODIN_OS == .Windows {
		if shot := screenshots(job.root, {build = true, only = {"about"}, width = SHOTS_WIDTH}); why != "" { return nil, "", fmt.tprintf("the About picture failed: %s", shot) }
	} else {
		fmt.println("tk release: the About picture is taken on Windows (fidget): it stays as it is")
	}
	paths = make([]string, 5, context.temp_allocator)
	copy(paths, []string{"CHANGELOG.md", "changelog.d", "src/ui/version.odin", "README.md", "docs/screenshots/about.png"})
	return paths, job.summary != "" ? fmt.tprintf("%s: %s", version, job.summary) : version, ""
}
