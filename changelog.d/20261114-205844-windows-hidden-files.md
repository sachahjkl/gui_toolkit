type: Fixed

**The file browser hides the files that Windows marks hidden**: on Windows, a file or folder with the hidden attribute is now hidden in the folder shown and in the search in subfolders, until Hidden files (Ctrl+H) is on, as in Explorer. Before, only names that start with "." were hidden. A system file without the hidden attribute stays shown. `fsx.read_folder` gives a folder's entries with the system's hidden mark.
