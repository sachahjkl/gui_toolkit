type: Fixed

**`config.save_user`** goes through `fsx.write_atomic`, flushed: a save that fails never removes the profile, and leaves no temporary file.
