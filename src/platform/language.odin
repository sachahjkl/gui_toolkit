package platform

// The language of the system's interface, as a language tag ("fr-FR", "en-GB"; "" when the system says none), in
// `allocator`. Read when asked: a program reads it once, at the start (its general.language setting's "system").
system_language :: proc(allocator := context.allocator) -> string { return system_language_read(allocator) }
