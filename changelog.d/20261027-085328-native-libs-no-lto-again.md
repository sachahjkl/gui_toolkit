type: Changed

**The native libraries are built without fat LTO again** (	ools/build_text.ps1, 	ools/build_a11y.ps1): with it (gt_text.lib 6.4 MB instead of 33 MB) the 	ext tests crashed on the CI runner at their first test (tlas_stress, a signal) while they pass on a development machine; the cause is not found, the size is not worth a crashing test run. Wren builds these crates into its own library and is not affected.
