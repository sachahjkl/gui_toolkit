# winrt: Windows Runtime APIs from Odin

`import winrt "gt:winrt"` (the package is named `tk_winrt`). It calls Windows Runtime APIs with no projection: a program
declares the vtables of the interfaces it uses (in the order of the SDK's headers, or of `windows-rs`), and this package
gives the rest.

```odin
winrt.init()                                             // once per thread: the multithreaded apartment
statics, hr := winrt.factory("Windows.Storage.PathIO", IID_IPathIOStatics)
defer winrt.release(statics)

op: rawptr
winrt.vtable(statics, IPathIOStatics_Vtbl).ReadTextAsync(statics, path, &op)
_, handler := winrt.async_iids(winrt.SIG_STRING)          // AsyncOperationCompletedHandler<HSTRING>
text: winrt.HSTRING
if winrt.ok(winrt.await(op, handler, &text)) { fmt.println(winrt.string_read(text)) }
winrt.string_delete(text)
```

## What it has

| | |
|---|---|
| `init(apartment)`, `uninit` | the thread joins an apartment: `.Multi` (the default) or `.Single` (some APIs, the clipboard's, refuse the other: `RO_E_UNSUPPORTED_FROM_MTA`); a `.Single` thread pumps its messages |
| `string_make`, `string_read`, `string_delete` | HSTRINGs from and to UTF-8 |
| `factory`, `activate` | a class's statics or activation factory; a new instance of a class with a default constructor |
| `vtable(object, T)`, `query`, `release` | an interface's methods; another interface of an object; the end of a reference |
| `await(operation, handler_iid, &result, timeout_ms)` | waits for an `IAsyncOperation<T>` and writes its result; past the timeout (10 s by default) it cancels it |
| `event_handler_make(iid, callback, user, done)` | an event handler (`EventHandler<T>`, `TypedEventHandler<S, T>`) that calls `callback(user, sender, args)`; `done(user)` runs when the last reference goes |
| `vector_size`, `vector_at` | an `IVectorView<T>` |

## The IDs of generic instances

`IAsyncOperation<ClipboardHistoryItemsResult>` has no ID in any header: Windows computes it from the type's signature (a
UUID version 5, SHA-1). `piid_of(signature)` does the same; `sig_class`, `sig_interface`, `sig_generic` and `SIG_STRING`
write the signatures (`SIG_INSPECTABLE` for `Object`), and `async_iids(result)`, `event_handler_iid(args)` and
`typed_event_handler_iid(sender, args)` give the IDs a program needs most:

```odin
result := winrt.sig_class("Windows.ApplicationModel.DataTransfer.ClipboardHistoryItemsResult", IID_IClipboardHistoryItemsResult)
_, handler := winrt.async_iids(result)
```

This part is pure: its tests run on every system and check IDs of the SDK's headers.

## Threads

`await` blocks its thread until the operation ends, taking the COM calls made to the thread meanwhile
(`CoWaitForMultipleHandles`): call it from a thread of the program's own, not from the window's.
An event handler runs on the thread the source raises the event on: hand the work to the program's threads from there.
