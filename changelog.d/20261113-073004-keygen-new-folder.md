type: Fixed

**`update keygen` writes a key into a folder that does not exist yet.** It refused such a path as if it were in a git work tree; it now checks from the nearest folder that exists, and makes the folder.
