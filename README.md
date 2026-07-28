# Dictabar

Menu-bar speech-to-text for macOS. Hold or toggle a shortcut, speak, text is inserted into the frontmost app.

## Install

1. Download the latest zip from [Releases](https://github.com/promantos/dictabar/releases) or `https://updates.dictabar.app/`.
2. Unzip → drag **Dictabar.app** to **Applications**.
3. Launch. Allow **Microphone** (required) and **Accessibility** (to insert text). Right-⌘ shortcuts also need **Input Monitoring**.

## First run

1. **Quick Start** — pick OpenAI / Groq / Deepgram / … and paste an API key.
2. **Permissions** — mic + accessibility.
3. Dictate with **Right Command** (default) or set a custom shortcut in Settings.

## Privacy

- Audio is recorded only while dictating.
- Audio is sent **only** to the speech provider you configure.
- API keys stay in `~/Library/Application Support/Dictabar/secrets.json` with `0600` permissions.
- Optional local **History** (last 30 transcripts) never leaves this Mac.
- Temp WAV files are deleted after each run (unless Debug is on).

## Updates

The app checks `https://updates.dictabar.app/appcast.xml` on launch (optional).
Until Cloudflare R2 is wired, use GitHub Releases.

## Build (dev)

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
./scripts/release.sh            # Release build + zip + appcast
./scripts/release.sh --github   # + GitHub release asset
./scripts/release.sh --upload   # + R2 (needs Cloudflare env — see WHAT_I_NEED_FROM_YOU.md)
```

Requires full **Xcode** (not only Command Line Tools).

## Signing / public ship

See [PRODUCTION.md](PRODUCTION.md) and [WHAT_I_NEED_FROM_YOU.md](WHAT_I_NEED_FROM_YOU.md).

Public distribution needs **Developer ID Application** + **notarization**. Development-signed builds are for the machine that signed them.
