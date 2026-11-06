type: Fixed

**`draw`**: an offscreen target left open is dropped at the end of the frame (it was composited, left its transform on the stack and cut the filters of the layers around it), and a plane left open in a recording ends with the recording (it took the frame's stacks down at `end_frame`).
