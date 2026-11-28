#!/bin/sh
# Fetch the Zig that CI and releases build with, verify its signature, then extract it into vendor/zig.
# The version is written only here. upstream-check.yml opens an issue when a newer Zig is out.
set -eu
cd "$(dirname "$0")/.."

VERSION=0.17.1
FILE="zig-aarch64-macos-$VERSION.tar.xz"
# Public key listed on ziglang.org/download
PUBKEY=RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U
DEST=vendor/zig

command -v minisign >/dev/null || { echo "minisign is required (brew install minisign)" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/zig.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

for f in "$FILE" "$FILE.minisig"; do
  curl -fsSL --proto =https -o "$TMP/$f" "https://ziglang.org/download/$VERSION/$f"
done
minisign -V -q -P "$PUBKEY" -m "$TMP/$FILE"

rm -rf "$DEST"
mkdir -p "$DEST"
tar -xJf "$TMP/$FILE" -C "$DEST" --strip-components 1
# A signed file of another version would also pass the signature check.
built="$("$DEST/zig" version)"
[ "$built" = "$VERSION" ] || { echo "The fetched Zig is $built, not $VERSION" >&2; exit 1; }
echo "$DEST"
