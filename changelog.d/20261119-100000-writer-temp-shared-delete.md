type: Fixed

**A download's part file goes at the program's end on Windows**: another thread can remove an `fsx.Writer`'s temporary
file while the writer still holds it open; the file goes when that writer closes it, instead of staying.
