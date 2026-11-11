type: Fixed

**A table read again stays where it was scrolled**: `table_apply` brought the selected row back into view at each new reading with no filter, so a list refreshed every second could not be scrolled away from it. Only a filter cleared brings it now.
