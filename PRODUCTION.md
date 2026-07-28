# Dictabar — production: signing, updates, local secrets

## 1. Code signing (Apple Developer account)

You need a paid **Apple Developer Program** membership ($99/year).

### Certificates you will use

| Certificate | When |
|-------------|------|
| **Apple Development** | Local debug / TestFlight-style internal runs |
| **Developer ID Application** | Distribute **outside** the Mac App Store (DMG / ZIP / your site / R2) |
| **Mac App Distribution** | Only if you ship via the **Mac App Store** |

For a menu-bar utility distributed yourself (R2 / website), use **Developer ID Application**.

### One-time setup in Xcode

1. Open `Dictabar.xcodeproj` in **full Xcode** (not only Command Line Tools).
2. Select the **Dictabar** target → **Signing & Capabilities**.
3. Enable **Automatically manage signing**.
4. Choose your **Team** (the one linked to your developer account).
5. Bundle ID is `app.dictabar.Dictabar` — register it once in [developer.apple.com](https://developer.apple.com/account/resources/identifiers/list) if Xcode doesn’t create it.
6. Keep **Hardened Runtime** on (already set in the project).

### Archive & export (Developer ID build)

```text
Product → Archive
→ Distribute App → Developer ID
→ Upload / Export
```

Or CLI (after Xcode is selected with `xcode-select -s /Applications/Xcode.app`):

```bash
xcodebuild -project Dictabar.xcodeproj -scheme Dictabar \
  -configuration Release -archivePath build/Dictabar.xcarchive archive

xcodebuild -exportArchive -archivePath build/Dictabar.xcarchive \
  -exportPath build/export -exportOptionsPlist ExportOptions-DeveloperID.plist
```

Example `ExportOptions-DeveloperID.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>teamID</key>
  <string>YOUR_TEAM_ID</string>
  <key>signingStyle</key>
  <string>automatic</string>
</dict>
</plist>
```

### Notarization (required for Gatekeeper)

Unsigned or non-notarized apps show scary warnings. After Developer ID export:

```bash
# Zip the .app first
ditto -c -k --keepParent build/export/Dictabar.app build/Dictabar.zip

xcrun notarytool submit build/Dictabar.zip \
  --apple-id "you@email.com" \
  --team-id "YOUR_TEAM_ID" \
  --password "app-specific-password" \
  --wait

xcrun stapler staple build/export/Dictabar.app
```

Create an **app-specific password** at appleid.apple.com. Prefer storing credentials with:

```bash
xcrun notarytool store-credentials "AC_PASSWORD" \
  --apple-id "you@email.com" --team-id "YOUR_TEAM_ID" --password "..."
```

Then: `xcrun notarytool submit ... --keychain-profile "AC_PASSWORD" --wait`.

### Local API-key storage

Dictabar stores provider keys in `~/Library/Application Support/Dictabar/secrets.json`
with directory mode `0700` and file mode `0600`. This avoids Keychain authorization
dialogs in local/ad-hoc builds. The file is readable by the current macOS user and is
less protected than Keychain, so never include it in diagnostics or release archives.

---

## 2. Updates via Cloudflare R2 (or any CDN)

### Mental model

```text
You build + sign + notarize Dictabar.app
        ↓
Pack as .zip or .dmg
        ↓
Upload binary to R2 (public bucket / custom domain)
        ↓
Upload appcast.xml next to it (or another public URL)
        ↓
App polls appcast on launch / “Check for Updates”
        ↓
User downloads new build (today) or Sparkle installs it (later)
```

R2 is only object storage + HTTP. It does **not** push updates by itself. The app must **check a feed**.

### Appcast (Sparkle-compatible)

Host something like:

`https://updates.yourdomain.com/appcast.xml`

Minimal example:

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Dictabar</title>
    <item>
      <title>Dictabar 0.2.0</title>
      <sparkle:version>2</sparkle:version>
      <sparkle:shortVersionString>0.2.0</sparkle:shortVersionString>
      <enclosure
        url="https://updates.yourdomain.com/Dictabar-0.2.0.zip"
        sparkle:version="2"
        sparkle:shortVersionString="0.2.0"
        length="12345678"
        type="application/octet-stream"
        sparkle:edSignature="BASE64_EDDSA_SIGNATURE"/>
      <pubDate>Tue, 08 Jul 2026 12:00:00 +0000</pubDate>
    </item>
  </channel>
</rss>
```

Set the feed URL in:

- `Info.plist` → `SUFeedURL`
- `UpdateManager.defaultFeedURL` in code

### What the app does today

`UpdateManager` fetches the appcast, compares `sparkle:version` / short version to `CFBundleShortVersionString`, and:

- on manual **Check for updates** → opens the enclosure URL if newer
- on launch (if enabled) → quiet check, status only (no browser spam)

### Full auto-update later (Sparkle)

1. Add [Sparkle](https://github.com/sparkle-project/Sparkle) via SPM.
2. Generate EdDSA keys: `./bin/generate_keys` from Sparkle tools.
3. Put **public** key in `Info.plist` → `SUPublicEDKey`.
4. Keep **private** key only on your release machine / CI secrets.
5. Sign each zip: `sign_update Dictabar.zip` → paste into appcast `sparkle:edSignature`.
6. Replace lightweight `UpdateManager` with `SPUStandardUpdaterController`.

**R2 setup sketch**

1. Create bucket `dictabar-updates`.
2. Attach custom domain `updates.yourdomain.com`.
3. Upload `Dictabar-x.y.z.zip` + `appcast.xml`.
4. Cache: short TTL on appcast (e.g. 60s), long TTL on versioned zips.

---

## 3. Release checklist

1. Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in Xcode.
2. Archive → Developer ID → notarize → staple.
3. Zip: `ditto -c -k --keepParent Dictabar.app Dictabar-x.y.z.zip`
4. Sign update (Sparkle) if using framework.
5. Upload zip + updated appcast to R2.
6. Smoke-test on a clean Mac: open app, Gatekeeper OK, dictation works, update check sees the feed.

---

## 4. Permissions users will see

These are **System Settings** privacy prompts — expected once per machine:

| Permission | Why |
|------------|-----|
| **Microphone** | Record dictation |
| **Accessibility** | Paste / type into other apps |
| **Input Monitoring** | Only for Right ⌘ / side modifier shortcuts |

---

## 5. Suggested first public feed URL

Replace placeholders:

```text
https://updates.dictabar.app/appcast.xml
```

Point that hostname at your R2 bucket custom domain.
