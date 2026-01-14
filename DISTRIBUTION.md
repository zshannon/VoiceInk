# Developer ID Distribution

This document explains how to build, sign, and distribute VoiceInk outside the Mac App Store using Developer ID.

## Prerequisites

### 1. Developer ID Application Certificate

You need a Developer ID Application certificate in your keychain.

**Check if you have one:**
```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

**If not, create one:**
1. Go to https://developer.apple.com/account/resources/certificates/list
2. Click **+** to create a new certificate
3. Select **Developer ID Application**
4. Follow the CSR instructions
5. Download and double-click to install

### 2. App ID

Register the app's bundle identifier with Apple.

1. Go to https://developer.apple.com/account/resources/identifiers/list
2. Click **+** to add a new identifier
3. Select **App IDs** → **App**
4. Enter:
   - **Description:** VoiceInk
   - **Bundle ID:** `me.zcs.VoiceInk` (Explicit)
5. No capabilities needed
6. Click **Continue** → **Register**

### 3. Developer ID Provisioning Profile

Create a provisioning profile that links your App ID to your certificate.

1. Go to https://developer.apple.com/account/resources/profiles/list
2. Click **+** to create a new profile
3. Select **Developer ID** under Distribution
4. Select **VoiceInk** App ID
5. Select your Developer ID Application certificate (pick the one with the latest expiration)
6. Name it: `VoiceInk Developer ID`
7. Download the `.provisionprofile` file

**Install the profile:**
```bash
# Extract UUID and install with correct filename
UUID=$(/usr/libexec/PlistBuddy -c "Print UUID" /dev/stdin <<< $(/usr/bin/security cms -D -i ~/Downloads/VoiceInk_Developer_ID.provisionprofile))
cp ~/Downloads/VoiceInk_Developer_ID.provisionprofile ~/Library/MobileDevice/Provisioning\ Profiles/$UUID.provisionprofile
```

Or just double-click the file to install it.

### 4. Notarization Credentials

Apple requires notarization for all Developer ID apps. Store your credentials in the keychain.

**Option A: App Store Connect API Key (recommended)**
1. Go to https://appstoreconnect.apple.com/access/integrations/api
2. Click **Team Keys** → **Generate API Key**
3. Download the `.p8` file (can only download once)
4. Store credentials:
```bash
xcrun notarytool store-credentials "AC_PASSWORD" \
  --key /path/to/AuthKey_XXXXXX.p8 \
  --key-id XXXXXX \
  --issuer YOUR-ISSUER-UUID
```

**Option B: App-Specific Password**
1. Go to https://appleid.apple.com/account/manage
2. Under **Sign-In and Security** → **App-Specific Passwords**, generate a password
3. Store credentials:
```bash
xcrun notarytool store-credentials "AC_PASSWORD" \
  --apple-id "your@email.com" \
  --team-id "NRD52JHX45" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

## Building a Release

### Full Release Build

Run the complete pipeline (archive → export → notarize → DMG):

```bash
make release
```

This creates `build/VoiceInk-{version}.dmg` ready for distribution.

### Individual Steps

```bash
make archive    # Build Release archive
make export     # Export signed .app from archive
make notarize   # Submit to Apple, wait, staple ticket
make dmg        # Create signed DMG
```

### Clean Up

```bash
make clean-dist  # Remove build/ directory
```

## What Each Step Does

### Archive
- Builds the app in Release configuration
- Creates `build/VoiceInk.xcarchive`

### Export
- Generates `ExportOptions.plist` for Developer ID distribution
- Exports signed `.app` to `build/export/VoiceInk.app`
- Signs with Developer ID Application certificate
- Embeds the provisioning profile

### Notarize
- Zips the app (required format for notarytool)
- Submits to Apple's notary service
- Waits for approval (usually 1-5 minutes)
- Staples the notarization ticket to the app
- Verifies with `spctl`

### DMG
- Creates a compressed DMG from the notarized app
- Signs the DMG with Developer ID Application
- Names it `VoiceInk-{version}.dmg`

## Verification

After building, verify the app is properly signed and notarized:

```bash
# Check code signature
codesign -dv --verbose=2 build/export/VoiceInk.app

# Check notarization
spctl -a -vv build/export/VoiceInk.app
# Should show: "source=Notarized Developer ID"

# Check DMG signature
codesign -dv build/VoiceInk-*.dmg
```

## Troubleshooting

### "No profiles for 'me.zcs.VoiceInk' were found"
- Install the provisioning profile (see Prerequisites #3)
- Make sure the profile name in `Makefile` matches exactly: `VoiceInk Developer ID`

### "ambiguous (matches multiple certificates)"
- The Makefile uses the certificate SHA-1 hash `555066E4A3E7123BE9E073B0A7E3AE1F355669A1`
- If you need to use a different certificate, find its hash:
  ```bash
  security find-identity -v -p codesigning | grep "Developer ID Application"
  ```
- Update the hash in the `dmg` target in `Makefile`

### Notarization fails
- Check the log:
  ```bash
  xcrun notarytool log <submission-id> --keychain-profile "AC_PASSWORD"
  ```
- Common issues: unsigned nested code, missing hardened runtime, restricted entitlements

### "Invalid credentials in keychain for ... missing Xcode-Token"
- This warning is harmless and doesn't affect the build
- It's Xcode trying to access Apple Developer account credentials that aren't stored

## Configuration

Key values in `Makefile`:

| Variable | Value | Description |
|----------|-------|-------------|
| `TEAM_ID` | `NRD52JHX45` | Apple Developer Team ID |
| `KEYCHAIN_PROFILE` | `AC_PASSWORD` | Notarytool credentials profile name |

The provisioning profile name `VoiceInk Developer ID` is hardcoded in the `export` target.
