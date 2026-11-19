type: Changed

**`file_thumbnail_make` answers a `File_Thumbnail`**: its pixels and their size, and the size of the picture it was
made from, so an inspector shows that size without decoding the file again. `file_thumbnail_decodes(name)` says which
files the toolkit decodes.
