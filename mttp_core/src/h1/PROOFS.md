# HTTP/1 number proofs

`moon prove` checks the executable integer core in `src/internal/number`.
Content-Length and chunk-size both map their initial ASCII digit run to
integer values and call its `fold`. Public signatures, OWS handling, chunk
extensions, and error order and text are preserved.

The proof covers integer digit sequences. Strings, bytes, OWS, exceptions
and the rest of HTTP framing remain tested integration code outside the
formal proof. No trusted arithmetic or conversion bridge is needed.

## Running it

From the repository root, with the pinned MoonBit toolchain and Z3 4.16.0
and CVC5 1.4.2 on PATH, run sequentially:

```sh
scripts/gates.sh prove
scripts/gates.sh prove --solver cvc5
# Equivalently:
moon run scripts/prove.mbtx -- --solver z3
moon run scripts/prove.mbtx -- --solver cvc5
```

This manual gate is outside quick, static and full. The runner, adapted
from codecs.mbt's `scripts/prove.mbtx`, checks the exact solver version and
resolves mise shims to executables. `MOON_HOME` must provide the matching
toolchain libraries, Why3 data and dependency registry/cache;
`MOON_PROVE_PRELUDE_OVERRIDE` must be unset. This attempt used a writable
copy under `/var/tmp/mttp-plan/scratch/v11b`, with actual solver directories
on PATH so the temporary XDG configuration did not change mise's selection.
That copy is removed at completion.

Each pinned Why3 configuration exposes exactly one solver and allows one
prover process at a time. The runner starts one `moon prove -j 1` at a time,
with a 600-second package timeout. A positive run needs exit 0, a fresh
report with `result: success`, and at least six valid goals. Missing,
unreadable or harness-error reports fail the gate; old reports are removed
before each run. Logs and solver-specific report copies are retained under
`_build/proof/<solver>-*`. The actual positive report is also at
`_build/verif/gaato/mttp_core/internal/number/number.proof.json`.

## Model and specification

For `0 <= n <= a.length()`, `model(a, n, base)` is the unbounded integer
value of the first `n` digits, in positional notation:

```text
V(a, 0, b)     = 0
V(a, n + 1, b) = V(a, n, b) * b + a[n]
```

The recursive definition and predicates live in `number.mbtp`.
`proof_decrease: n` proves termination. Nonrecursive logic helpers perform
the primitive arithmetic and array access around the recursive call:
direct operations there lower to program calls on moonc 0.10.20 and leave
the model opaque to SMT solvers. These helpers are definitions, not axioms.
`model_zero` and `model_step` prove the two equations above. Outside the
prefix domain the model returns zero; no parser claim uses those values.

`digits(a, n, base)` means every prefix element is in `0..<base`.
`fold_post` states that the result is nonnegative exactly when the prefix
is nonempty, every element is a digit, and its mathematical value is at
most 9223372036854775807. On acceptance the result equals that value;
otherwise it is -1. There is no maximum digit count; leading zeros are
allowed.

| Function | Property | Preconditions | Prelude | Solvers |
| --- | --- | --- | --- | --- |
| `step` | Result is `value * base + digit` if that fits signed 63 bits, and -1 exactly above the bound; the accepted multiplication itself fits | `0 <= value <= MAX`, base 10 or 16, `0 <= digit < base` | unbounded | Z3, CVC5 |
| `valid_digits` | True exactly when every prefix element is a digit | `fold_pre` | unbounded | Z3, CVC5 |
| `fold` | Empty/invalid prefixes refused; for digit sequences, refusal exactly on mathematical overflow, and accepted values equal `model` | `0 <= n <= min(a.length(), 2147483647)`, base 10 or 16 | unbounded | Z3, CVC5 |
| `model_zero`, `model_step`, recursive `model` | Base/step equations and model termination | Step: `0 <= n < a.length()` | unbounded | Z3, CVC5 |

`fold` first checks digit membership with a prefix invariant. Its numeric
loop maintains either `acc == V(prefix)` within the bound, or
`V(prefix) > MAX` with a sticky overflow flag. A later nonnegative digit in
base 10 or 16 cannot bring an overflowing value back within the bound.
The executable accumulator stays in `0..MAX`; index increments cannot pass
`n`, itself at most Int32's maximum. No allocation or mutation occurs.

Content-Length's language is `1*DIGIT` after outer OWS removal (RFC 9110
section 8.6); chunk-size's is `1*HEXDIG`, before extensions (RFC 9112
section 7.1). h1's `number_prefix` stops at the first non-digit. Folding
that prefix before inspecting the remainder preserves overflow errors
that precede an invalid character or extension. Content-Length then
requires all the trimmed value to have been digits; chunk-size separately
validates the remainder as extensions.

## What is trusted and tested

- The solvers, Why3, MoonBit's translation and its built-in array/integer
  models. The unbounded prelude does not model machine wrapping; contracts,
  the explicit product assertion and loop bounds keep every executable
  arithmetic operation within its runtime range.
- The h1 integration is not formally verified. Its code-unit to Int64
  mapping is exhaustively tested over all 65,536 UTF-16 code units, in both
  bases, against explicit ASCII character and digit-value tables. OWS,
  signs, non-ASCII digits, error order and both public entry points are
  tested in `numbers_wbtest.mbt`.
- `number_test.mbt` checks the exact maximum and one past it in both bases,
  empty/invalid digits, long leading-zero inputs, sticky overflow, prefix
  lengths and every valid digit pair. Existing h1 tests are retained.
  Public `request_framing` and `ChunkedDecoder::feed` agree with the core,
  including `7fffffffffffffff` and `8000000000000000`.

Trusted bridge budget: **0**. There are no `proof_axiomatized` functions,
external `#proof_import` declarations or custom proof preludes.

## Negative controls

`scripts/proof/controls.mbt.in` deliberately claims that a step never
overflows, every step overflows, every fold accepts, and every fold refuses.
Runtime counterexamples are respectively the decimal maximum plus one,
zero followed by zero, empty digits, and `[0, 0]`; the numeric tests exercise
these cases. Each claim must fail with each solver.

The runner copies the actual core source and model unchanged into an
isolated generated workspace under `_build/proof/negative` and adds those
contracts. No false claim ships in production sources, no additional
committed package is needed, and the source package has no imports. The
control report must say `proof_failure`, exit nonzero, and name all four
false claims and no other failed function. The copied production goals
must therefore still pass. The final solver attempt for controls is one
second; refusal is a negative check, not a positive theorem.

## Why the core is outside h1

The initial V11b attempt contracted an Int64 step inside h1. Loading h1's
dependency interface stopped before solver dispatch:

```text
_build/verif/gaato/mttp_core/pkg_5_gaato_10_mttp_ucore.mlw
line 9, characters 35-40: unbound type symbol 'array'
```

The interface uses `array` in `Headers.pairs` before declaring it near its
end. Other forward references include `streamBody`, `map` and
`_moonbitlang_core_ref_Ref`. Enabling proof on the root package did not fix
it. Z3/CVC5 configurations stopped with `harness_error` in 0.284 s and
0.229 s respectively; these were frontend times, not solver times.

This remains an upstream report candidate: generated Why3 interfaces use
opaque types before declaring them. The approved workaround is one
dependency-free internal package, with `proof_enabled` only there. The
runner does not patch generated Why3. No upstream report was sent.

## Verification results

Toolchain: moon 0.1.20261104 (940aa18), moonc 0.10.20+65efd5b93.

| Solver | Core | Negative controls | Result |
| --- | --- | --- | --- |
| Z3 4.16.0 | 6 goals, 0.5 s | All 4 refused, 29.0 s | pass |
| CVC5 1.4.2 | 6 goals, 1.1 s | All 4 refused, 24.4 s | pass |

Times are wall time for each `moon prove`, including the frontend. The
solvers ran sequentially. `moon check --deny-warn` and `moon info` passed.
Package tests passed on wasm-gc, wasm, js and native (`MOON_CC=cc`): 56 per
target in h1 and 4 per target in number, with identical counts across all
four targets. UTF-16 conversion and mapping were checked over their complete
code-unit domain. Format checks, shell syntax, resource-bound citations,
architecture and test-layout audits passed.

A separate native coverage run of only these two packages passed all 60
tests. Coverage was 79/79 lines for `chunked.mbt`, 34/34 for `framing.mbt`,
12/12 for h1's `numbers.mbt`, and 21/21 for `internal/number/number.mbt`.
No uncovered-line budget was added. The existing module row already covers
the new package; no module dependency or public enum was added, so
`modules.tsv` and `non_exhaustive.tsv` need no new rows.

`scripts/gates.sh manifest --update` passed (`gates: OK`, 215 rows). The
four existing h1 rows changed from 52 to 56 tests; four number rows with
4 tests each were appended, preserving the previous row order. Existing
generated public interfaces are unchanged; the new internal package's
interface was generated with `moon info`. No quick, static, full, interop
or workerd gate was run.

## Review follow-up

The h1 mapping now counts the initial digit run before allocating its
FixedArray, so extensions and invalid suffixes consume no digit slots.
The existing tests check exact capacity, an empty run and a 4 KiB suffix.
The core source, mathematical model and contracts are unchanged; this does
not weaken or replace the proof. The updated h1 code passed all 56 tests on
each of the four targets, and its targeted native coverage remains 12/12.

The old mutation entries F10/C03 searched for guards removed by extraction.
They now mutate the shared `step` overflow guard for base 10 and base 16
separately. F12/C16 independently test the wrappers' handling of -1.
`scripts/gates.sh mutate F10 C03 F12 C16` passed its baseline and killed
all four mutations, with no survivor or timeout. The rest of the mutation
sample was not rerun. No proof source or generated Why3 was changed.

The follow-up also passed `moon check --deny-warn`, `moon info`, formatting
and `scripts/gates.sh manifest --update` (215 rows, no manifest diff).
