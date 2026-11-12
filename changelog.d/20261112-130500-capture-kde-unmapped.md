type: Fixed

**A window closed no longer ends the capture session on ShojiWM**: when KDE's window management protocol said a window was gone, `gt:capture` asked the compositor to destroy its object, which ShojiWM refused with a protocol error that closed the connection.
