#+build !linux
package tk_desktop

// Not NixOS: it is a Linux.
is_nixos :: proc() -> bool { return false }
