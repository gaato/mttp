;; Answers WASI p1's random_get with ENOSYS (52), so that moonbitlang/core's
;; @env.rand returns None and gaato/mttp_core falls back to its xorshift.
(module
  (func (export "random_get") (param i32 i32) (result i32)
    i32.const 52))
