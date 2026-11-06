type: Changed

**`instance.Owner_State`**: an `Owner` says where it is (`None`, `Claimed`, `Serving`, `Closing`) in `Owner.state`, which replaces `Owner.closing`. A second `owner_start` answers false and opens nothing, a file descriptor 0 is one like any other, and a window that could not be destroyed no longer points at its Owner.
