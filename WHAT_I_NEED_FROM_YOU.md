# What I need from you (before public ship)

FlowDictate is prepared for Cloudflare updates and a signed public release.
Do these in order; then ask me to run the release path.

## 1. Apple signing (required for strangers’ Macs)

You currently ship with **Apple Development** — fine on *your* machine only.

1. Paid [Apple Developer Program](https://developer.apple.com/programs/).
2. In Xcode → Settings → Accounts: add your Apple ID / team `8J49699RB4`.
3. Create certificate: **Developer ID Application** (not Mac App Distribution).
4. Create an **app-specific password** at appleid.apple.com.
5. Store notary credentials once:

```bash
xcrun notarytool store-credentials "AC_PASSWORD" \
  --apple-id "YOUR_APPLE_ID@email.com" \
  --team-id "8J49699RB4" \
  --password "app-specific-password"
```

6. Tell me when Developer ID is available in Keychain (`security find-identity -v -p codesigning` should list **Developer ID Application**).

I will then: Archive → Developer ID → notarize → staple → re-zip.

## 2. Cloudflare R2 (auto-update CDN)

App already polls:

`https://updates.flowdictate.app/appcast.xml`

Either:

### Option A — custom domain (preferred, matches code)
1. Cloudflare account.
2. R2 bucket, e.g. `flowdictate-updates`, **public** via custom domain `updates.flowdictate.app`.
3. DNS CNAME for that domain → R2 public bucket (Cloudflare UI wizard).
4. Create **R2 API token** with Object Read & Write on that bucket.
5. Give me (paste in chat or local env file — don’t commit):

```bash
export CLOUDFLARE_ACCOUNT_ID="..."
export R2_ACCESS_KEY_ID="..."
export R2_SECRET_ACCESS_KEY="..."
export R2_BUCKET="flowdictate-updates"
export UPDATE_PUBLIC_BASE="https://updates.flowdictate.app"
```

### Option B — temporary public R2.dev URL
Same bucket + `r2.dev` public URL. Then tell me the base URL so I change `SUFeedURL` / `UpdateManager.defaultFeedURL` / allowed hosts.

## 3. Optional tools on this Mac

```bash
brew install awscli   # R2 uploads via S3 API
# gh already works
```

## 4. What you do *not* need yet

- Sparkle EdDSA keys — feed works without install-in-place; Sparkle is next step after first public CDN works.
- Mac App Store — skip (sandbox breaks global dictation).

## 5. After you deliver keys

Say: **“ключи есть”** and paste env vars (or path to a local untracked `.env.release`).

I will:

1. Switch project to Developer ID for Release.
2. Notarize + staple.
3. `./scripts/release.sh --upload --github`
4. Install notarized app to `/Applications`.
5. Verify appcast URL returns 200 and app “Check for Updates” sees the build.

## Privacy blurb (for landing / README)

> FlowDictate records only while you hold/toggle dictation. Audio is sent only to the speech provider you choose. API keys stay in Keychain. Transcripts are optional and stored only on this Mac if you enable history. No FlowDictate cloud account.
