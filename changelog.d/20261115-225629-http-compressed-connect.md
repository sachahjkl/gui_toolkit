type: Added

**`gt:http`: compressed answers and a bound on the connection**: `Request.compressed` asks for gzip or deflate and gives the body decoded (`max_bytes` counts decoded bytes), for a request and an event stream; `Request.connect_timeout` bounds the name's lookup and the connection of a request, a stream and a socket (0: `timeout`).
