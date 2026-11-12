type: Changed

**A long list costs nothing when it does not change**: a `vlist` makes its rows' offsets again only when its ids or a measured height change, so a frame of a list of 100 000 rows that changed nothing does no pass over them. `vlist` takes an `ids_version` (the program's count of the changes of its ids) to skip even the comparison of the ids.
