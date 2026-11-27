type: Fixed

**A program a tool starts draws on the CPU, never the GPU**: `toolbox.program_session_start` gives the program Mesa's lavapipe as its only Vulkan driver and turns the implicit layers off, so a program's live tests and pictures no longer take the machine's graphics card (an NVIDIA one included) and match the CI's. A machine without lavapipe does not start the program and says why; `Program_Options.gpu` keeps the machine's own driver for a demo a person watches.
