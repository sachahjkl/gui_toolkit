type: Fixed

**`http.request` reuses its connections**: requests to a server go on the connections already open (keep-alive) instead of a TCP connection and a TLS handshake each; one pool for the process, safe from any thread, with no client to keep (Linux: idle libcurl handles matched by origin, at most `POOL_IDLE`; Windows: one WinHTTP session). Five requests in a row now open one connection, not five.
