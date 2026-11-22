'use strict';

// moon runs this script (moon.mod's --moonbit-unstable-prebuild) before it
// builds gaato/mttp_ng, in this repository and in every program that
// imports the module. A library package's `cc-link-flags` in moon.pkg reach
// only that package's own tests, so the link flags of each package that
// binds a system library come from here (`link_configs`), and the compiler
// flags of its C stub too (`vars`, read in moon.pkg as `${build.NAME}`).
// stdout carries the JSON moon reads and nothing else.
//
// pkg-config names the flags where it knows the libraries. Without it, or
// without a .pc file, the plain library names stand in, so that a program
// that never links a package does not fail here: only the packages a program
// imports are compiled and linked, so HTTP/2 alone needs neither ngtcp2 nor
// an OpenSSL with QUIC.

const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

// Homebrew's OpenSSL is keg-only, so pkg-config finds it only through its
// own directory; ngtcp2's crypto library there is built against openssl@4.
function pkgConfigPath() {
  const dirs = [];
  for (const prefix of ['/opt/homebrew', '/usr/local']) {
    for (const keg of ['openssl@4', 'openssl@3']) {
      const dir = path.join(prefix, 'opt', keg, 'lib', 'pkgconfig');
      if (fs.existsSync(dir)) {
        dirs.push(dir);
        break;
      }
    }
  }
  const current = process.env.PKG_CONFIG_PATH;
  if (current) {
    dirs.unshift(current);
  }
  return dirs.join(path.delimiter);
}

const env = { ...process.env, PKG_CONFIG_PATH: pkgConfigPath() };

function pkgConfig(flag, modules) {
  const result = spawnSync('pkg-config', [flag, ...modules], {
    env,
    encoding: 'utf8',
  });
  if (result.error || result.status !== 0) {
    return null;
  }
  return result.stdout.trim();
}

// The flags of `modules`, or `fallback` when pkg-config does not know them.
function flags(modules, fallback) {
  const cflags = pkgConfig('--cflags', modules);
  const libs = pkgConfig('--libs', modules);
  if (cflags === null || libs === null) {
    return { cflags: '', libs: fallback };
  }
  return { cflags, libs };
}

const tls = flags(['openssl'], '-lssl -lcrypto');
const h2 = flags(['libnghttp2'], '-lnghttp2');
const h3 = flags(
  ['libngtcp2_crypto_ossl', 'libngtcp2', 'libnghttp3', 'openssl'],
  '-lngtcp2_crypto_ossl -lngtcp2 -lnghttp3 -lssl -lcrypto',
);

// moon sends its environment and paths on stdin; nothing here needs them,
// but reading to the end lets moon finish writing.
process.stdin.resume();
process.stdin.on('end', () => {
  process.stdout.write(
    JSON.stringify({
      vars: {
        TLS_CFLAGS: tls.cflags,
        H2_CFLAGS: h2.cflags,
        H3_CFLAGS: h3.cflags,
      },
      link_configs: [
        { package: 'gaato/mttp_ng/tls', link_flags: tls.libs },
        { package: 'gaato/mttp_ng/h2', link_flags: h2.libs },
        { package: 'gaato/mttp_ng/h3', link_flags: h3.libs },
      ],
    }),
  );
});
