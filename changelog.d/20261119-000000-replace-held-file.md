type: Fixed

**A file another program reads is still written on Windows.** `fsx.write_atomic` replaced a file in one try: while a
reader, an antivirus or the indexer held it, the write failed and the settings it held were lost. It tries again a few
times now; plugins.toml is also written again after a failed write.
