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

### Servers

| implementation | body | connections | req/s | p50 ms | p99 ms | vs Go |
|---|---:|---:|---:|---:|---:|---:|
| mttp | 15 B | 1 | 8,244.3 | 0.11 | 0.17 | 0.42x |
| mttp | 15 B | 32 | 10,418.4 | 3.04 | 3.90 | 0.07x |
| mttp | 1 MiB | 1 | 1,837.5 | 0.52 | 0.68 | 0.36x |
| mttp | 1 MiB | 32 | 1,828.8 | 17.44 | 19.81 | 0.37x |
| core/async/http | 15 B | 1 | 27,716.2 | 0.03 | 0.05 | 1.41x |
| core/async/http | 15 B | 32 | 60,221.7 | 0.50 | 0.70 | 0.42x |
| core/async/http | 1 MiB | 1 | 218.4 | 4.29 | 7.91 | 0.04x |
| core/async/http | 1 MiB | 32 | 181.7 | 175.50 | 206.10 | 0.04x |
| Go net/http | 15 B | 1 | 19,678.1 | 0.04 | 0.11 | 1.00x |
| Go net/http | 15 B | 32 | 144,332.4 | 0.12 | 1.33 | 1.00x |
| Go net/http | 1 MiB | 1 | 5,086.9 | 0.18 | 0.39 | 1.00x |
| Go net/http | 1 MiB | 32 | 4,984.3 | 6.24 | 13.44 | 1.00x |
| Node http | 15 B | 1 | 23,153.1 | 0.04 | 0.07 | 1.18x |
| Node http | 15 B | 32 | 31,619.1 | 0.86 | 3.40 | 0.22x |
| Node http | 1 MiB | 1 | 6,629.5 | 0.14 | 0.21 | 1.30x |
| Node http | 1 MiB | 32 | 6,888.8 | 4.54 | 8.84 | 1.38x |

### Clients against Go

| implementation | body | connections | req/s | p50 ms | p99 ms | vs core |
|---|---:|---:|---:|---:|---:|---:|
| mttp | 15 B | 1 | 13,080.1 | 0.07 | 0.12 | 0.51x |
| core/async/http | 15 B | 1 | 25,580.3 | 0.04 | 0.06 | 1.00x |
| mttp | 15 B | 32 | 18,640.1 | 1.65 | 2.97 | 0.32x |
| core/async/http | 15 B | 32 | 58,449.5 | 0.56 | 0.71 | 1.00x |
| mttp | 1 MiB | 1 | 762.0 | 1.23 | 1.73 | 0.46x |
| core/async/http | 1 MiB | 1 | 1,656.7 | 0.53 | 0.84 | 1.00x |
| mttp | 1 MiB | 32 | 956.6 | 32.90 | 40.38 | 0.75x |
| core/async/http | 1 MiB | 32 | 1,281.9 | 24.85 | 29.44 | 1.00x |

No mttp row was 10x slower than core/async/http; the largest gap was 5.8x
for the 15-byte server response at 32 connections. It was nevertheless only
0.07x Go, so a future profile should start in mttp's listener/connection
scheduling and HTTP/1 response write path under that row. Core's 1 MiB server
path was also pathological at 0.04x Go; profile
`ServerConnection::write` and response buffering/copying before drawing a
broader conclusion. No optimization was made as part of this benchmark task.
