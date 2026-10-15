#!/usr/bin/env bash
#
# Regenerates FontManager/Resources/Acknowledgements.txt — the license notices for every
# bundled third-party library, shown in the app's Acknowledgements window. MIT and Apache 2.0
# both require these notices to ship with the binary.
#
# Usage:  scripts/generate-acknowledgements.sh
# Run after adding or updating a dependency (build once first so SwiftPM checkouts exist).
#
set -euo pipefail
cd "$(dirname "$0")/.."

CHECKOUTS="$(ls -d ~/Library/Developer/Xcode/DerivedData/FontManager-*/SourcePackages/checkouts 2>/dev/null | head -1)"
[ -n "$CHECKOUTS" ] || { echo "✗ No SwiftPM checkouts found — build the app once first."; exit 1; }

OUT="FontManager/Resources/Acknowledgements.txt"
mkdir -p "$(dirname "$OUT")"

# name | homepage | directory containing the license files
LIBS=(
  "woff2|https://github.com/google/woff2|ThirdParty/woff2"
  "Brotli|https://github.com/google/brotli|ThirdParty/brotli"
  "Pirata One (font)|https://github.com/google/fonts/tree/main/ofl/pirataone|FontManager/Resources/Fonts/PirataOne"
  "MCP Swift SDK|https://github.com/modelcontextprotocol/swift-sdk|$CHECKOUTS/swift-sdk"
  "EventSource|https://github.com/mattt/EventSource|$CHECKOUTS/eventsource"
  "SwiftNIO|https://github.com/apple/swift-nio|$CHECKOUTS/swift-nio"
  "Swift Log|https://github.com/apple/swift-log|$CHECKOUTS/swift-log"
  "Swift Atomics|https://github.com/apple/swift-atomics|$CHECKOUTS/swift-atomics"
  "Swift Collections|https://github.com/apple/swift-collections|$CHECKOUTS/swift-collections"
  "Swift System|https://github.com/apple/swift-system|$CHECKOUTS/swift-system"
  "Sparkle (open-source build only)|https://github.com/sparkle-project/Sparkle|$CHECKOUTS/Sparkle"
)

{
  echo "Font Manager includes the following open-source software. Thank you to its authors."
  for entry in "${LIBS[@]}"; do
    IFS='|' read -r name url dir <<< "$entry"
    echo
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "$name"
    echo "$url"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    found=0
    for f in "$dir"/LICENSE "$dir"/LICENSE.md "$dir"/LICENSE.txt "$dir"/OFL.txt "$dir"/NOTICE.txt; do
      [ -f "$f" ] || continue
      echo
      cat "$f"
      found=1
    done
    [ "$found" = 1 ] || { echo "✗ No license file in $dir" >&2; exit 1; }
  done
} > "$OUT"

echo "✓ Wrote $OUT ($(wc -l < "$OUT" | tr -d ' ') lines)"
