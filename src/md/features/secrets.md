# Secrets sealed for the user

`gt:secrets` (`tk_secrets`) seals a secret (a password, a token) for the user's account. A program keeps a field in its
own file; the field stands for the secret. opencode native (its servers' passwords) and Wren (its keys) each had their
own copy of this; this package replaces both.

## Decisions

- **The system's store, not ours.** Windows: DPAPI for the current user, the field holds the blob. Linux: the Secret
  Service over the session bus, the field names the item. The system already ties these stores to the user's login.
- **A field with a mark and a version.** `dpapi:v1:` + base64, `secret-service:v1:` + the name. `open` knows its own work
  from a value in clear by the mark alone, without a call to the system. A field of the other system's mark is
  `Refused`, not `Not_Sealed`: a sealed field never passes for a password in clear (the file moved between systems).
- **The Linux field names the item.** The name is copied into the field at seal. A thing renamed later keeps the item
  that its field names, also while the keyring is locked and the item cannot be moved.
- **The item's attributes are `application` = app and `name` = name.** `app` keeps two programs apart in one keyring.
  The label `<app>: <name>` is what the user sees in a keyring manager.
- **Results are enums.** `Seal_Result` (`Sealed`, `Unavailable`) and `Open_Result` (`Opened`, `Not_Sealed`, `Refused`). Each
  case asks the program for a different action; two booleans let the program confuse them.
- **A locked keyring is no store.** `CreateItem` answered with the path `/` asks for a prompt. The package shows no
  prompt (the call runs on a worker), so the seal is `Unavailable`. A locked item at `open` is `Refused`.
- **The program decides on `Unavailable`.** The package never writes a secret in clear. A program can keep it in clear
  in a file only the user reads and say so (opencode native), or refuse.
- **No state in the package.** Every call opens its own bus connection and closes it. Whether a service answered, and
  when to ask again, is the program's to keep: its interface reads it in a frame, and only it knows its cadence.
- **Every call blocks.** D-Bus and DPAPI can wait. A program calls the package on a worker, never in a frame.
- **Copies are zeroed.** The D-Bus body that carried the secret and the reply that brought it back are zeroed before
  their memory goes back; the same for DPAPI's output.

## Refused alternatives

- **A file encrypted with a key of our own.** The key has to live somewhere the user's account can read: beside the
  file, it protects nothing. The system's store ties the key to the login.
- **libsecret.** A C library to link and to ship, with GLib, where the toolkit's D-Bus client already speaks the protocol.
  A binary without it still starts on a system without the library.
- **A cache of the service's state in the toolkit.** A global, and a cadence that suits one program. opencode native keeps
  its own (`secret_available`): it posts a frame when the answer changes.
- **The encrypted session (`dh-ietf1024-sha256-aes128-cbc-pkcs7`).** The session bus is the user's own and local; any
  process that can read it can also ask the service for the secret.

## Subtleties

- `available` is true on Linux when the service answers, even if the keyring is locked: only `seal` finds out.
- `forget` on Windows does nothing: the field holds the secret, and the program deletes the field.
- A seal with the same `app` and `name` replaces the item (`CreateItem` with `replace`).
