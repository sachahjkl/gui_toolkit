# http: one GET

`import http "gt:http"` (the package is named `tk_http`: a program may have an `http` package of its own). One GET over
HTTP or HTTPS with what the system has: WinHTTP on Windows (its proxy settings and certificates), libcurl on Linux, loaded at
run time (`libcurl.so.4`: a program that never asks for a URL starts on a system without it). It blocks: call it on a thread
of its own.

```odin
status, body, err := http.get("https://github.com/me/app/releases/latest/download/update-linux-x64.json",
                              {max_bytes = 16 * 1024, user_agent = "app/1.2.3", timeout = 30 * time.Second})
```

- Redirects are followed (at most `MAX_REDIRECTS`; Windows never follows https to http).
- `status` is the status of the last answer. A status that is not 2xx is no error: the caller reads it (404: no such file).
- `max_bytes` bounds the body (0: `MAX_BYTES`, 64 MiB): a larger one is `.Too_Large`, and nothing is returned.
- `timeout` bounds the whole request (0: `TIMEOUT`, 5 minutes).
- `Error`: `No_Client` (Linux without libcurl), `Bad_Url` (not http or https, credentials in the address), `Unreachable` (the
  name, the network, TLS, the time limit), `Too_Large`. `error_text` says it in a sentence.

`url_parse` gives the parts of an http or https URL (secure, host, port, path with its query).

The Updater (`docs/update.md`) downloads with it.
