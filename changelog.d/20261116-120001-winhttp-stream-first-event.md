type: Fixed

**A server's events arrive at once on Windows**: an event stream read whole chunks and waited for one to fill, so a live server's first event never came and a program never saw its server online; it reads what has come.
