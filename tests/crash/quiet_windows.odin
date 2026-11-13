package crash_test

foreign import kernel32 "system:Kernel32.lib"

@(private = "file", default_calling_convention = "system")
foreign kernel32 {
	SetErrorMode :: proc(uMode: u32) -> u32 ---
}

@(private = "file") SEM_FAILCRITICALERRORS :: 0x0001
@(private = "file") SEM_NOGPFAULTERRORBOX :: 0x0002

// The child's crash shows no "stopped working" window, which would wait for a click.
quiet_faults :: proc "contextless" () {
	SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX)
}
