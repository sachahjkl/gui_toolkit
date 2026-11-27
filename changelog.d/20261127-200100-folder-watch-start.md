type: Fixed

**A folder followed misses no change made as it is opened**: a file made in a folder just opened in `ui.file_tree` (or the picker's folder) at once came only at the next change, or never; a folder is now read again once its watch begins. On Windows, setting the folders followed no longer loses a change made at that moment in a folder already followed.
