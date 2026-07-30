# Roadmap

Not yet built, and not promised for a specific release:

- **Timeout-aware `CHECK-CANCELLED` propagation into `AWAIT`/`RECV`/`SEND`.**
  Today cancellation is purely cooperative via explicit `CHECK-CANCELLED`
  calls; a task blocked inside `AWAIT` or `RECV` does not observe its scope's
  cancellation until it returns to a point that calls `CHECK-CANCELLED`
  itself.
- **Buffered-channel backpressure metrics** (current depth, high-water mark)
  for observability.
- Porting `src/primitives.lisp` to another implementation is out of scope for
  this project (see [Compatibility](compatibility.md)) but would be the only
  file that needs it.
