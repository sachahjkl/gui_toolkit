type: Added

**The first frame on the CPU on Windows**: with Direct3D 11, a translucent window shows its first frame drawn on the CPU through a WARP device's swap chain on its own DirectComposition visual, and the hardware device's chain replaces it at its first present, in the same commit; a window without composition shows it through GDI until its swap chain presents. Not yet run on a Windows machine.
