type: Added

**Views with instances reopen at start**: each instance of a view (a journal per service, a terminal per shell) has its own line in the views' memory, with its presentation and its place. `ui.view_restored_instances(vs, id)` lists the instances open at the last quit; the program reopens each with its own data, and each opens where it was. `view_was_open(vs, id, instance)` now reads that instance's line.
