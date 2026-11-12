type: Fixed

**Text selected in a dialog is copied**: Ctrl+C did nothing on text selected in a dialog, since a dialog holds the keys and the selection reads them after the dialogs are built. The selection now has its keys when it is in the dialog on top (Ctrl+C, Ctrl+Insert, Shift and the arrows, Ctrl+A), and Ctrl+Insert copies a selection everywhere.
