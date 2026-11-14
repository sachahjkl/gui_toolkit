package tk_toolbox

// A program's Windows resource, made from its Project: what Explorer, Task Manager, the Start menu and every window of
// the program show of it, and how Windows runs it. build_windows writes it before a build; odin_command passes it to the
// linker (-resource). The program writes no .rc and no manifest of its own.
//
//	id 1, ICON         Project.icon: the file's icon, the shortcuts', the taskbar's and every window's (the platform's
//	                   window class loads id 1, big and small)
//	id 1, VERSIONINFO  the version (Project.version_file), title, description, publisher and copyright (Properties >
//	                   Details; Task Manager names the process by the file's description)
//	id 1, RT_MANIFEST  as the user who starts it, Windows 10 and 11, per-monitor DPI aware (v2), UTF-8 as the code page
//	                   of the A functions and the C runtime, paths longer than MAX_PATH, the common controls of version 6

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "../fsx"

// Where build_windows writes the resource script and the manifest (<name>.rc, <name>.manifest), in the project.
WINDOWS_RESOURCE_DIR :: "build/windows"

// The resource script build_windows writes in `dir`, and odin_command passes to the linker.
windows_resource_path :: proc(p: Project, dir := WINDOWS_RESOURCE_DIR) -> string { return fmt.tprintf("%s/%s.rc", dir, p.name) }

// The program's icon: Project.icon, else assets/<name>.ico (what a tool's logo command writes).
project_icon :: proc(p: Project) -> string { return p.icon != "" ? p.icon : fmt.tprintf("assets/%s.ico", p.name) }

// The program as people read it: Project.title, else its name.
project_title :: proc(p: Project) -> string { return p.title != "" ? p.title : p.name }

// The three numbers of a version "x.y.z"; ok = false for anything else.
version_numbers :: proc(version: string) -> (n: [3]int, ok: bool) {
	parts := strings.split(version, ".", context.temp_allocator)
	if len(parts) != 3 { return }
	for part, i in parts {
		if part == "" { return }
		for c in part { if c < '0' || c > '9' { return } }
		n[i] = strconv.parse_int(part, 10) or_return
		if n[i] > 65535 { return }   // (each is a 16-bit word of the VERSIONINFO)
	}
	return n, true
}

// The application manifest of the program at version `v`.
windows_manifest :: proc(p: Project, v: [3]int, allocator := context.temp_allocator) -> string {
	// (the assembly's name: letters, digits, dots and hyphens; the AppUserModelID is such a name already)
	aumid := project_aumid(p)
	b := strings.builder_make(context.temp_allocator)
	for c in (aumid != "" ? aumid : p.name) {
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '-' { strings.write_rune(&b, c) }
	}
	identity := strings.to_string(b)
	if identity == "" { identity = "program" }
	// (the name is put in by a plain replace, never by fmt: the supportedOS GUID's braces are fmt's argument indexes,
	// and fmt.aprintf turned "{8e0f7a12-…}" into "%!(BAD ARGUMENT NUMBER)…": Windows refused the manifest, error 14001)
	out, _ := strings.replace_all(WINDOWS_MANIFEST, MANIFEST_NAME_MARK, identity, allocator)
	return out
}

@(private = "file")
MANIFEST_NAME_MARK :: "{{name}}"

// (the assembly's name at {{name}}. The manifest is the one papier and Wren start with on Windows: a version 1.0.0.0 on
// amd64, run as the user, Windows 10 and 11, per-monitor DPI; the program's version is in the VERSIONINFO, where
// Explorer reads it. Nothing of the toolkit needs Common Controls 6, and it calls the wide (UTF-16) functions.)
@(private = "file")
WINDOWS_MANIFEST :: `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <assemblyIdentity type="win32" name="{{name}}" version="1.0.0.0" processorArchitecture="amd64"/>
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security>
      <requestedPrivileges>
        <requestedExecutionLevel level="asInvoker" uiAccess="false"/>
      </requestedPrivileges>
    </security>
  </trustInfo>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application>
      <!-- Windows 10 and 11 -->
      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
    </application>
  </compatibility>
  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    <windowsSettings>
      <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true/pm</dpiAware>
      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2</dpiAwareness>
    </windowsSettings>
  </application>
</assembly>
`

// The resource script of the program at version `v`: its icon and its manifest are the files at `icon` and `manifest`
// (absolute: rc.exe reads them from where odin runs it).
windows_resource_script :: proc(p: Project, v: [3]int, icon, manifest: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "// Written by the project's tool (gt:toolbox, build_windows) from its Project: do not edit.\r\n")
	strings.write_string(&b, "#pragma code_page(65001)\r\n\r\n")   // (the texts are UTF-8)
	fmt.sbprintf(&b, "1 ICON \"%s\"\r\n", rc_text(icon))
	fmt.sbprintf(&b, "1 24 \"%s\"\r\n\r\n", rc_text(manifest))   // (24: RT_MANIFEST; 1: the manifest a process starts with)
	fmt.sbprintf(&b, "1 VERSIONINFO\r\nFILEVERSION %d,%d,%d,0\r\nPRODUCTVERSION %d,%d,%d,0\r\n", v[0], v[1], v[2], v[0], v[1], v[2])
	// (VOS_NT_WINDOWS32, VFT_APP)
	strings.write_string(&b, "FILEFLAGSMASK 0x3fL\r\nFILEFLAGS 0x0L\r\nFILEOS 0x40004L\r\nFILETYPE 0x1L\r\nFILESUBTYPE 0x0L\r\nBEGIN\r\n")
	strings.write_string(&b, "    BLOCK \"StringFileInfo\"\r\n    BEGIN\r\n        BLOCK \"040904B0\"\r\n        BEGIN\r\n")
	version := fmt.tprintf("%d.%d.%d", v[0], v[1], v[2])
	title := project_title(p)
	values := [?][2]string{
		{"CompanyName", p.publisher},
		{"FileDescription", title},   // (Task Manager's name of the process)
		{"FileVersion", version},
		{"InternalName", p.name},
		{"LegalCopyright", p.copyright},
		{"OriginalFilename", fmt.tprintf("%s.exe", p.name)},
		{"ProductName", title},
		{"ProductVersion", version},
		{"Comments", p.description},
	}
	for value in values {
		if value[1] == "" { continue }
		fmt.sbprintf(&b, "            VALUE \"%s\", \"%s\"\r\n", value[0], rc_text(value[1]))
	}
	strings.write_string(&b, "        END\r\n    END\r\n")
	// (U.S. English, Unicode: the strings above)
	strings.write_string(&b, "    BLOCK \"VarFileInfo\"\r\n    BEGIN\r\n        VALUE \"Translation\", 0x0409, 1200\r\n    END\r\nEND\r\n")
	return strings.to_string(b)
}

// `s` inside an rc string: a quote doubled, a backslash too (rc reads escapes in strings).
@(private = "file")
rc_text :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, "\\", "\\\\", context.temp_allocator)
	out, _ = strings.replace_all(out, "\"", "\"\"", context.temp_allocator)
	return out
}

// Writes the program's resource script and manifest in `dir`, each only when it changes (rc.exe does not run again).
// why: "" when both are there.
write_windows_resource :: proc(p: Project, dir := WINDOWS_RESOURCE_DIR) -> (why: string) {
	version := project_version(p)
	v, ok := version_numbers(version)
	if !ok { return fmt.tprintf("%s: %q is not a version of three numbers", p.version_file, version) }
	icon := project_icon(p)
	if !os.exists(icon) { return fmt.tprintf("%s is not there: the tool's logo command writes it (Project.icon)", icon) }
	icon_abs, err := os.get_absolute_path(icon, context.temp_allocator)
	if err != nil { return fmt.tprintf("%s: %v", icon, err) }
	manifest := fmt.tprintf("%s/%s.manifest", dir, p.name)
	if !fsx.make_dirs(dir) { return fmt.tprintf("%s cannot be made", dir) }
	if !write_if_changed(manifest, windows_manifest(p, v)) { return fmt.tprintf("%s cannot be written", manifest) }
	manifest_abs, merr := os.get_absolute_path(manifest, context.temp_allocator)
	if merr != nil { return fmt.tprintf("%s: %v", manifest, merr) }
	script := windows_resource_path(p, dir)
	if !write_if_changed(script, windows_resource_script(p, v, icon_abs, manifest_abs)) { return fmt.tprintf("%s cannot be written", script) }
	return ""
}

// Writes `text` at `path` unless the file holds it already.
@(private)
write_if_changed :: proc(path, text: string) -> bool {
	if old, err := os.read_entire_file(path, context.temp_allocator); err == nil && string(old) == text { return true }
	_ = os.make_directory_all(filepath.dir(path))
	return os.write_entire_file(path, transmute([]u8)text) == nil
}
