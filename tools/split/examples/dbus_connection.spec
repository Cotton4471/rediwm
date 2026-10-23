# znested.py: the Connection struct into connection_*.zig, the first step of
# 1250383 (line numbers of its parent).
parent src/dbus/connection.zig
container Connection
group src/dbus/connection_calls.zig Handlers and calls: method and signal registration, match rules, calls, replies (also deferred) and signals.
  142-342
group src/dbus/connection_io.zig Wire I/O: serials, sending, dispatching incoming messages, reading (with fds), writing, and the loop's fd and timer callbacks.
  343-580
