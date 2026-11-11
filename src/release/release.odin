// Package release: what a program's release is made of, the same steps on a laptop and in a release workflow (a project's
// own tool calls them, its Config says what the program is). The package is named tk_release.
//
//	package [version]   <dist>/<name>-<version>-linux-x64.tar.gz on Linux, <name>-<version>-windows-x64.zip on Windows:
//	                    the program and the files beside it, its SHA-256 in <archive>.sha256; the version is the
//	                    sources' when none is given, and a version given must be theirs (a tag). A program that
//	                    updates itself (Config.update): the program alone too, and its manifest signed by
//	                    $UPDATE_SIGNING_KEY (a release, with its tag, needs the key)
//	notes <version>     the changelog's section of that version (a GitHub release's notes)
//	ship <version> [--dry-run]
//	                    from a clean master: the fragments of changelog.d/ assembled into the changelog's section
//	                    [<version>] with today's date, the sources' version becomes <version>, the project's checks, a
//	                    commit, the tag v<version>, the push
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

Config :: struct {
	name:         string,     // the program ("classeur"): the archive's name, the commit's and the tag's message
	repository:   string,     // https://github.com/<owner>/<repo>: the versions' links
	changelog:    string,     // "CHANGELOG.md", its fragments in changelog.d/ beside it
	version_file: string,     // the source that holds the version ("src/main.odin")
	version_line: string,     // the start of its line ("APP_VERSION :: "), the version in quotes after it
	program:      string,     // the release build ("build/classeur", "build/classeur.exe")
	dist:         string,     // where the archive goes ("build/dist")
	files:        [][2]string,   // what goes beside the program: a file and its name in the archive
	check:        proc() -> int, // the project's checks, run by ship before it commits (0: they passed)
	// a program that updates itself (gt:update; its name set): package_ writes the program alone, what an installed copy
	// downloads, and its manifest signed by $UPDATE_SIGNING_KEY (toolbox.UPDATE_KEY_ENV)
	update:       update.Product,
}

// The version of the sources: the value in quotes after `line` ("" when the line is not there).
version_of :: proc(source, line: string) -> string {
	rest := source
	for l in strings.split_lines_iterator(&rest) {
		if !strings.has_prefix(l, line) { continue }
		v := strings.trim_space(l[len(line):])
		if len(v) >= 2 && v[0] == '"' {
			if end := strings.index_byte(v[1:], '"'); end >= 0 { return v[1:end + 1] }
		}
	}
	return ""
}

// The sources with the version set to `version`; ok = false when the line is not there.
version_set :: proc(source, line, version: string, allocator := context.temp_allocator) -> (out: string, ok: bool) {
	old := version_of(source, line)
	if old == "" { return "", false }
	from := fmt.tprintf("%s\"%s\"", line, old)
	to := fmt.tprintf("%s\"%s\"", line, version)
	out, _ = strings.replace(source, from, to, 1, allocator)
	return out, out != source || old == version
}

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

// The folder of the changelog and its fragments, for gt:changelog.
@(private = "file")
changelog_options :: proc(c: Config) -> changelog.Options {
	return {root = os.dir(c.changelog), link = fmt.tprintf("%s/releases/tag/v%%s", c.repository)}
}

// `notes <version>`: the changelog's section on the standard output.
notes :: proc(c: Config, args: []string) -> int {
	if len(args) != 1 { fmt.eprintfln("%s: notes <version>", c.name); return 2 }
	section, ok := changelog.section(changelog_options(c).root, strings.trim_prefix(args[0], "v"))
	if !ok { fmt.eprintfln("%s: %s has no section %s", c.name, c.changelog, args[0]); return 1 }
	fmt.print(section)
	return 0
}

// `package [version]`: the archive of the release build and its SHA-256.
package_ :: proc(c: Config, args: []string) -> int {
	source, _ := read_text(c.version_file)
	version := version_of(source, c.version_line)
	if len(args) > 0 {
		asked := strings.trim_prefix(args[0], "v")
		if asked != version { fmt.eprintfln("%s: the tag says %s, the sources %s", c.name, asked, version); return 1 }
	}
	if !os.exists(c.program) { fmt.eprintfln("%s: %s is not built (a release build first)", c.name, c.program); return 1 }
	// (a release, with its tag: the copies installed update themselves from its signed manifest, which needs the key)
	updates := c.update.name != ""
	signed := os.get_env(toolbox.UPDATE_KEY_ENV, context.temp_allocator) != ""
	if updates && len(args) > 0 && !signed { fmt.eprintfln("%s: a release signs its update manifest: set %s", c.name, toolbox.UPDATE_KEY_ENV); return 1 }
	when ODIN_OS == .Windows {
		name := fmt.tprintf("%s-%s-windows-x64", c.name, version)
		exe, archive := fmt.tprintf("%s.exe", c.name), fmt.tprintf("%s.zip", name)
	} else {
		name := fmt.tprintf("%s-%s-linux-x64", c.name, version)
		exe, archive := c.name, fmt.tprintf("%s.tar.gz", name)
	}
	stage := fmt.tprintf("%s/%s", c.dist, name)
	_ = os.remove_all(c.dist)
	if os.make_directory_all(stage) != nil { fmt.eprintfln("%s: %s cannot be made", c.name, stage); return 1 }
	if !copy_file(c.name, c.program, fmt.tprintf("%s/%s", stage, exe)) { return 1 }
	for f in c.files {
		if !copy_file(c.name, f[0], fmt.tprintf("%s/%s", stage, f[1])) { return 1 }
	}
	when ODIN_OS == .Windows {
		// (tar.exe of Windows 10 and later: -a picks the zip format by the name)
		if !toolbox.run({"tar", "-a", "-cf", archive, name}, {dir = c.dist}) { return 1 }
	} else {
		// (the symbols are a third of a program: a crash in a release is read again with a build of its tag)
		if !toolbox.run({"strip", fmt.tprintf("%s/%s", stage, exe)}) { return 1 }
		_ = os.chmod(fmt.tprintf("%s/%s", stage, exe), {.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other})
		if !toolbox.run({"tar", "--owner=0", "--group=0", "--numeric-owner", "-czf", archive, name}, {dir = c.dist}) { return 1 }
	}
	// the program alone (stripped on Linux, as in the archive) and its signed manifest
	program: []u8
	if updates {
		err: os.Error
		program, err = os.read_entire_file(fmt.tprintf("%s/%s", stage, exe), context.temp_allocator)
		if err != nil { fmt.eprintfln("%s: %s/%s cannot be read", c.name, stage, exe); return 1 }
	}
	_ = os.remove_all(stage)
	if updates {
		alone := fmt.tprintf("%s/%s", c.dist, update.expected_file_name(c.update, version, update.PLATFORM, context.temp_allocator))
		if os.write_entire_file(alone, program) != nil { fmt.eprintfln("%s: %s cannot be written", c.name, alone); return 1 }
		when ODIN_OS != .Windows { _ = os.chmod(alone, {.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other}) }
		if signed {
			manifest := fmt.tprintf("%s/%s", c.dist, update.manifest_name(update.PLATFORM, "", context.temp_allocator))
			if why := toolbox.update_manifest(c.update, alone, version, "", manifest); why != "" { fmt.eprintfln("%s: %s", c.name, why); return 1 }
		}
	}
	sum, ok := toolbox.sha256_file(fmt.tprintf("%s/%s", c.dist, archive))
	if !ok { return 1 }
	// (one file per archive: the Linux and the Windows jobs of a release each upload their own)
	if os.write_entire_file(fmt.tprintf("%s/%s.sha256", c.dist, archive), fmt.tprintf("%s  %s\n", sum, archive)) != nil { return 1 }
	fmt.printfln("wrote %s/%s and %s/%s.sha256", c.dist, archive, c.dist, archive)
	return 0
}

@(private = "file")
copy_file :: proc(who, from, to: string) -> bool {
	data, err := os.read_entire_file(from, context.temp_allocator)
	if err != nil { fmt.eprintfln("%s: %s cannot be read", who, from); return false }
	if os.write_entire_file(to, data) != nil { fmt.eprintfln("%s: %s cannot be written", who, to); return false }
	return true
}

// `ship <version> [--dry-run]`: the release made from a clean master, tagged and pushed (the release workflow builds it).
ship :: proc(c: Config, args: []string) -> int {
	if len(args) == 0 { fmt.eprintfln("%s: ship <version> [--dry-run]", c.name); return 2 }
	version := strings.trim_prefix(args[0], "v")
	dry := len(args) > 1 && args[1] == "--dry-run"
	if _, ok := semver(version); !ok { fmt.eprintfln("%s: %s is not x.y.z", c.name, version); return 2 }
	source, _ := read_text(c.version_file)
	current := version_of(source, c.version_line)
	if !semver_newer(current, version) && current != version { fmt.eprintfln("%s: %s does not come after %s", c.name, version, current); return 1 }
	branch, _ := toolbox.capture({"git", "rev-parse", "--abbrev-ref", "HEAD"})
	if strings.trim_space(branch) != "master" { fmt.eprintfln("%s: ship from master", c.name); return 1 }
	if status, _ := toolbox.capture({"git", "status", "--porcelain"}); strings.trim_space(status) != "" {
		fmt.eprintfln("%s: the working tree is not clean", c.name)
		return 1
	}
	o := changelog_options(c)
	problems, fragments := changelog.check(o)
	for p in problems { fmt.eprintfln("%s: %s", c.name, p) }
	if len(problems) > 0 { return 1 }
	section, _ := changelog.preview(o.root)
	if section == "" { fmt.eprintfln("%s: nothing to release: no fragment in changelog.d/ (and nothing under [Unreleased] in %s)", c.name, c.changelog); return 1 }
	new_source, sok := version_set(source, c.version_line, version)
	if !sok { fmt.eprintfln("%s: %s has no %s line", c.name, c.version_file, c.version_line); return 1 }
	if dry {
		fmt.printfln("ship %s (dry run): the section it releases\n%s", version, section)
		return 0
	}
	_, errors := changelog.assemble(o, version)
	for e in errors { fmt.eprintfln("%s: %s", c.name, e) }
	if len(errors) > 0 { return 1 }
	if os.write_entire_file(c.version_file, new_source) != nil { return 1 }
	if c.check != nil && c.check() != 0 { fmt.eprintfln("%s: the checks failed: nothing is committed (git checkout . takes the changes back)", c.name); return 1 }
	add := make([dynamic]string, context.temp_allocator)
	append(&add, "git", "add", "-A", "--", c.changelog, c.version_file)
	// (the fragments deleted: a project with only an [Unreleased] section may have no changelog.d/ to add)
	if fragments > 0 { append(&add, fmt.tprintf("%s/changelog.d", o.root)) }
	steps := [][]string{
		add[:],
		{"git", "commit", "-m", fmt.tprintf("%s %s", c.name, version)},
		{"git", "tag", "-a", fmt.tprintf("v%s", version), "-m", fmt.tprintf("%s %s", c.name, version)},
		{"git", "push", "origin", "master", fmt.tprintf("v%s", version)},
	}
	for s in steps { if !toolbox.run(s, {echo = true}) { return 1 } }
	fmt.printfln("shipped v%s: the release workflow builds and publishes it (%s/actions)", version, c.repository)
	return 0
}
