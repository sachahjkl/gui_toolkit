type: Fixed

**The command palette appears at once, with its rows.** It opened after three or four unseen frames, began to fade in before its rows had come, jumped when a frame was late, and redrew the whole window before it showed. Now a dialog of a known size shows in its first frame; a view can say its content is not ready yet (`ui.view_not_ready`), and its dialog waits for it, 100 ms at most; the palette waits for its first ranking; a dialog's fade moves by 25 ms a frame at most, and the palette's lasts 70 ms (`View_Options.quick`); and an unseen dialog redraws nothing.
