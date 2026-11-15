# Builds Http11Probe's command-line program at one commit, in the .NET SDK
# image interop/images.tsv pins. interop/run.mbtx runs it as
#
#   sh /src/build.sh <repository URL> <commit>
#
# with the work directory /work mounted writable. The program lands in
# /work/bin, and /work/bin/commit names the commit it was built from, so a
# later run with the same pin builds nothing and needs no network. NuGet
# packages are kept in /work/nuget for the same reason.
set -eu
repo=$1
commit=$2
cd /work
if [ "$(cat bin/commit 2>/dev/null)" = "$commit" ]; then
  exit 0
fi
rm -rf src bin
git init -q src
cd src
git fetch -q --depth 1 "$repo" "$commit"
git -c advice.detachedHead=false checkout -q FETCH_HEAD
# A commit hash names the whole tree, so this is the pin's integrity check.
test "$(git rev-parse HEAD)" = "$commit"
dotnet publish src/Http11Probe.Cli -c Release -f net10.0 -o /work/bin --nologo -v quiet
echo "$commit" > /work/bin/commit
