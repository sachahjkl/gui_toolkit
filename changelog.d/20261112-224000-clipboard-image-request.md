type: Added

**An image asked from the clipboard comes without a wait**: `platform.clipboard_request(w, .Image)` answers with the image as its owner holds it, still encoded (`Clipboard_Reply.data` and `.mime`: PNG, JPEG, BMP, or a Windows DIB as `image/x-dib`), which `platform.clipboard_image_decode` turns into pixels on any thread. On Linux the read stops at the first type that came.
