type: Fixed

**`install_init` with a new settings registry**: called again with another registry (a program that reads its
settings anew), it moves its watch of "In the application menu" and "Start with the session" to the new one, instead
of keeping an id that named another observer there; the refusal's message is in French too.
