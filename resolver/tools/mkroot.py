#!/usr/bin/env python3
"""Create a root module for a resolver experiment.

usage: mkroot.py <dir> <json spec>
spec: {"name": "wf2/x", "imports": ["a@0.1.0"], "extra_mod": "...",
       "pkgs": {"src": {"moon.pkg": "...", "lib.mbt": "..."}, "src/sub": {...}},
       "moonbit_version": "0.10.16+b1a0e846e"}
Refuses to write into an existing directory (use a fresh name per experiment).
"""
import json, os, sys

d = sys.argv[1]
spec = json.loads(sys.argv[2])
if os.path.exists(d):
    sys.exit(f"refusing: {d} exists")
os.makedirs(d)
lines = [f'name = "{spec["name"]}"', 'version = "0.0.1"', 'source = "src"']
if spec.get("extra_mod"):
    lines.append(spec["extra_mod"])
if spec.get("imports"):
    lines.append("import {")
    lines += [f'  "{i}",' for i in spec["imports"]]
    lines.append("}")
open(os.path.join(d, "moon.mod"), "w").write("\n".join(lines) + "\n")
if spec.get("moonbit_version"):
    open(os.path.join(d, "moonbit-version"), "w").write(spec["moonbit_version"] + "\n")
for pkg, files in spec.get("pkgs", {}).items():
    p = os.path.join(d, pkg)
    os.makedirs(p, exist_ok=True)
    for fn, body in files.items():
        open(os.path.join(p, fn), "w").write(body)
print("created", d)
