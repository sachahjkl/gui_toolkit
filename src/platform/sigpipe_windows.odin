package platform

// Windows has no SIGPIPE: a write to a closed pipe is an error of that write.
sigpipe_ignore :: proc() {}
