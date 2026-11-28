#!/bin/sh
# Run the same tests locally and in CI.
#   1. Zig tests
#   2. App build
#   3. The upaa command against a stand-in for the app's socket (tests/remote-answer.py)
#   4. Compare exported screens with the baseline images (tests/snapshots/)
#   5. Whether speed is outside the lower or upper bound
# With UPDATE_SNAPSHOTS=1, the baseline images are replaced with the current rendering.
set -eu
cd "$(dirname "$0")/.."

zig build test --summary all

CONFIG=release sh scripts/build-app.sh
BIN=build/upaa.app/Contents/MacOS/upaa

python3 -I tests/remote-answer.py "$BIN"

mkdir -p build/snapshots tests/snapshots
for vt in tests/fixtures/*.vt; do
  name="$(basename "$vt" .vt)"
  "$BIN" --snapshot "build/snapshots/$name.png" --command "cat '$PWD/$vt'"
  if [ "${UPDATE_SNAPSHOTS:-0}" = 1 ]; then
    cp "build/snapshots/$name.png" "tests/snapshots/$name.png"
    echo "Updated baseline: tests/snapshots/$name.png"
  else
    printf '%s: ' "$name"
    "$BIN" --compare-png "tests/snapshots/$name.png" "build/snapshots/$name.png"
  fi
done

# Shared CI timing is noisy, so fail only when it is slower by an order of magnitude.
if [ ! -f build/bench.txt ]; then
  # Limit the amount read first. If base64 is cut with head, it does not terminate in environments that ignore SIGPIPE (GitHub Actions runners).
  head -c 15000000 /dev/urandom | base64 -b 100 > build/bench.txt
fi
"$BIN" --bench-headless "$PWD/build/bench.txt" --max-frame-ms 5 --min-mb-per-s 10

echo "All passed"
