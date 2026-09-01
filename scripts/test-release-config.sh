#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_SCRIPT="$SCRIPT_DIR/release.sh"
TEST_ROOT="$(mktemp -d /tmp/voiceink-release-config.XXXXXX)"
BIN_DIR="$TEST_ROOT/bin"
SPARKLE_BIN_DIR="$TEST_ROOT/sparkle-bin"
FORK_SIGNING_IDENTITY="555066E4A3E7123BE9E073B0A7E3AE1F355669A1"

cleanup() {
    rm -rf "$TEST_ROOT"
}

trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_status() {
    local expected="$1"
    local actual="$2"
    local output="$3"
    local context="$4"

    if [[ "$actual" != "$expected" ]]; then
        printf '%s\n' "$output" >&2
        fail "$context (expected exit $expected, got $actual)"
    fi
}

mkdir -p "$BIN_DIR" "$SPARKLE_BIN_DIR"

cat > "$BIN_DIR/security" <<EOF
#!/usr/bin/env bash
printf '  1) $FORK_SIGNING_IDENTITY "Developer ID Application: Fork Signer (NRD52JHX45)"\n'
EOF

cat > "$BIN_DIR/codesign" <<'EOF'
#!/usr/bin/env bash
exit 42
EOF

cat > "$BIN_DIR/create-dmg" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$BIN_DIR/xcodebuild" <<'EOF'
#!/usr/bin/env bash
export_options=""
previous=""
for argument in "$@"; do
    if [[ "$previous" == "-exportOptionsPlist" ]]; then
        export_options="$argument"
        break
    fi
    previous="$argument"
done

if [[ -n "$export_options" ]]; then
    team_id="$(plutil -extract teamID raw "$export_options")"
    [[ "$team_id" == "NRD52JHX45" ]] || exit 43
fi

exit 42
EOF

for tool in generate_appcast generate_keys sign_update; do
    cat > "$SPARKLE_BIN_DIR/$tool" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
done

chmod +x "$BIN_DIR/security" "$BIN_DIR/codesign" "$BIN_DIR/create-dmg" \
    "$BIN_DIR/xcodebuild" "$SPARKLE_BIN_DIR/generate_appcast" \
    "$SPARKLE_BIN_DIR/generate_keys" "$SPARKLE_BIN_DIR/sign_update"

COMMON_ENV=(
    "PATH=$BIN_DIR:$PATH"
    "SPARKLE_BIN_DIR=$SPARKLE_BIN_DIR"
    "VOICEINK_RELEASE_OUTPUT_ROOT=$TEST_ROOT/output"
)

set +e
framework_output="$(env "${COMMON_ENV[@]}" \
    VOICEINK_DEVELOPER_IDENTITY="$FORK_SIGNING_IDENTITY" \
    "$RELEASE_SCRIPT" \
    --notes "$TEST_ROOT/unused-notes.html" \
    --output-dir "$TEST_ROOT/framework-output" \
    --skip-notarization \
    --allow-dirty 2>&1)"
framework_status=$?
set -e
assert_status 42 "$framework_status" "$framework_output" \
    "release did not use the Whisper framework produced by make whisper"

FAKE_APP="$TEST_ROOT/VoiceInk.app"
mkdir -p "$FAKE_APP/Contents"
cat > "$FAKE_APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>me.zcs.VoiceInk</string>
    <key>CFBundleShortVersionString</key>
    <string>2.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.4</string>
    <key>SUFeedURL</key>
    <string>https://voice-ink-releases.zcs.me/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>test-key</string>
</dict>
</plist>
EOF
printf '<p>Release notes</p>\n' > "$TEST_ROOT/notes.html"

set +e
identity_output="$(env "${COMMON_ENV[@]}" \
    "$RELEASE_SCRIPT" \
    --app "$FAKE_APP" \
    --notes "$TEST_ROOT/notes.html" \
    --output-dir "$TEST_ROOT/identity-output" \
    --skip-notarization \
    --allow-dirty 2>&1)"
identity_status=$?
set -e
assert_status 42 "$identity_status" "$identity_output" \
    "release rejected the fork signing identity, bundle identifier, or Sparkle feed"

FAKE_ARCHIVE="$TEST_ROOT/VoiceInk.xcarchive"
mkdir -p "$FAKE_ARCHIVE"

set +e
export_output="$(env "${COMMON_ENV[@]}" \
    VOICEINK_DEVELOPER_IDENTITY="$FORK_SIGNING_IDENTITY" \
    "$RELEASE_SCRIPT" \
    --archive "$FAKE_ARCHIVE" \
    --notes "$TEST_ROOT/unused-notes.html" \
    --output-dir "$TEST_ROOT/export-output" \
    --skip-notarization \
    --allow-dirty 2>&1)"
export_status=$?
set -e
assert_status 42 "$export_status" "$export_output" \
    "release export options did not select the fork's Apple developer team"

printf 'PASS: release configuration matches the fork\n'
