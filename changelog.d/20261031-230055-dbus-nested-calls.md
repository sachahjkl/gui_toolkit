type: Fixed

**`dbus.call`**: a call in a handler while another call waits: each gets its reply, whatever their order, where the outer one timed out; what an outer call had read no longer waits for the inner call's timeout.
