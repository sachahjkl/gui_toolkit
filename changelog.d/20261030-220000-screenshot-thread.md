type: Fixed

**A screenshot of a real window took two seconds and froze it**: the wake asked for its next frame was consumed by the frame already starting, so the window slept until its next timer (about 1.2 s); reading a translucent window's fp16 target back ran `pow` on every channel (now a table); the PNG was encoded on the UI thread (now `flate.deflate_runs`, made for rate, on a thread of its own). A timeline keeps its pictures in memory and compresses, compares and writes them when it ends. An offscreen window keeps its wakes, so the end-to-end run never saw the first one.
