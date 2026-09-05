# Roadmap

- Add scope-cancellation wakeups for tasks blocked in `AWAIT`, `RECV`, or
  `SEND`. Cancellation is currently observed at explicit `CHECK-CANCELLED`
  calls.
- Add current-depth and high-water-mark metrics to buffered channels.
- Support Common Lisp implementations other than SBCL by porting
  `src/primitives.lisp`; see [Compatibility](../reference/compatibility.md).
