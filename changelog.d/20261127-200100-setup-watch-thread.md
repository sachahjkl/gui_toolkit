type: Fixed

**The setup no longer waits on the disk when it opens**: the dialog and the Installation page start and stop the watch of the install's places on a thread of their own, and the window no longer freezes while the options are read and the places opened. `setup.watching(&d)` says when the watch runs.
