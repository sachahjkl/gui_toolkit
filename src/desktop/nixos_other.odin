#+build !linux
package tk_desktop

// Not NixOS: it is a Linux.
is_nixos :: proc() -> bool { return false }

// Nothing to adapt: a plan asks for it on NixOS only.
nixos_adapt :: proc(id: Identity, dir, exe_name: string, files: ^[dynamic]string) -> Result { return {} }
