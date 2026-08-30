#!/bin/bash
# Release-safety check: fails if debug/store-side command strings survive into
# the release executable. These are compiled out behind `#if DEBUG`; this script
# is the backstop that keeps a regression from shipping a trial-reset or a
# license-signing path to end users.
#
# Usage: ./scripts/check-release-safety.sh [path-to-release-binary]
#        (no argument: builds .build/release/FlowClone first)
set -euo pipefail

cd "$(dirname "$0")/.."

BIN="${1:-}"
if [[ -z "$BIN" ]]; then
  echo "▸ Building release binary…"
  swift build -c release >/dev/null
  BIN=".build/release/FlowClone"
fi

if [[ ! -f "$BIN" ]]; then
  echo "❌ No binary at $BIN"
  exit 1
fi

# Forbidden in a shipped binary:
#  --trial-set-days-ago  → resets the 14-day trial from a terminal
#  --sign-license        → mints valid license keys (store-side only)
#  ONYX_SIGNING_KEY      → the signing-key env lookup (only the signer needs it)
#  signing-key.b64       → the on-disk private-key path (ditto)
FORBIDDEN=(
  "--trial-set-days-ago"
  "--sign-license"
  "ONYX_SIGNING_KEY"
  "signing-key.b64"
)

fail=0
for s in "${FORBIDDEN[@]}"; do
  if strings "$BIN" | grep -qF -- "$s"; then
    echo "❌ forbidden string \"$s\" present in $BIN"
    fail=1
  fi
done

if [[ "$fail" -ne 0 ]]; then
  echo "❌ Release-safety check FAILED — a debug/store-side command shipped."
  exit 1
fi
echo "✅ Release-safety check passed ($BIN clean)."
