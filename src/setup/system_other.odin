#+build !windows
package tk_setup

// No record of the installed programs that a person sees: the install's record is its icons (a desktop entry's).
SYSTEM_RECORD :: false
// On the PATH, the program alone: a shell's terminal is its console already.
PATH_LAUNCHER :: false
