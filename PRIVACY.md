# Dictabar privacy

Last updated: July 29, 2026.

Dictabar is a native macOS application. It has no Dictabar account, analytics,
advertising, or Dictabar-operated speech server.

## Audio

Dictabar records only during an active dictation session.

- With a local model, audio is processed on this Mac.
- With a cloud or custom provider, the completed WAV recording is sent directly
  from the app to the provider selected in Settings.
- Dictabar does not send the recording to any other speech provider.
- The selected provider's privacy, retention, and data-processing terms apply.

Temporary recordings are deleted after processing unless Debug mode is enabled.
If transcription fails, the most recent failed recording can be stored locally
for retry and expires after 24 hours. Debug mode stores up to 10 recordings in
`~/Library/Application Support/Dictabar/DebugRecordings`; old items are pruned
when a new debug recording is retained.

## Local data

Dictabar may store:

- provider API keys in
  `~/Library/Application Support/Dictabar/secrets.json`;
- up to 30 recent transcripts in `transcript-history.json` when History is
  enabled;
- preferences in macOS `UserDefaults`;
- downloaded local models under `~/Library/Caches/qwen3-speech/models`;
- redacted diagnostic metadata and errors in `diagnostics.log`.

The Dictabar Application Support directory uses mode `0700`. Secret, transcript,
audio, and diagnostic files created there use mode `0600`.

History can be disabled or cleared in Settings. API keys can be removed by
clearing a provider key or resetting Dictabar. Downloaded local models can be
removed from the Local Models screen.

## Network connections

Dictabar connects only when needed to:

- the speech provider configured by the user;
- Hugging Face when the user downloads a local model;
- GitHub to check for and download signed application updates.

The app uses no first-party telemetry endpoint.

## macOS permissions

- **Microphone** records an active dictation.
- **Accessibility** inserts the resulting text into another app.
- **Input Monitoring** is required only for shortcuts that depend on a specific
  left or right modifier key.

Permissions can be revoked at any time in macOS System Settings.

## Removing Dictabar data

After quitting Dictabar, remove these folders to delete its local application
data and downloaded models:

```text
~/Library/Application Support/Dictabar
~/Library/Caches/qwen3-speech
```

macOS privacy permissions and preferences can be reset separately in System
Settings or with the standard `tccutil` and `defaults` tools.

## Questions

For privacy questions, open a
[GitHub issue](https://github.com/promantos/dictabar/issues) without including
API keys, recordings, transcripts, or other private data. Report security
problems privately according to [SECURITY.md](SECURITY.md).
