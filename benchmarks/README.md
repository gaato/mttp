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

### Servers

| implementation | body | connections | req/s | p50 ms | p99 ms | vs Go |
|---|---:|---:|---:|---:|---:|---:|
| mttp | 15 B | 1 | 10,212.4 | 0.09 | 0.15 | 0.39x |
| mttp | 15 B | 32 | 11,021.8 | 2.87 | 3.61 | 0.07x |
| mttp | 1 MiB | 1 | 1,823.4 | 0.51 | 0.83 | 0.33x |
| mttp | 1 MiB | 32 | 1,643.7 | 17.53 | 43.21 | 0.31x |
| core/async/http | 15 B | 1 | 23,804.9 | 0.04 | 0.07 | 0.90x |
| core/async/http | 15 B | 32 | 59,015.8 | 0.54 | 0.77 | 0.38x |
| core/async/http | 1 MiB | 1 | 206.8 | 4.52 | 6.40 | 0.04x |
| core/async/http | 1 MiB | 32 | 143.1 | 186.16 | 438.06 | 0.03x |
| Go net/http | 15 B | 1 | 26,372.2 | 0.03 | 0.06 | 1.00x |
| Go net/http | 15 B | 32 | 157,225.4 | 0.11 | 1.27 | 1.00x |
| Go net/http | 1 MiB | 1 | 5,607.0 | 0.17 | 0.32 | 1.00x |
| Go net/http | 1 MiB | 32 | 5,268.6 | 5.83 | 13.73 | 1.00x |
| Node http | 15 B | 1 | 23,449.2 | 0.04 | 0.08 | 0.89x |
| Node http | 15 B | 32 | 38,771.1 | 0.77 | 1.64 | 0.25x |
| Node http | 1 MiB | 1 | 6,014.2 | 0.14 | 0.66 | 1.07x |
| Node http | 1 MiB | 32 | 7,051.9 | 4.34 | 8.57 | 1.34x |

### Clients against Go

| implementation | body | connections | req/s | p50 ms | p99 ms | vs core |
|---|---:|---:|---:|---:|---:|---:|
| mttp | 15 B | 1 | 13,220.3 | 0.07 | 0.11 | 0.53x |
| core/async/http | 15 B | 1 | 25,024.9 | 0.04 | 0.06 | 1.00x |
| mttp | 15 B | 32 | 18,877.1 | 1.64 | 2.85 | 0.34x |
| core/async/http | 15 B | 32 | 56,173.7 | 0.60 | 0.78 | 1.00x |
| mttp | 1 MiB | 1 | 716.6 | 1.27 | 2.10 | 0.63x |
| core/async/http | 1 MiB | 1 | 1,137.9 | 0.61 | 2.19 | 1.00x |
| mttp | 1 MiB | 32 | 379.5 | 91.14 | 203.58 | 0.92x |
| core/async/http | 1 MiB | 32 | 411.9 | 75.83 | 139.05 | 1.00x |

No mttp row was 10x slower than core/async/http; the largest gap was 5.4x
for the 15-byte server response at 32 connections. It was nevertheless only
0.07x Go, so a future profile should start in mttp's listener/connection
scheduling and HTTP/1 response write path under that row. Core's 1 MiB server
path was also pathological at 0.03–0.04x Go; profile
`ServerConnection::write` and response buffering/copying before drawing a
broader conclusion. No optimization was made as part of this benchmark task.
