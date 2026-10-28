type: Added

**Linux tray icon and notifications** (`platform`): `tray_create` / `tray_notify` and the rest of the tray API now work on Linux through the StatusNotifierItem specification over D-Bus, with its menu as a `com.canonical.dbusmenu` tree and notifications through `org.freedesktop.Notifications` (clicks, chosen menu items and notification results come back as `Tray_Event`s). Same public API as the Windows backend; `tray_create` returns nil when there is no status-notifier host, as Windows does when the shell refuses an icon.
