# Dictabar production releases and automatic updates

This is the source of truth for shipping Dictabar outside the Mac App Store.

## 1. Current architecture

| Component | Location | Visibility |
|-----------|----------|------------|
| Source, release scripts, tags | [`promantos/dictabar`](https://github.com/promantos/dictabar) | Public |
| Sparkle feed | [`dictabar-updates/main/appcast.xml`](https://raw.githubusercontent.com/promantos/dictabar-updates/main/appcast.xml) | Public |
| Notarized update zips | [`dictabar-updates/releases`](https://github.com/promantos/dictabar-updates/releases) | Public |
| Installed app | `/Applications/Dictabar.app` | Local |
| Developer ID private key | macOS login Keychain | Local only |
| Notary profile | Keychain profile `Dictabar Notary` | Local only |
| Sparkle EdDSA private key | macOS Keychain | Local only |
| Sparkle EdDSA public key | `Dictabar/Info.plist` → `SUPublicEDKey` | Committed |

There is no Cloudflare R2 dependency in the current release path.

### User-side update flow

```text
Dictabar checks the public appcast
        ↓
Sparkle compares CFBundleVersion with sparkle:version
        ↓
Sparkle downloads Dictabar-x.y.z.zip from the public GitHub Release
        ↓
Sparkle verifies the EdDSA signature and Apple code signature
        ↓
Sparkle replaces /Applications/Dictabar.app and relaunches it
```

Automatic checks are enabled by `SUEnableAutomaticChecks`. Users can also run
**Check for Updates…**. No GitHub account or token is required on the user's Mac.

## 2. One-time release-Mac setup

These items are already configured on the current release Mac.

### Apple signing

- Paid Apple Developer Program membership.
- Team ID: `8J49699RB4`.
- Bundle ID: `app.dictabar.Dictabar`.
- Full Xcode installed.
- **Developer ID Application** certificate and its private key installed in the
  login Keychain.
- Hardened Runtime enabled for Release builds.

Verify the signing identity:

```bash
security find-identity -v -p codesigning
```

The result must contain:

```text
Developer ID Application: Roman Platonov (8J49699RB4)
```

### Apple notarization

Credentials are stored in Keychain under `Dictabar Notary`:

```bash
xcrun notarytool history --keychain-profile "Dictabar Notary"
```

To recreate the profile on another Mac:

```bash
xcrun notarytool store-credentials "Dictabar Notary"
```

Enter the App Store Connect API key information, or the Apple ID, Team ID, and
app-specific password requested by `notarytool`. Never commit these credentials.

### GitHub

`gh` must be authenticated as an account that can push to both repositories:

```bash
gh auth status
gh repo view promantos/dictabar
gh repo view promantos/dictabar-updates
```

### Sparkle signing key

The private EdDSA key is stored in the Keychain and is read by Sparkle's
`sign_update`. Its public half is committed as `SUPublicEDKey`.

Do not regenerate this key for routine releases. Existing installations trust
the current public key; losing the private key would require distributing a
manually installed migration build.

If macOS asks whether `sign_update` may access the key, choose **Always Allow**.

## 3. Release workflow

### Step 1 — bump the version

Update both Release and Debug occurrences in
`Dictabar.xcodeproj/project.pbxproj`:

- `MARKETING_VERSION`: user-visible version, for example `0.6.17`.
- `CURRENT_PROJECT_VERSION`: strictly increasing integer build number.

Never reuse a published build number. Sparkle primarily orders releases by
`sparkle:version`, which is generated from `CURRENT_PROJECT_VERSION`.

### Step 2 — run source checks

```bash
bash Tests/check_permissions.sh
bash Tests/check_provider_catalog.sh
bash Tests/check_hardening.sh
git diff --check
```

### Step 3 — build and publish the zip as a prerelease

```bash
./scripts/release.sh --github
```

The script:

1. Builds the Release configuration with Developer ID and Hardened Runtime.
2. Signs Sparkle's nested XPC services and helper apps inside-out.
3. Verifies the app signature, secure timestamp, and release entitlements.
4. Creates a zip and submits it through `Dictabar Notary`.
5. Waits for Apple notarization, staples the ticket, and runs Gatekeeper.
6. Repackages the stapled app.
7. Signs the zip with the Sparkle EdDSA key.
8. Writes `build/appcast.xml` and repository-root `appcast.xml`.
9. Uploads the zip to `promantos/dictabar-updates` as a GitHub prerelease.

Generated artifacts:

```text
build/DerivedData/Build/Products/Release/Dictabar.app
build/Dictabar-x.y.z.zip
build/appcast.xml
appcast.xml
```

### Step 4 — verify the release candidate

```bash
APP=build/DerivedData/Build/Products/Release/Dictabar.app
codesign --verify --deep --strict --verbose=2 "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"

gh release view "vX.Y.Z" \
  --repo promantos/dictabar-updates \
  --json url,isPrerelease,assets
```

Expected Gatekeeper result:

```text
accepted
source=Notarized Developer ID
```

Do not publish the appcast yet if the release candidate is not ready for every
user. The public appcast, not GitHub's prerelease label, controls Sparkle rollout.

### Step 5 — commit and tag the source

Review the exact changes before staging:

```bash
git status --short
git diff --check
git diff --stat
```

Commit the release changes, push `main`, then create and push the matching tag:

```bash
git add -A
git commit -m "release: Dictabar X.Y.Z"
git push origin main
git tag -a "vX.Y.Z" -m "Dictabar X.Y.Z"
git push origin "vX.Y.Z"
```

### Step 6 — publish the appcast (go live)

`appcast.xml` already exists in the public update repository, so update it with:

```bash
APPCAST_SHA=$(gh api \
  repos/promantos/dictabar-updates/contents/appcast.xml \
  --jq .sha)
APPCAST_CONTENT=$(base64 -i appcast.xml)

gh api --method PUT \
  repos/promantos/dictabar-updates/contents/appcast.xml \
  --field message="Publish Dictabar X.Y.Z appcast" \
  --field content="$APPCAST_CONTENT" \
  --field sha="$APPCAST_SHA"
```

Once this succeeds, all Dictabar installations using the production feed can
discover the release.

### Step 7 — verify public delivery

```bash
set -o pipefail

curl -fsSL \
  https://raw.githubusercontent.com/promantos/dictabar-updates/main/appcast.xml

shasum -a 256 "build/Dictabar-X.Y.Z.zip"
curl -fsSL \
  "https://github.com/promantos/dictabar-updates/releases/download/vX.Y.Z/Dictabar-X.Y.Z.zip" \
  | shasum -a 256
```

The local and remote zip hashes must match.

### Step 8 — test the installed update

Start from an older signed build in `/Applications`, then launch Dictabar and use
**Check for Updates…**, or wait for its scheduled automatic check.

After Sparkle finishes:

```bash
APP=/Applications/Dictabar.app
/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"
```

### Step 9 — mark the GitHub release stable

After the rollout test:

```bash
gh release edit "vX.Y.Z" \
  --repo promantos/dictabar-updates \
  --prerelease=false \
  --latest
```

This changes the GitHub presentation only. Sparkle rollout already began when
the appcast was published.

## 4. Recovery rules

- A bad release should be fixed with a new, higher build number. Sparkle does
  not automatically downgrade users.
- To halt discovery of a release, restore the previous public `appcast.xml`.
- Do not delete a release asset while its item remains in the appcast; clients
  will receive a broken download URL.
- Never commit the Sparkle private key, Apple credentials, `.p12` files,
  app-specific passwords, API keys, or GitHub tokens.
- Keep a secure backup of the Developer ID private key and Sparkle private key
  outside the repository.

## 5. User permissions and local data

| Permission | Why |
|------------|-----|
| **Microphone** | Record dictation |
| **Accessibility** | Insert text into other apps |
| **Input Monitoring** | Detect Right Command and side-modifier shortcuts |

Provider API keys are stored in
`~/Library/Application Support/Dictabar/secrets.json`. The directory uses mode
`0700` and the file uses `0600`. Never include that file in diagnostics or
release archives.
