type: Added

**A tool bar's tool opens a menu**: `ui.toolbar_tool(id, {..., menu = "insert_menu"})` opens the menu that the program builds as always (`if ui.menu("insert_menu") { ... }`, outside the bar). In the bar the menu opens under the tool, which stays lit while it is open. Folded into the "…" menu, the tool is a submenu row, and the same block builds its submenu, by the pointer or by the keyboard. The spacing of a tool bar is now one rule for every program: 0.2 em between two tools, 0.5 em between two controls, 0.8 em between two groups or a separator's room, all following the density.
