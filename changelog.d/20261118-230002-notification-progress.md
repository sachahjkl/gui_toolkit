type: Added

**`platform.Notification.progress`**: a notification shows a progress bar (a value from 0 to 1, or not known, and the words under it), and a `replace` with a new value moves it in place. Windows 10 1607 and later: the toast's bar, updated without a new popup or sound while the rest of the notification stays the same (`notification_shape`). Linux: the `value` hint that KDE Plasma, dunst, mako and Xfce draw; the words are a line of the body. A system without a bar shows the notification without it.
