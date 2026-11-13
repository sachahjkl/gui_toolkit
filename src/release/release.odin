// Package release: what a program's release is made of, the same steps on a laptop and in a release workflow (a project's
// own tool calls them, its Release_Options says what the program is). The package is named tk_release.
//
//	package [version]   <dist>/<name>-<version>-linux-x64.tar.gz on Linux, <name>-<version>-windows-x64.zip on Windows:
//	                    the program (on Windows with its console launcher, <name>.com) and the files beside it, its
//	                    SHA-256 in <archive>.sha256; the version is the
//	                    sources' when none is given, and a version given must be theirs (a tag). A program that
//	                    updates itself (Release_Options.update): the program alone too, and its manifest signed by
//	                    $UPDATE_SIGNING_KEY (a release, with its tag, needs the key)
//	notes <version>     the changelog's section of that version (a GitHub release's notes)
//	ship <patch|minor|major|x.y.z> [--dry-run]
//	                    from a clean checkout: the next number after the last tag (publish), the fragments of
//	                    changelog.d/ assembled into the changelog's section with today's date, the sources' version
//	                    set, the project's checks, a commit, the tag v<version>, master and the tag pushed at once
//
// The changelog is made of fragments, one file per change in changelog.d/ beside CHANGELOG.md (gt:changelog,
// docs/changelog.md); CHANGELOG.md follows Keep a Changelog: `## [x.y.z] - yyyy-mm-dd` sections, the versions' links at
// its end. An [Unreleased] section written by hand is assembled with the fragments, then removed.
package tk_release

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import changelog "../changelog"
import toolbox "../toolbox"
import update "../update"
import "../fsx"

Release_Options :: struct {
	// the program: its name (the archive's, the commit's and the tag's message), its repository (the versions' links), its
	// changelog (its fragments in changelog.d/ beside it), where its version is (version_file, version_line), its release
	// build (program)
	using project: toolbox.Project,
	dist:         string,        // where the archive goes ("build/dist")
	files:        [][2]string,   // what goes beside the program: a file and its name in the archive
	check:        proc() -> int, // the project's checks, run by ship before it commits (0: they passed)
	// a program that updates itself (gt:update; its name set): package_ writes the program alone, what an installed copy
	// downloads, and its manifest signed by $UPDATE_SIGNING_KEY (toolbox.UPDATE_KEY_ENV)
	update:       update.Product,
}

// The release's commands of a project's tool: package, notes and ship, over `o` (copied; the slices it holds must live as
// long as the tool: a package's table, or main's frame, which tool_main never leaves).
commands :: proc(o: Release_Options) -> [3]toolbox.Command {
	copy := new_clone(o)
	return {
		{name = "package", usage = "[version]: the archive of a release build and its SHA-256 (and the signed update of a program that updates itself)", run_with = run_package, user = copy},
		{name = "notes", usage = "<version>: the changelog's section of that version (a release's notes)", run_with = run_notes, user = copy},
		{name = "ship", usage = "<patch|minor|major|x.y.z> [--dry-run]: from a clean checkout, the changelog, the version, the checks, a commit, the tag, the push", run_with = run_ship, user = copy},
	}
}

@(private = "file") run_package :: proc(args: []string, user: rawptr) -> int { return package_((^Release_Options)(user)^, args) }
@(private = "file") run_notes :: proc(args: []string, user: rawptr) -> int { return notes((^Release_Options)(user)^, args) }
@(private = "file") run_ship :: proc(args: []string, user: rawptr) -> int { return ship((^Release_Options)(user)^, args) }

// The three numbers of "x.y.z"; ok = false for anything else.
semver :: proc(v: string) -> (n: [3]int, ok: bool) {
	parts := strings.split(v, ".", context.temp_allocator)
	if len(parts) != 3 { return }
	for p, i in parts {
		if p == "" || (len(p) > 1 && p[0] == '0') { return }
		n[i] = strconv.parse_int(p, 10) or_return
		if n[i] < 0 { return }
	}
	return n, true
}

// Whether `b` comes after `a`.
semver_newer :: proc(a, b: string) -> bool {
	x, ok1 := semver(a)
	y, ok2 := semver(b)
	if !(ok1 && ok2) { return false }
	for i in 0 ..< 3 { if y[i] != x[i] { return y[i] > x[i] } }
	return false
}

@(private = "file")
read_text :: proc(path: string) -> (string, bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return string(data), err == nil
}

// The folder of the changelog and its fragments, for gt:changelog. A bare "CHANGELOG.md" is in the current folder:
// os.dir gives "" for it, and the changelog was then looked for at the root of the disk.
@(private = "package")
changelog_options :: proc(o: Release_Options) -> changelog.Project_Options {
	root := os.dir(o.changelog)
	if root == "" { root = "." }
	return {root = root, link = fmt.tprintf("%s/releases/tag/v%%s", o.repository)}
}

// `notes <version>`: the changelog's section on the standard output.
notes :: proc(o: Release_Options, args: []string) -> int {
	if len(args) != 1 { fmt.eprintfln("%s: notes <version>", o.name); return 2 }
	section, ok := changelog.section(changelog_options(o).root, strings.trim_prefix(args[0], "v"))
	if !ok { fmt.eprintfln("%s: %s has no section %s", o.name, o.changelog, args[0]); return 1 }
	fmt.print(section)
	return 0
}

// `package [version]`: the archive of the release build and its SHA-256.
package_ :: proc(o: Release_Options, args: []string) -> int {
	source, _ := read_text(o.version_file)
	version := toolbox.version_of(source, o.version_line)
	if len(args) > 0 {
		asked := strings.trim_prefix(args[0], "v")
		if asked != version { fmt.eprintfln("%s: the tag says %s, the sources %s", o.name, asked, version); return 1 }
	}
	if !os.exists(o.program) { fmt.eprintfln("%s: %s is not built (a release build first)", o.name, o.program); return 1 }
	// (a release, with its tag: the copies installed update themselves from its signed manifest, which needs the key)
	updates := o.update.name != ""
	signed := os.get_env(toolbox.UPDATE_KEY_ENV, context.temp_allocator) != ""
	if updates && len(args) > 0 && !signed { fmt.eprintfln("%s: a release signs its update manifest: set %s", o.name, toolbox.UPDATE_KEY_ENV); return 1 }
	when ODIN_OS == .Windows {
		name := fmt.tprintf("%s-%s-windows-x64", o.name, version)
		exe, archive := fmt.tprintf("%s.exe", o.name), fmt.tprintf("%s.zip", name)
	} else {
		name := fmt.tprintf("%s-%s-linux-x64", o.name, version)
		exe, archive := o.name, fmt.tprintf("%s.tar.gz", name)
	}
	stage := fmt.tprintf("%s/%s", o.dist, name)
	_ = os.remove_all(o.dist)
	if !fsx.make_dirs(stage) { fmt.eprintfln("%s: %s cannot be made", o.name, stage); return 1 }
	if !copy_file(o.name, o.program, fmt.tprintf("%s/%s", stage, exe)) { return 1 }
	// (its console launcher beside it: typed in cmd or PowerShell, the program gives its output and exit code)
	when ODIN_OS == .Windows {
		if !copy_file(o.name, toolbox.launcher_path(o.project), fmt.tprintf("%s/%s.com", stage, o.name)) { return 1 }
	}
	for f in o.files {
		if !copy_file(o.name, f[0], fmt.tprintf("%s/%s", stage, f[1])) { return 1 }
	}
	when ODIN_OS == .Windows {
		// (tar.exe of Windows 10 and later: -a picks the zip format by the name)
		if !toolbox.run({"tar", "-a", "-cf", archive, name}, {dir = o.dist}) { return 1 }
	} else {
		// (the symbols are a third of a program: a crash in a release is read again with a build of its tag)
		if !toolbox.run({"strip", fmt.tprintf("%s/%s", stage, exe)}) { return 1 }
		_ = os.chmod(fmt.tprintf("%s/%s", stage, exe), {.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other})
		if !toolbox.run({"tar", "--owner=0", "--group=0", "--numeric-owner", "-czf", archive, name}, {dir = o.dist}) { return 1 }
	}
	// the program alone (stripped on Linux, as in the archive) and its signed manifest
	program: []u8
	if updates {
		err: os.Error
		program, err = os.read_entire_file(fmt.tprintf("%s/%s", stage, exe), context.temp_allocator)
		if err != nil { fmt.eprintfln("%s: %s/%s cannot be read", o.name, stage, exe); return 1 }
	}
	_ = os.remove_all(stage)
	if updates {
		alone := fmt.tprintf("%s/%s", o.dist, update.expected_file_name(o.update, version, update.PLATFORM, context.temp_allocator))
		if os.write_entire_file(alone, program) != nil { fmt.eprintfln("%s: %s cannot be written", o.name, alone); return 1 }
		when ODIN_OS != .Windows { _ = os.chmod(alone, {.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other}) }
		if signed {
			manifest := fmt.tprintf("%s/%s", o.dist, update.manifest_name(update.PLATFORM, "", context.temp_allocator))
			if why := toolbox.update_manifest(o.update, alone, version, "", manifest); why != "" { fmt.eprintfln("%s: %s", o.name, why); return 1 }
		}
	}
	sum, ok := toolbox.sha256_file(fmt.tprintf("%s/%s", o.dist, archive))
	if !ok { return 1 }
	// (one file per archive: the Linux and the Windows jobs of a release each upload their own)
	if os.write_entire_file(fmt.tprintf("%s/%s.sha256", o.dist, archive), fmt.tprintf("%s  %s\n", sum, archive)) != nil { return 1 }
	fmt.printfln("wrote %s/%s and %s/%s.sha256", o.dist, archive, o.dist, archive)
	return 0
}

@(private = "file")
copy_file :: proc(who, from, to: string) -> bool {
	data, err := os.read_entire_file(from, context.temp_allocator)
	if err != nil { fmt.eprintfln("%s: %s cannot be read", who, from); return false }
	if os.write_entire_file(to, data) != nil { fmt.eprintfln("%s: %s cannot be written", who, to); return false }
	return true
}

// `ship <patch|minor|major|x.y.z> [--dry-run]`: the release made from a clean checkout (any branch, a worktree), its
// number the next after the last tag, committed, tagged and pushed to master with its tag at once (publish); the
// release workflow builds it.
ship :: proc(o: Release_Options, args: []string) -> int {
	if len(args) == 0 { fmt.eprintfln("%s: ship <patch|minor|major|x.y.z> [--dry-run]", o.name); return 2 }
	asked := strings.trim_prefix(args[0], "v")
	dry := len(args) > 1 && args[1] == "--dry-run"
	source, _ := read_text(o.version_file)
	current := toolbox.version_of(source, o.version_line)
	if _, ok := version_next(current, asked); !ok { fmt.eprintfln("%s: %s is not patch, minor, major or a version after %s", o.name, asked, current); return 2 }
	changes := changelog_options(o)
	problems, _ := changelog.check(changes)
	for p in problems { fmt.eprintfln("%s: %s", o.name, p) }
	if len(problems) > 0 { return 1 }
	section, _ := changelog.preview(changes.root)
	if section == "" { fmt.eprintfln("%s: nothing to release: no fragment in changelog.d/ (and nothing under [Unreleased] in %s)", o.name, o.changelog); return 1 }
	if dry {
		fmt.printfln("ship %s (dry run, after %s): the section it releases\n%s", asked, current, section)
		return 0
	}
	o := o
	version, why := publish({asked = asked, floor = current, write = ship_write, user = &o})
	if why != "" { fmt.eprintfln("%s: %s", o.name, why); return 1 }
	fmt.printfln("shipped v%s: the release workflow builds and publishes it (%s/actions)", version, o.repository)
	return 0
}

// The files of a program's release: the changelog's section, the version in the sources, then the project's checks.
@(private = "file")
ship_write :: proc(version: string, user: rawptr) -> (paths: []string, subject: string, why: string) {
	o := (^Release_Options)(user)^
	changes := changelog_options(o)
	source, _ := read_text(o.version_file)
	new_source, sok := toolbox.version_set(source, o.version_line, version)
	if !sok { return nil, "", fmt.tprintf("%s has no %s line", o.version_file, o.version_line) }
	_, fragments := changelog.check(changes)
	_, errors := changelog.assemble(changes, version)
	for e in errors { fmt.eprintfln("%s: %s", o.name, e) }
	if len(errors) > 0 { return nil, "", "assembling the changelog failed" }
	if os.write_entire_file(o.version_file, new_source) != nil { return nil, "", fmt.tprintf("%s cannot be written", o.version_file) }
	if o.check != nil && o.check() != 0 { return nil, "", "the checks failed: nothing is committed" }
	add := make([dynamic]string, context.temp_allocator)
	append(&add, o.changelog, o.version_file)
	// (the fragments deleted: a project with only an [Unreleased] section may have no changelog.d/ to add)
	if fragments > 0 { append(&add, fmt.tprintf("%s/changelog.d", changes.root)) }
	return add[:], fmt.tprintf("%s %s", o.name, version), ""
}
