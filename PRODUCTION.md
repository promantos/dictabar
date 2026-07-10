# FlowDictate — production: signing, updates, Keychain

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

1. Open `FlowDictate.xcodeproj` in **full Xcode** (not only Command Line Tools).
2. Select the **FlowDictate** target → **Signing & Capabilities**.
3. Enable **Automatically manage signing**.
4. Choose your **Team** (the one linked to your developer account).
5. Bundle ID is `app.flowdictate.FlowDictate` — register it once in [developer.apple.com](https://developer.apple.com/account/resources/identifiers/list) if Xcode doesn’t create it.
6. Keep **Hardened Runtime** on (already set in the project).

### Archive & export (Developer ID build)

```text
Product → Archive
→ Distribute App → Developer ID
→ Upload / Export
```

Or CLI (after Xcode is selected with `xcode-select -s /Applications/Xcode.app`):

```bash
xcodebuild -project FlowDictate.xcodeproj -scheme FlowDictate \
  -configuration Release -archivePath build/FlowDictate.xcarchive archive

xcodebuild -exportArchive -archivePath build/FlowDictate.xcarchive \
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
ditto -c -k --keepParent build/export/FlowDictate.app build/FlowDictate.zip

xcrun notarytool submit build/FlowDictate.zip \
  --apple-id "you@email.com" \
  --team-id "YOUR_TEAM_ID" \
  --password "app-specific-password" \
  --wait

xcrun stapler staple build/export/FlowDictate.app
```

Create an **app-specific password** at appleid.apple.com. Prefer storing credentials with:

```bash
xcrun notarytool store-credentials "AC_PASSWORD" \
  --apple-id "you@email.com" --team-id "YOUR_TEAM_ID" --password "..."
```

Then: `xcrun notarytool submit ... --keychain-profile "AC_PASSWORD" --wait`.

### Why signing also fixes Keychain popups

Keychain ties secrets to the **code signature** (Team ID + bundle ID).

- Ad-hoc / constantly changing debug signatures → macOS may ask again and again.
- Stable **Developer ID** (or Development with fixed Team) → **one** item, **no** repeated “wants to use your confidential information” dialogs.

FlowDictate stores **all provider keys in a single Keychain item** (`service=app.flowdictate.FlowDictate`, `account=api-keys`). That means at most one authorization event total — not one dialog per provider.

---

## 2. Updates via Cloudflare R2 (or any CDN)

### Mental model

```text
You build + sign + notarize FlowDictate.app
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
    <title>FlowDictate</title>
    <item>
      <title>FlowDictate 0.2.0</title>
      <sparkle:version>2</sparkle:version>
      <sparkle:shortVersionString>0.2.0</sparkle:shortVersionString>
      <enclosure
        url="https://updates.yourdomain.com/FlowDictate-0.2.0.zip"
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
5. Sign each zip: `sign_update FlowDictate.zip` → paste into appcast `sparkle:edSignature`.
6. Replace lightweight `UpdateManager` with `SPUStandardUpdaterController`.

**R2 setup sketch**

1. Create bucket `flowdictate-updates`.
2. Attach custom domain `updates.yourdomain.com`.
3. Upload `FlowDictate-x.y.z.zip` + `appcast.xml`.
4. Cache: short TTL on appcast (e.g. 60s), long TTL on versioned zips.

---

## 3. Release checklist

1. Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in Xcode.
2. Archive → Developer ID → notarize → staple.
3. Zip: `ditto -c -k --keepParent FlowDictate.app FlowDictate-x.y.z.zip`
4. Sign update (Sparkle) if using framework.
5. Upload zip + updated appcast to R2.
6. Smoke-test on a clean Mac: open app, Gatekeeper OK, dictation works, update check sees the feed.

---

## 4. Permissions users will see (normal, not Keychain)

These are **System Settings** privacy prompts — expected once per machine:

| Permission | Why |
|------------|-----|
| **Microphone** | Record dictation |
| **Accessibility** | Paste / type into other apps |
| **Input Monitoring** | Only for Right ⌘ / side modifier shortcuts |

Keychain is separate and should stay quiet after a stable signature.

---

## 5. Suggested first public feed URL

Replace placeholders:

```text
https://updates.flowdictate.app/appcast.xml
```

Point that hostname at your R2 bucket custom domain.
