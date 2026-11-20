type: Fixed

**A Wayland window takes the refresh rate of the monitor it is on** (`platform.display_info`): it read the first monitor's, and a window on a 144 Hz monitor beside a 60 Hz one was held to 60 frames a second by its pacer. The rate is now that of the outputs the window is on (the highest when it spans several), and the pacer replans when the window moves to another monitor. The first frame after a rest moves an animation by one refresh of that monitor, not by 1/60 s, wherever the renderer measures no refresh (Linux); `host.DT_RESTED_S` is gone.
