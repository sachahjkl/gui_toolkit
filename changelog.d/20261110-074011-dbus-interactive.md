type: Added

**`dbus.call` / `call_async` `interactive`**: the call carries ALLOW_INTERACTIVE_AUTHORIZATION, so a service that checks with polkit (systemd on a system unit) can ask the user for a password instead of refusing.
