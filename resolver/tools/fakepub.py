#!/usr/bin/env python3
"""Publish a local module directory into the isolated fake registry.

usage: fakepub.py <module_dir> [--yanked REASON]

Reads name/version/import from <module_dir>/moon.mod, zips the directory
(deterministically), writes the zip into $MOON_HOME/registry/cache/<user>/<mod>/<ver>.zip
and appends an index line to $MOON_HOME/registry/index/user/<user>/<mod>.index.
"""
import hashlib, io, json, os, re, sys, zipfile

def parse_mod(text):
    name = re.search(r'^name\s*=\s*"([^"]+)"', text, re.M).group(1)
    version = re.search(r'^version\s*=\s*"([^"]+)"', text, re.M).group(1)
    deps = {}
    m = re.search(r'^import\s*\{(.*?)\}', text, re.M | re.S)
    if m:
        for spec in re.findall(r'"([^"]+)"', m.group(1)):
            n, v = spec.rsplit('@', 1)
            deps[n] = v
    st = re.search(r'^supported_targets\s*=\s*"([^"]+)"', text, re.M)
    return name, version, deps, st.group(1) if st else None

def main():
    d = sys.argv[1]
    yanked = None
    if '--yanked' in sys.argv:
        yanked = sys.argv[sys.argv.index('--yanked') + 1]
    home = os.environ['MOON_HOME']
    text = open(os.path.join(d, 'moon.mod')).read()
    name, version, deps, st = parse_mod(text)
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED) as z:
        for root, dirs, files in os.walk(d):
            dirs[:] = sorted(x for x in dirs if x not in ('_build', '.mooncakes'))
            for f in sorted(files):
                p = os.path.join(root, f)
                rel = os.path.relpath(p, d)
                zi = zipfile.ZipInfo(rel, date_time=(1980, 1, 1, 0, 0, 0))
                z.writestr(zi, open(p, 'rb').read())
    data = buf.getvalue()
    sha = hashlib.sha256(data).hexdigest()
    user, mod = name.split('/', 1)
    cdir = os.path.join(home, 'registry', 'cache', user, mod)
    os.makedirs(cdir, exist_ok=True)
    open(os.path.join(cdir, version + '.zip'), 'wb').write(data)
    idir = os.path.join(home, 'registry', 'index', 'user', user)
    ipath = os.path.join(idir, mod + '.index')
    os.makedirs(os.path.dirname(ipath), exist_ok=True)
    entry = {"name": name, "version": version, "deps": deps, "source": "src",
             "license": "Apache-2.0", "checksum": sha,
             "yanked": yanked is not None, "yanked_reason": yanked,
             "created_at": "2026-10-23T00:00:00+00:00"}
    if st:
        entry["supported-targets"] = st
    lines = []
    if os.path.exists(ipath):
        lines = [l for l in open(ipath).read().splitlines()
                 if l.strip() and json.loads(l)['version'] != version]
    lines.append(json.dumps(entry))
    open(ipath, 'w').write('\n'.join(lines) + '\n')
    print(f"published {name}@{version} deps={deps} sha={sha[:12]} yanked={yanked}")

main()
