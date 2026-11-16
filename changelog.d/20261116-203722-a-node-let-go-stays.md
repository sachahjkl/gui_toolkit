type: Fixed

**A node let go in `ui.node_graph` stays where it was let go.** The frame of the release drew the moved nodes back at their old place, before the program applied `Graph_Moved`: they jumped there and back, and the widgets in them glided both ways.
