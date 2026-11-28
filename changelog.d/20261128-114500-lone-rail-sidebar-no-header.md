type: Fixed

**A lone sidebar with its own compact rail keeps no extra header bar.** Sidebars that declare `View_Options.rail_em`
own their top row with `ui.view_fold_button`; skipping `view_lone_header` for them removes the extra bar above the
sidebar and keeps the fold button at the same pixel across fold and unfold.
