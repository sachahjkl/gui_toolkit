type: Fixed

**A WebSocket to the loopback needs no libcurl (Linux)**: `ws://127.x.x.x` and `ws://[::1]` connect over a TCP connection of the package's own, so `gt:cdp` drives a program from a shell without curl again; since 0.287.0 `cdp.connect` failed there (`ws_connect` answered `.No_Client`) and a program's live test stopped at "the window serves the DevTools protocol".
