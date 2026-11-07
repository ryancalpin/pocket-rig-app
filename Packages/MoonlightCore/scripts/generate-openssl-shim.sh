#!/usr/bin/env bash
# Usage: generate-openssl-shim.sh <OpenSSL.framework/Headers dir>
# Writes one forwarding header per OpenSSL header into openssl-shim/openssl/,
# so <openssl/x.h> resolves to <OpenSSL/x.h> from the framework.
set -euo pipefail
HDRS="${1:?path to OpenSSL.framework/Headers}"
OUT="$(cd "$(dirname "$0")/.." && pwd)/Sources/CMoonlight/openssl-shim/openssl"
rm -rf "$OUT"; mkdir -p "$OUT"
for f in "$HDRS"/*.h; do
  n=$(basename "$f")
  printf '#include_next <OpenSSL/%s>\n' "$n" > "$OUT/$n"
done
echo "Generated $(ls "$OUT" | wc -l | tr -d ' ') headers in $OUT"
