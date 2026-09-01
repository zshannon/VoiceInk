#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <path-to-dmg> <notarytool-keychain-profile>" >&2
    exit 64
fi

dmg_path="$1"
keychain_profile="$2"

if [[ ! -f "$dmg_path" ]]; then
    echo "DMG not found: $dmg_path" >&2
    exit 66
fi

echo "Submitting DMG for notarization..."
xcrun notarytool submit "$dmg_path" \
    --keychain-profile "$keychain_profile" \
    --wait

echo "Stapling DMG notarization ticket..."
xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"

echo "Validating DMG with Gatekeeper..."
spctl -a -t open --context context:primary-signature -vv "$dmg_path"
