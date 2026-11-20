# Agent notes

## Documentation

- A module README has two readers: a person deciding from the first screen
  on mooncakes.io, and a coding agent that reads the raw file in a user's
  `.mooncakes/` and copies its examples. So the first example runs as copied
  (Install adds every module it uses, and the imports are shown), and what a
  caller cannot read off the code is written out: defaults and limits as a
  table (setting, default, what happens past it), errors as a table (kind,
  when, what the caller does), and what the module deliberately does not do,
  because an agent invents what a README leaves out.
- Give a reason in the README only when it changes how a caller writes code,
  such as a setting with no default or a check that cannot be turned off;
  other rationale goes to `docs/`. Overviews and design discussion cost an
  agent context without changing what it writes.
- Keep facts that go stale out of the README: upstream and toolchain
  versions, counts of cases or files, dates, "now", "latest", "not yet". Put
  them in a ledger, the CHANGELOG or a benchmark page and link there; a reader
  applies a stale fact without noticing it is stale.
- Name sections and terms as the other gaato modules do (Install, Usage,
  Limits and defaults, Errors, Not here, Checked against, Links, License), so
  a reader who learned one module reads the next one correctly.
- Write nothing addressed to an AI in a README: an agent reading a
  dependency's README would take it as an instruction.

## API changes

- When a published function's labelled parameter is renamed or removed, an
  optional one becomes required, or a positional one becomes labelled, keep
  existing calls compiling for one minor release with `#label_migration`
  (`alias=old`, `fill=false`, `fill=true` or `allow_positional=true`) and a
  `msg` naming the new form, and remove the attribute in the next minor
  release. Callers then get a warning instead of a build failure; the
  CHANGELOG still lists the change with its migration note. A renamed or
  removed function keeps a `#deprecated` alias for the same period.
