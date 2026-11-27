type: Fixed

**A test's folder is a Windows path as the system writes it**: `testkit.temp_folder` and `fsx.temp_dir` give backslashes alone and long names (`C:\Users\runneradmin\AppData\Local\Temp\gui_toolkit-...`, not `C:\Users\RUNNER~1\...\Temp/gui_toolkit-...`), with no separator at the end. A program's test that compared it with a path from the system failed on the CI. A session's folder (`build/session/<test>`) is joined the same way.
