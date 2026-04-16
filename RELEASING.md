# Releasing Crooner

## Prerequisites

- Xcode 15+
- Apple Developer account enrolled in the Developer ID program
- `notarytool` credentials stored in keychain (see step 4)
- `create-dmg` installed: `brew install create-dmg`

## Steps

### 1. Bump the version

Edit `project.yml` and set `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`:

```yaml
settings:
  base:
    MARKETING_VERSION: "1.2.0"        # shown in About box / App Store
    CURRENT_PROJECT_VERSION: "42"     # monotonically increasing build number
```

Then regenerate the project:

```bash
xcodegen generate
```

### 2. Archive

```bash
xcodebuild archive \
  -scheme Crooner \
  -configuration Release \
  -archivePath build/Crooner.xcarchive
```

Or use **Xcode → Product → Archive** and confirm the scheme is set to *Release*.

### 3. Export with Developer ID

```bash
xcodebuild -exportArchive \
  -archivePath build/Crooner.xcarchive \
  -exportPath   build/export \
  -exportOptionsPlist ExportOptions.plist
```

`ExportOptions.plist` (create once, commit to repo):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>             <string>developer-id</string>
  <key>signingStyle</key>       <string>automatic</string>
  <key>teamID</key>             <string>YOUR_TEAM_ID</string>
  <key>hardendedRuntime</key>   <true/>
  <key>stripSwiftSymbols</key>  <true/>
</dict>
</plist>
```

Replace `YOUR_TEAM_ID` with your 10-character Apple team identifier.

### 4. Store notarytool credentials (one-time)

```bash
xcrun notarytool store-credentials "crooner-notary" \
  --apple-id  "you@example.com" \
  --team-id   "YOUR_TEAM_ID" \
  --password  "@keychain:AC_PASSWORD"   # app-specific password
```

### 5. Notarise

```bash
xcrun notarytool submit build/export/Crooner.app \
  --keychain-profile "crooner-notary" \
  --wait
```

The `--wait` flag blocks until Apple returns a result (usually under 2 minutes).
On success you'll see `status: Accepted`.

### 6. Staple the ticket

```bash
xcrun stapler staple build/export/Crooner.app
```

Verify:

```bash
spctl --assess --type execute --verbose build/export/Crooner.app
```

Expected output: `source=Notarized Developer ID`.

### 7. Build the DMG

```bash
create-dmg \
  --volname "Crooner" \
  --volicon "Crooner/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png" \
  --window-pos  200 120 \
  --window-size 600 400 \
  --icon-size 128 \
  --icon "Crooner.app" 150 185 \
  --app-drop-link 450 185 \
  "build/Crooner-1.0.0.dmg" \
  "build/export/"
```

Update the version in the filename each release.

### 8. Notarise the DMG

Repeat steps 5–6 for the `.dmg`:

```bash
xcrun notarytool submit "build/Crooner-1.0.0.dmg" \
  --keychain-profile "crooner-notary" \
  --wait

xcrun stapler staple "build/Crooner-1.0.0.dmg"
```

### 9. Verify and distribute

```bash
spctl --assess --type open --context context:primary-signature \
  --verbose "build/Crooner-1.0.0.dmg"
```

Upload `build/Crooner-1.0.0.dmg` to GitHub Releases, your website, or wherever
you distribute the app.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `The executable does not have the hardened runtime enabled` | Confirm `ENABLE_HARDENED_RUNTIME = YES` in project.yml and re-archive |
| Notarisation rejected — camera/mic entitlements | Ensure entitlements file is included in the archive; check with `codesign -d --entitlements - Crooner.app` |
| `spctl` says *rejected* after stapling | The staple ticket may not have been written; re-run `stapler staple` and verify with `stapler validate` |
| AVFoundation/ScreenCaptureKit crash on first launch | macOS 13 Gatekeeper quarantine: users must right-click → Open on first launch, or you must clear quarantine with `xattr -cr Crooner.app` before packaging |
