type: Fixed

**A program built by the toolkit starts on Windows: the real cause**: the builder made the application manifest with `fmt.aprintf`, which read the braces of the Windows 10 compatibility GUID (`{8e0f7a12-…}`) as an argument index and wrote "%!(BAD ARGUMENT NUMBER)" into the manifest; Windows refused it (error 14001). The program's name is now put in by a plain replace, and a test checks the GUID comes out whole. 0.252.1 and 0.253.1 changed the manifest's content and did not fix it.
