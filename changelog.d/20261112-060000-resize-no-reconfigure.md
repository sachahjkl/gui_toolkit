type: Fixed

**A resize costs less on Wayland**: the swap chain was reconfigured for every size the compositor asked for, also those no picture was drawn at (while the last picture waited to be shown), about three reconfigures for each picture shown; it now takes the window's size only with a picture drawn.
