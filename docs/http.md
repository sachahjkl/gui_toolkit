# http: requests over HTTP and HTTPS

`import http "gt:http"` (the package is named `tk_http`: a program may have an `http` package of its own). Requests over
HTTP or HTTPS with what the system has: WinHTTP on Windows (its proxy settings and certificates), libcurl on Linux, loaded at
run time (`libcurl.so.4`: a program that never asks for a URL starts on a system without it). Every request blocks: call it
on a thread of its own.

## A GET

```odin
status, body, err := http.get("https://github.com/me/app/releases/latest/download/update-linux-x64.json",
                              {max_bytes = 16 * 1024, user_agent = "app/1.2.3", timeout = 30 * time.Second})
```

- Redirects are followed (at most `MAX_REDIRECTS`; Windows never follows https to http).
- `status` is the status of the last answer. A status that is not 2xx is no error: the caller reads it (404: no such file).
- `max_bytes` bounds the body (0: `MAX_BYTES`, 64 MiB): a larger one is `.Too_Large`, and nothing is returned.
- `timeout` bounds the whole request (0: `TIMEOUT`, 5 minutes).

## Any request

```odin
form, content_type := http.multipart({
	http.form_text("reqtype", "fileupload"),
	http.form_file("fileToUpload", "shot.png", "image/png", png),
}, context.temp_allocator)
res, err := http.request("POST", "https://example.com/upload", {
	headers = {{"Content-Type", content_type}, {"Authorization", "Bearer ..."}},
	body    = form,
})
defer http.response_destroy(&res)
location, found := http.header_value(res.headers, "Location")
```

- `request(method, url, req)`: any method that is a token (GET, POST, PUT, PATCH, DELETE, HEAD...). `get` is a call of it.
- `Request.headers` are sent as given; a header the caller names replaces the client's own (the User-Agent too). Nothing
  is added to a body: without a `Content-Type` header, none is sent (libcurl's form type and its `Expect: 100-continue`
  are removed).
- `Request.body`: nil sends none; POST, PUT and PATCH send an empty one then.
- A method that is not a token, a header name that is not a token, or a header value with a line break is `.Bad_Request`,
  before anything is sent.
- `Response`: `status`, `body`, `headers` (the last answer's, in order), `url` (the address that answered, after the
  redirects), `header_text` (the lines as received). `response_destroy` frees it, with the request's allocator.
- `header_value(headers, name)`: the first header of that name; names compare without case.
- A redirect of a request with a body is followed as browsers do: 303 (and 301, 302 after a POST) becomes a GET.

## Form bodies

Pure procedures: no system call, testable anywhere.

- `multipart(fields)` gives a `multipart/form-data` body and its `Content-Type` with the boundary. A `Form_Field` is a text
  (`form_text(name, value)`) or a file (`form_file(name, file_name, content_type, bytes)`; an empty content type is
  `application/octet-stream`). The boundary is random and occurs in no field. A quote or a line break in a name or file
  name is written `%22`, `%0D`, `%0A`, as browsers do.
- `form_urlencoded(params)` gives an `application/x-www-form-urlencoded` body from `Param`s: `a=1&b=x+y`.
- `query_append(url, params)` adds params to a URL's query string (`?` or `&`, before a fragment).
- `form_encode(s)` encodes one name or value: letters, digits and `*-._` stay, a space is `+`, any other byte is `%XX`.

## Errors

`Error`: `No_Client` (Linux without libcurl), `Bad_Url` (not http or https, credentials in the address), `Bad_Request`,
`Unreachable` (the name, the network, TLS, the time limit), `Too_Large`. `error_text` says it in a sentence.

`url_parse` gives the parts of an http or https URL (secure, host, port, path with its query).

The Updater (`docs/update.md`) downloads with it.
