type: Changed

**`term`**: the grid draws each row as a retained picture keyed by the row's content: a line printed records one row, and the rows it moves up replay their pictures. In opencode native, a grid at rest costs 0.009–0.019 ms of the interface's thread instead of 0.21 ms, and a line printed costs 0.47 ms instead of 0.66 ms. On a screen of 40 by 120 cells (`-define:TERM_TIMING=true`), a draw at rest costs 0.02 ms instead of 0.9 ms. `View.rows_recorded` counts the recordings.
