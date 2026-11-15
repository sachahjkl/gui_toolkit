# secrets: secrets sealed for the user

`import secrets "gt:secrets"` (the package is named `tk_secrets`: a program may have a `secrets` package of its own).
It seals a secret (a password, a token) for the user's account. The program keeps in its own file only a field that
stands for the secret.

- Windows: DPAPI for the current user. The field is `dpapi:v1:` and the base64 of the encrypted blob. Only this
  Windows account can open it.
- Linux: the Secret Service (`org.freedesktop.secrets`) over the session bus, in its default collection. The field is
  `secret-service:v1:<name>`: the secret stays in the service's item, and the field names that item.
- Other systems: no store. `seal` is `.Unavailable`, `open` of a sealed field is `.Refused`.

Every call can wait on the system (a D-Bus round trip, DPAPI). Call it on a worker (`gt:tasks`, `ui.task`), never in a
frame. The package keeps no state.

## Seal and open

```odin
field, sealed := secrets.seal("my-app", "server 1", password)
switch sealed {
case .Sealed:      // write `field` to the program's file
case .Unavailable: // the program decides: keep the password in clear and say so, or refuse
}

password, opened := secrets.open("my-app", field)
switch opened {
case .Opened:     // use `password`
case .Not_Sealed: // `field` is not seal's work: a value in clear from an older version, for example
case .Refused:    // seal's work, but it cannot be opened here: another account or system, a locked keyring, the item gone
}
```

- `app` names the program. On Linux it is the item's `application` attribute and the start of its label
  (`<app>: <name>`). Give the same `app` to every call.
- `name` names the secret in the program. On Linux it is the item's `name` attribute. A seal with the same `app` and
  `name` replaces the item. The field keeps the name: a thing renamed later keeps its item while it keeps its field.
- `field` and `secret` are allocated with the `allocator` argument (default `context.allocator`).
- The package never writes a secret in clear. When `seal` is `.Unavailable`, the program chooses what to do.
- On Linux, a locked keyring makes `seal` `.Unavailable` and `open` `.Refused`. The package shows no unlock prompt.

## Forget and available

```odin
secrets.forget("my-app", field)   // Linux: deletes the service's item. Windows: nothing (the field holds the secret).
up := secrets.available()         // Linux: a Secret Service answers. Windows: true. Elsewhere: false.
```

- `forget` of a field that is not seal's work does nothing.
- `available` is true on Linux when the service answers, even if its keyring is locked: only `seal` tells.
- A program that shows whether the store is there asks `available` on a worker and keeps the answer itself.

## Marks

`secrets.is_sealed(field)` tells whether a field starts with `DPAPI_MARK` or `SERVICE_MARK`, on any system. A field of
the other system's mark is `.Refused`, never `.Not_Sealed`: a program never reads it as a value in clear.

The design: [src/md/features/secrets.md](../src/md/features/secrets.md).
