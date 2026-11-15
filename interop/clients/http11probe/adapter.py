"""Reads the JSON report of Http11Probe (github.com/MDA2AV/Http11Probe), which
interop/run.mbtx runs against the mttp interop server, and prints one
`CASE <id> ok|fail <detail>` line per probe test. The standard library only.

    adapter.py <report.json> <console log> <case,case,...>

Each probe test becomes the case `h11p-<test id, lowercased>`. A requested
case ending in `*` asks for every case starting with what precedes it, so
`h11p-*` asks for all of them.

Verdicts:

- Pass is ok.
- Warn is ok with a detail starting `warn:`: the RFC allows the behaviour,
  and the probe prefers another one. It stays visible in the output.
- Fail is fail.
- Skip and Error are fail with their reason, except when the reason is that
  the test does not apply to this run: then ok with a detail starting
  `n/a:`. The probe reports that as Skip without an error message; at the
  pinned commit it does so only for tests a --category or --test option
  leaves out, and run.mbtx passes neither, so a Skip with no reason shows
  that a newer probe chose not to run a test. Every Error (a connection that
  failed, an exception, a baseline request without a 2xx answer) and every
  Skip with a message fails.

Without a report, the adapter prints the end of the probe's console output
to stderr and exits with status 1, so the runner reports every case as
without result.
"""

import json
import sys

PREFIX = "h11p-"


def one_line(text):
    return " ".join(str(text).split())


def describe(result):
    status = result.get("statusCode")
    got = f"{status}" if status is not None else "no response"
    parts = [f"{got}, {result.get('connectionState', '?')}"]
    if result.get("expected"):
        parts.append(f"expected {result['expected']}")
    if result.get("rfcReference"):
        parts.append(result["rfcReference"])
    if result.get("behavioralNote"):
        parts.append(result["behavioralNote"])
    if result.get("error"):
        parts.append(f"error: {result['error']}")
    return one_line("; ".join(parts))


def judge(result):
    verdict = result.get("verdict")
    detail = describe(result)
    if verdict == "Pass":
        return True, detail
    if verdict == "Warn":
        return True, f"warn: {detail}"
    if verdict == "Skip" and not result.get("error"):
        return True, f"n/a: the probe skipped it as not applying; {detail}"
    return False, f"{verdict}: {detail}"


def wanted(case, requested):
    return any(
        case.startswith(r[:-1]) if r.endswith("*") else case == r for r in requested
    )


def main():
    if len(sys.argv) != 4:
        print("usage: adapter.py <report.json> <console log> <case,...>", file=sys.stderr)
        return 2
    report_path, console_path, cases = sys.argv[1:]
    requested = [c for c in cases.split(",") if c]
    try:
        with open(report_path, encoding="utf-8") as f:
            report = json.load(f)
    except (OSError, ValueError) as error:
        try:
            with open(console_path, encoding="utf-8", errors="replace") as f:
                tail = f.read().splitlines()[-5:]
        except OSError:
            tail = []
        print(f"no Http11Probe report ({error})", *tail, sep="\n", file=sys.stderr)
        return 1
    for result in report.get("results", []):
        case = PREFIX + str(result.get("id", "?")).lower()
        if not wanted(case, requested):
            continue
        ok, detail = judge(result)
        print(f"CASE {case} {'ok' if ok else 'fail'} {detail}", flush=True)
    summary = report.get("summary", {})
    print(f"http11probe summary: {one_line(json.dumps(summary))}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
