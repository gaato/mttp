# Transport benchmarks

Run the pinned comparison from the workspace root:

```sh
MOON_CC=cc scripts/gates.sh bench
```

The command prints tab-separated `BENCH_RESULT` lines and Markdown tables but
does not write a result. Add `--record` to explicitly write the dated JSON to
`benchmarks/results/`. CI uses `--output` for an artifact instead, so a noisy
shared runner never changes the repository:

```sh
MOON_CC=cc scripts/gates.sh bench --record
```

Each row runs for 10 seconds over HTTP/1.1 loopback with keep-alive, first with
one connection and then 32. Server rows use the pinned oha container to send
the same GET for a fixed 15-byte body or a fixed 1 MiB body to mttp,
`moonbitlang/core/async/http`, Go `net/http`, and Node `http`. Client rows run
mttp and core/async/http against the same pinned Go server. Every server is
checked for the exact body before timing; every MoonBit client checks every
body. A crash, HTTP error, or wrong body fails the gate. A number never does.

All four servers send `Date`. mttp, Go, and Node generate it automatically;
core/async/http has no automatic Date facility, so its server is given one
IMF-fixdate value at startup as a persistent response header.

The server throughput ratio uses Go on that machine as 1.00x; the client ratio
uses core/async/http. The ratios remove some host-to-host scale but not shared
runner noise, scheduling, container overhead, or implementation differences
outside these two response shapes. These are loopback throughput and latency
observations, not internet performance, capacity limits, or a general HTTP
implementation ranking.

The comparison programs are in `transport/` and `servers/`; third-party image
digests are in `images.tsv`.

## 2026-11-16 local run

- Machine: Intel Core i5-10400F, 6 cores / 12 threads; Linux
  7.3.1-1-default x86_64.
- Toolchain: moon 0.1.20261104 (940aa18), moonc
  0.10.20+65efd5b93 (2026-11-05), moonrun 0.1.20261104.
- Command:

  ```sh
  export PATH=/home/gaato/.moonup/toolchains/0.10.20+65efd5b93/bin:$PATH
  export MOON_CC=cc
  export BENCH_ENGINE=docker
  scripts/gates.sh bench --record
  ```

The raw values and image digests are in
[`results/2026-11-16.json`](results/2026-11-16.json).
These tables show V15a's third complete after run. The before/after
three-run medians and instruction counts are in
[`PROFILE-2026-11.md`](PROFILE-2026-11.md#v15a-direct-bytesempty-responses).

### Servers

| implementation | body | connections | req/s | p50 ms | p99 ms | vs Go |
|---|---:|---:|---:|---:|---:|---:|
| mttp | 15 B | 1 | 9,344.6 | 0.09 | 0.24 | 0.33x |
| mttp | 15 B | 32 | 12,142.7 | 2.57 | 3.06 | 0.07x |
| mttp | 1 MiB | 1 | 1,978.2 | 0.49 | 0.66 | 0.36x |
| mttp | 1 MiB | 32 | 1,910.5 | 16.70 | 20.14 | 0.30x |
| core/async/http | 15 B | 1 | 28,523.6 | 0.03 | 0.05 | 1.02x |
| core/async/http | 15 B | 32 | 63,653.6 | 0.47 | 0.64 | 0.34x |
| core/async/http | 1 MiB | 1 | 204.7 | 5.03 | 6.89 | 0.04x |
| core/async/http | 1 MiB | 32 | 181.2 | 174.41 | 222.31 | 0.03x |
| Go net/http | 15 B | 1 | 27,905.0 | 0.03 | 0.05 | 1.00x |
| Go net/http | 15 B | 32 | 186,329.4 | 0.10 | 0.97 | 1.00x |
| Go net/http | 1 MiB | 1 | 5,568.9 | 0.15 | 0.64 | 1.00x |
| Go net/http | 1 MiB | 32 | 6,392.6 | 4.86 | 10.20 | 1.00x |
| Node http | 15 B | 1 | 25,478.9 | 0.04 | 0.06 | 0.91x |
| Node http | 15 B | 32 | 40,454.5 | 0.73 | 1.55 | 0.22x |
| Node http | 1 MiB | 1 | 7,107.5 | 0.14 | 0.18 | 1.28x |
| Node http | 1 MiB | 32 | 7,199.3 | 4.30 | 8.25 | 1.13x |

### Clients against Go

| implementation | body | connections | req/s | p50 ms | p99 ms | vs core |
|---|---:|---:|---:|---:|---:|---:|
| mttp | 15 B | 1 | 11,609.1 | 0.09 | 0.12 | 0.48x |
| core/async/http | 15 B | 1 | 24,213.0 | 0.04 | 0.06 | 1.00x |
| mttp | 15 B | 32 | 20,583.5 | 1.55 | 2.04 | 0.34x |
| core/async/http | 15 B | 32 | 60,266.3 | 0.53 | 0.70 | 1.00x |
| mttp | 1 MiB | 1 | 794.5 | 1.20 | 1.40 | 0.50x |
| core/async/http | 1 MiB | 1 | 1,579.3 | 0.53 | 1.26 | 1.00x |
| mttp | 1 MiB | 32 | 1,050.0 | 29.87 | 41.00 | 0.76x |
| core/async/http | 1 MiB | 32 | 1,374.5 | 23.09 | 28.07 | 1.00x |

V15a keeps Bytes/Empty responses on the direct write path while preserving
completion and shutdown admission. The 15-byte / 32-connection median rose
13.98% over three runs, with 13.38% fewer Callgrind instructions. The other
mttp throughput medians were lower by 3.54–6.61% on the shared host; the
profile records all observations and comparison-server changes. These
measurements establish no general throughput improvement for those rows.
