'use strict';

// moon runs this script (moon.mod's --moonbit-unstable-prebuild) before it
// builds gaato/mttp_curl, in this repository and in every program that
// imports the module. Its only job is to put libcurl on the final link line.
// A library package's `cc-link-flags` in moon.pkg reaches only executables
// of that package (its own tests); moon passes the `link_configs` printed
// here to every executable that links the package, a user's program
// included. stdout carries the JSON moon reads and nothing else.

// moon sends its environment and paths on stdin; nothing here needs them,
// but reading to the end lets moon finish writing.
process.stdin.resume();
process.stdin.on('end', () => {
  process.stdout.write(
    JSON.stringify({
      link_configs: [
        {
          package: 'gaato/mttp_curl',
          // pthread: the thread that drives libcurl's multi handle.
          link_flags: '-lcurl -lpthread',
        },
      ],
    }),
  );
});
