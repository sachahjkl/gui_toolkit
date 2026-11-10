type: Fixed

**`setup.facts`**: on Windows, a program installed in the default folder (`%LOCALAPPDATA%\Programs\<name>`, or an `install_folder` that is the same path) was taken for an install "to repair" after its restart: the record of the default folder counted as no record. `desktop.install_recorded` reads the record alone.
