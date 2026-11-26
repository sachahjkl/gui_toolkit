package tk_desktop

// The system scope on Windows (src/md/features/install-scope.md): the program in %ProgramFiles%\<vendor>\<name>, the
// Start menu of every account, HKLM's record, classes and PATH; an administrator allows them through runas.

import "base:runtime"
import "core:fmt"
import "core:strings"
import win "core:sys/windows"
import i18n "../i18n"
import "../process"

@(private = "file") POLICIES_KEY :: `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System`

// How long the verb is awaited, in milliseconds: the person answers the consent prompt first.
@(private = "file") MACHINE_WAIT_MS :: 10 * 60 * 1000

// (winerror.h: the person declined the consent prompt)
@(private = "file") ERROR_CANCELLED :: 1223

// A standard account whose prompts are refused by policy, or an account under UAC that is off: no one can be asked. An
// administrator's split token (TokenElevationTypeLimited) can always be raised.
@(private)
system_refusal_here :: proc() -> System_Refusal {
	if elevation_type() == .Limited { return .None }
	lua, _ := reg_get_dword(POLICIES_KEY, "EnableLUA")
	if lua == 0 { return .No_Elevation }
	behaviour, has := reg_get_dword(POLICIES_KEY, "ConsentPromptBehaviorUser")
	if has && behaviour == 0 { return .No_Elevation }
	return .None
}

@(private)
no_elevation_words :: proc() -> string {
	return i18n.tr("No administrator can be asked from this account: Windows refuses its requests.")
}

@(private = "file")
Elevation_Type :: enum u32 { Default = 1, Full = 2, Limited = 3 }

@(private = "file")
elevation_type :: proc() -> Elevation_Type {
	token: win.HANDLE
	if !win.OpenProcessToken(win.GetCurrentProcess(), win.TOKEN_QUERY, &token) { return .Default }
	defer win.CloseHandle(token)
	t: u32
	size: win.DWORD
	if !win.GetTokenInformation(token, .TokenElevationType, &t, size_of(t), &size) { return .Default }
	return Elevation_Type(t)
}

// <root>\Program Files\<vendor>\<name>, or %ProgramFiles%\<vendor>\<name> by the known-folder API (a variable of the
// environment can move %ProgramFiles%; the known folder cannot).
@(private)
system_install_dir_here :: proc(o: ^Integration_Options, root: string, allocator: runtime.Allocator) -> string {
	if !folder_name_ok(o.identity.name) { return "" }
	pf := root != "" ? strings.concatenate({root, "\\Program Files"}, context.temp_allocator) : known_folder(win.FOLDERID_ProgramFiles)
	if pf == "" { return "" }
	if !folder_name_ok(o.identity.vendor) { return strings.concatenate({pf, "\\", o.identity.name}, allocator) }
	return strings.concatenate({pf, "\\", o.identity.vendor, "\\", o.identity.name}, allocator)
}

// The Start menu's Programs of every account (FOLDERID_CommonPrograms), or the test's.
@(private)
machine_programs_folder :: proc(o: ^Integration_Options) -> string {
	if root := machine_root_of(o); root != "" { return strings.concatenate({root, "\\Start Menu\\Programs"}, context.temp_allocator) }
	return known_folder(win.FOLDERID_CommonPrograms)
}

// HKEY_LOCAL_MACHINE as a path (reg_* read the hive from it), or the test's key under HKCU.
@(private)
machine_hive :: proc(o: ^Integration_Options) -> string {
	if machine_root_of(o) != "" && o.machine_registry_root != "" { return o.machine_registry_root }
	return "HKLM"
}

// Program Files gives what is made in it the folder's rights: only an administrator writes there. Nothing to check.
@(private)
machine_prepare :: proc(o: ^Integration_Options, dir: string) -> Result { return {} }

@(private)
self_image_place :: proc(exe: string) -> Result { return image_copy_self(exe) }

// A file that runs cannot be deleted: it is put aside and goes at the next restart (a folder too, once empty).
@(private)
remove_at_restart :: proc(path: string) {
	if !win.DeleteFileW(wide(path)) && !win.RemoveDirectoryW(wide(path)) { _ = win.MoveFileExW(wide(path), nil, win.MOVEFILE_DELAY_UNTIL_REBOOT) }
}

// Runs the elevated verb as an administrator (runas: Windows asks the person, or the credentials of an administrator
// on a standard account) and waits for it.
machine_elevate :: proc(o: ^Integration_Options, exe: string, arguments: []string) -> Result {
	params := strings.join(arguments, " ", context.temp_allocator)
	info := win.SHELLEXECUTEINFOW{
		cbSize = size_of(win.SHELLEXECUTEINFOW),
		fMask = win.SEE_MASK_NOCLOSEPROCESS | win.SEE_MASK_NOASYNC | win.SEE_MASK_FLAG_NO_UI,
		hwnd = win.GetForegroundWindow(),   // (the consent prompt comes over the window the person clicked in)
		lpVerb = win.L("runas"),
		lpFile = wide(exe),
		lpParameters = wide(params),
		lpDirectory = wide(process.parent_dir(exe)),
		nShow = win.SW_HIDE,
	}
	if !win.ShellExecuteExW(&info) {
		if win.GetLastError() == ERROR_CANCELLED { return {.Not_Allowed, error_text(.Not_Allowed)} }
		return {.Machine, fmt.tprintf("the change for every account could not start (error %d)", win.GetLastError())}
	}
	if info.hProcess == nil { return {.Machine, "the change for every account gave no process"} }
	defer win.CloseHandle(info.hProcess)
	if win.WaitForSingleObject(info.hProcess, MACHINE_WAIT_MS) != win.WAIT_OBJECT_0 { return {.Machine, "the change for every account did not end"} }
	code: win.DWORD
	if !win.GetExitCodeProcess(info.hProcess, &code) || code != 0 { return {.Machine, fmt.tprintf("the change for every account failed (exit code %d)", code)} }
	return {}
}
