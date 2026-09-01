#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_SCRIPT="$SCRIPT_DIR/release.sh"
DMG_NOTARIZER="$SCRIPT_DIR/notarize-dmg.sh"
MAKEFILE="$SCRIPT_DIR/../Makefile"
PROJECT="$SCRIPT_DIR/../VoiceInk.xcodeproj"
SOURCE_INFO_PLIST="$SCRIPT_DIR/../VoiceInk/Info.plist"
REAL_XCODEBUILD="$(command -v xcodebuild)"
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

assert_success() {
    local status="$1"
    local output="$2"
    local context="$3"

    if [[ "$status" != "0" ]]; then
        printf '%s\n' "$output" >&2
        fail "$context (expected exit 0, got $status)"
    fi
}

assert_failure() {
    local status="$1"
    local output="$2"
    local context="$3"

    if [[ "$status" == "0" ]]; then
        printf '%s\n' "$output" >&2
        fail "$context (expected a non-zero exit)"
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

MAKE_WORK_DIR="$TEST_ROOT/make-work"
MAKE_BIN_DIR="$TEST_ROOT/make-bin"
mkdir -p "$MAKE_WORK_DIR/.deps/whisper.cpp/build-apple/whisper.xcframework" \
    "$MAKE_BIN_DIR"

cat > "$MAKE_BIN_DIR/xcodebuild" <<'EOF'
#!/usr/bin/env bash

arguments=" $* "
[[ "$arguments" == *" archive "* ]] || exit 51
[[ "$arguments" != *" CODE_SIGN_STYLE="* ]] || exit 52
[[ "$arguments" != *" DEVELOPMENT_TEAM="* ]] || exit 53
[[ "$arguments" != *" CODE_SIGN_IDENTITY="* ]] || exit 54
[[ "$arguments" != *" PROVISIONING_PROFILE_SPECIFIER="* ]] || exit 55
[[ "$arguments" != *" -allowProvisioningUpdates "* ]] || exit 56
EOF
chmod +x "$MAKE_BIN_DIR/xcodebuild"

set +e
archive_output="$(PATH="$MAKE_BIN_DIR:$PATH" \
    make -C "$MAKE_WORK_DIR" -f "$MAKEFILE" archive 2>&1)"
archive_status=$?
set -e
assert_success "$archive_status" "$archive_output" \
    "Makefile archive leaked app signing settings into Swift package targets"

mkdir -p "$MAKE_WORK_DIR/build/export/VoiceInk.app/Contents"
cat > "$MAKE_WORK_DIR/build/export/VoiceInk.app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleShortVersionString</key><string>2.1</string>
</dict></plist>
EOF

set +e
make_license_output="$(make -C "$MAKE_WORK_DIR" -f "$MAKEFILE" verify-fork-license-policy 2>&1)"
make_license_status=$?
set -e
assert_failure "$make_license_status" "$make_license_output" \
    "Makefile accepted an app that enforces licensing"
[[ "$make_license_output" == *"license enforcement must be disabled"* ]] || \
    fail "Makefile did not explain the license enforcement failure"

/usr/libexec/PlistBuddy -c 'Add :ZCSLicenseEnforcementDisabled bool true' \
    "$MAKE_WORK_DIR/build/export/VoiceInk.app/Contents/Info.plist"

set +e
make_license_output="$(make -C "$MAKE_WORK_DIR" -f "$MAKEFILE" verify-fork-license-policy 2>&1)"
make_license_status=$?
set -e
assert_success "$make_license_status" "$make_license_output" \
    "Makefile rejected an app with license enforcement disabled"

set +e
dmg_plan="$(make -C "$MAKE_WORK_DIR" -f "$MAKEFILE" -n dmg 2>&1)"
dmg_plan_status=$?
set -e
assert_success "$dmg_plan_status" "$dmg_plan" \
    "Makefile could not produce the final DMG release plan"
[[ "$dmg_plan" == *"./scripts/notarize-dmg.sh"* ]] || \
    fail "Makefile DMG target did not invoke final DMG notarization"

set +e
release_settings="$($REAL_XCODEBUILD -project "$PROJECT" \
    -target VoiceInk \
    -configuration Release \
    -showBuildSettings 2>&1)"
release_settings_status=$?
set -e
assert_success "$release_settings_status" "$release_settings" \
    "Xcode could not resolve the VoiceInk Release signing settings"

release_team="$(printf '%s\n' "$release_settings" | awk -F ' = ' '/^[[:space:]]*DEVELOPMENT_TEAM = / { print $2; exit }')"
release_identity="$(printf '%s\n' "$release_settings" | awk -F ' = ' '/^[[:space:]]*CODE_SIGN_IDENTITY = / { print $2; exit }')"
release_profile="$(printf '%s\n' "$release_settings" | awk -F ' = ' '/^[[:space:]]*PROVISIONING_PROFILE_SPECIFIER = / { print $2; exit }')"
release_style="$(printf '%s\n' "$release_settings" | awk -F ' = ' '/^[[:space:]]*CODE_SIGN_STYLE = / { print $2; exit }')"

[[ "$release_team" == "NRD52JHX45" ]] || \
    fail "VoiceInk Release target did not select the fork's Apple developer team"
[[ "$release_identity" == "$FORK_SIGNING_IDENTITY" ]] || \
    fail "VoiceInk Release target did not select the installed Developer ID certificate"
[[ "$release_profile" == "VoiceInk Developer ID" ]] || \
    fail "VoiceInk Release target did not select the Developer ID provisioning profile"
[[ "$release_style" == "Manual" ]] || \
    fail "VoiceInk Release target did not use manual signing"
source_license_enforcement_disabled="$(plutil -extract ZCSLicenseEnforcementDisabled raw "$SOURCE_INFO_PLIST")"
[[ "$source_license_enforcement_disabled" == "true" ]] || \
    fail "VoiceInk app metadata did not disable license enforcement"

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
unsafe_license_output="$(env "${COMMON_ENV[@]}" \
    "$RELEASE_SCRIPT" \
    --app "$FAKE_APP" \
    --notes "$TEST_ROOT/notes.html" \
    --output-dir "$TEST_ROOT/unsafe-license-output" \
    --skip-notarization \
    --allow-dirty 2>&1)"
unsafe_license_status=$?
set -e
assert_status 1 "$unsafe_license_status" "$unsafe_license_output" \
    "release accepted an app that enforces licensing"
[[ "$unsafe_license_output" == *"license enforcement must be disabled"* ]] || \
    fail "release did not explain the license enforcement failure"

/usr/libexec/PlistBuddy -c 'Add :ZCSLicenseEnforcementDisabled bool true' \
    "$FAKE_APP/Contents/Info.plist"

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

DMG_BIN_DIR="$TEST_ROOT/dmg-bin"
DMG_PATH="$TEST_ROOT/VoiceInk-2.1.dmg"
NOTARY_LOG="$TEST_ROOT/notary.log"
mkdir -p "$DMG_BIN_DIR"
touch "$DMG_PATH"

cat > "$DMG_BIN_DIR/xcrun" <<'EOF'
#!/usr/bin/env bash
printf 'xcrun %s\n' "$*" >> "$VOICEINK_NOTARY_TEST_LOG"
EOF

cat > "$DMG_BIN_DIR/spctl" <<'EOF'
#!/usr/bin/env bash
printf 'spctl %s\n' "$*" >> "$VOICEINK_NOTARY_TEST_LOG"
EOF
chmod +x "$DMG_BIN_DIR/xcrun" "$DMG_BIN_DIR/spctl"

set +e
dmg_notary_output="$(PATH="$DMG_BIN_DIR:$PATH" \
    VOICEINK_NOTARY_TEST_LOG="$NOTARY_LOG" \
    "$DMG_NOTARIZER" "$DMG_PATH" AC_PASSWORD 2>&1)"
dmg_notary_status=$?
set -e
assert_success "$dmg_notary_status" "$dmg_notary_output" \
    "final DMG was not submitted, stapled, and Gatekeeper-validated"

expected_notary_log="$(cat <<EOF
xcrun notarytool submit $DMG_PATH --keychain-profile AC_PASSWORD --wait
xcrun stapler staple $DMG_PATH
xcrun stapler validate $DMG_PATH
spctl -a -t open --context context:primary-signature -vv $DMG_PATH
EOF
)"
actual_notary_log="$(cat "$NOTARY_LOG")"
[[ "$actual_notary_log" == "$expected_notary_log" ]] || {
    printf 'Expected notarization operations:\n%s\n' "$expected_notary_log" >&2
    printf 'Actual notarization operations:\n%s\n' "$actual_notary_log" >&2
    fail "final DMG notarization operations were incomplete"
}

printf 'PASS: release configuration matches the fork\n'
