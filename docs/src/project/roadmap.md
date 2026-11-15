# Roadmap

- Add scope-cancellation wakeups for tasks blocked in `AWAIT`, `RECV`, or
  `SEND`. Cancellation is currently observed at explicit `CHECK-CANCELLED`
  calls.
- Add current-depth and high-water-mark metrics to buffered channels.
- Support Common Lisp implementations other than SBCL by porting the
  primitive wrappers, timeout and barrier interrupt control, timers, and
  executor compare-and-swap operations; see
  [Compatibility](../reference/compatibility.md).
