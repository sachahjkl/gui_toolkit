type: Fixed

**A Markdown table's stripes run from side to side, square**: a striped row stood off the frame's sides with its own rounded corners, a curve inside the frame's curve. Its rows are square and clipped to the frame's inside, where a row that reaches a corner takes the frame's curve: only the frame is rounded. `ui.clip_inside_open` and `clip_inside_close` clip what a rounded frame holds to its inside (`clip_inside_push` from a custom draw, as a floating dock panel does); a table's or a code block's frame has its radius even when the program draws it.
