#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

for CONCEPT in A B; do
    ICONSET="Resources/Icons/$CONCEPT/app/Pusu.iconset"
    OUTPUT="Resources/Icons/$CONCEPT/Pusu.icns"
    if [ ! -d "$ICONSET" ]; then
        echo "Eksik iconset: $ICONSET" >&2
        exit 1
    fi
    iconutil -c icns "$ICONSET" -o "$OUTPUT"
    echo "$OUTPUT"
done
