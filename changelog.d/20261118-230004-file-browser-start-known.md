type: Fixed

**The toolkit's file browser opens in `File_Dialog.start_known`**: a dialog asked to start in Downloads (or another folder the system names) now opens there, after `start_dir` and the folder the dialog was last left in. A program's source answers it with `File_Source.known`; a source without such folders starts as before.
