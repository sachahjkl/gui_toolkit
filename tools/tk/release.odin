package tk

import "core:fmt"
import "core:os"
import "core:strings"
import toolbox "../../src/toolbox"

// Publishes a version of gui_toolkit, on Windows or Linux (CONTRIBUTING.md, "Publishing a version"), from a clean checkout of master:
//   1. tools/changelog assembles the fragments of changelog.d into the version's CHANGELOG.md section, and writes the version in
//      ui/version.odin and the README's badge;
//   2. on Windows, the About picture (docs/screenshots/about.png shows the version) is taken again from fidget; elsewhere it stays;
//   3. that is committed as "<version>: <summary>" and tagged v<version> (annotated: signed tags need it);
//   4. unless -no-push: master and the tag are pushed, and the GitHub release is made with the section as its notes (gh).
// -no-push stops after the tag, to look at the commit (`git tag -d v<version>` and `git reset --hard HEAD~1` undo it).
run_release :: proc(a: ^Args) -> string {
	version := a.positionals[0]
	summary := flag_value(a, "summary")
	root := toolkit_root()
	git :: proc(root: string, args: ..string) -> bool {
		command := make([dynamic]string, context.temp_allocator)
		append(&command, "git", "-C", root)
		append(&command, ..args)
		return toolbox.run(command[:])
	}

	if out, code := toolbox.capture({"git", "-C", root, "status", "--porcelain"}); code != 0 || strings.trim_space(out) != "" { return "the working tree is not clean" }
	if out, code := toolbox.capture({"git", "-C", root, "branch", "--show-current"}); code != 0 || strings.trim_space(out) != "master" { return "not on master" }
	changelog := join({root, "build", "changelog.exe" when ODIN_OS == .Windows else "changelog"})
	if !toolbox.run({"odin", "build", join({root, "tools", "changelog"}), fmt.tprintf("-out:%s", changelog)}) { return "building tools/changelog failed" }
	if !toolbox.run({changelog, "-check"}, {dir = root}) { return "changelog.d has fragments to fix first" }
	if !toolbox.run({changelog, "-assemble", fmt.tprintf("-version:%s", version)}, {dir = root}) { return "assembling the CHANGELOG failed" }
	if !toolbox.run({changelog, "-check", fmt.tprintf("-release:%s", version)}, {dir = root}) { return "the release is not consistent" }

	when ODIN_OS == .Windows {
		if why := screenshots(root, {build = true, only = {"about"}, width = SHOTS_WIDTH}); why != "" { return fmt.tprintf("the About picture failed: %s", why) }
	} else {
		fmt.println("tk release: the About picture is taken on Windows (fidget): it stays as it is")
	}

	if !git(root, "add", "-A", "--", "CHANGELOG.md", "changelog.d", "src/ui/version.odin", "README.md", "docs/screenshots/about.png") { return "git add failed" }
	if !git(root, "commit", "-q", "-m", summary != "" ? fmt.tprintf("%s: %s", version, summary) : version) { return "git commit failed" }
	tag := fmt.tprintf("v%s", version)
	if !git(root, "tag", "-a", tag, "-m", summary != "" ? fmt.tprintf("%s: %s", tag, summary) : tag) { return "git tag failed" }
	if has_flag(a, "no-push") { fmt.printfln("committed and tagged %s (not pushed)", tag); return "" }

	if !git(root, "push", "-q", "origin", "HEAD:master") { return "pushing master failed" }
	if !git(root, "push", "-q", "origin", tag) { return "pushing the tag failed" }
	notes := join({root, "build", fmt.tprintf("gui_toolkit-%s-notes.md", version)})
	if !toolbox.run({changelog, "-section", fmt.tprintf("-version:%s", version), fmt.tprintf("-out:%s", notes)}, {dir = root}) { return "reading the CHANGELOG section failed" }
	defer os.remove(notes)
	if !toolbox.run({"gh", "release", "create", tag, "--title", fmt.tprintf("gui_toolkit %s", version), "--notes-file", notes, "--verify-tag", "--latest"}, {dir = root}) { return "gh release create failed" }
	fmt.printfln("released %s", tag)
	return ""
}
