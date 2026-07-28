import AVFoundation
import CoreAudio
import Foundation

/// Records microphone audio to the WAV format accepted by every Dictabar provider.
/// AVAudioRecorder is deliberately used here: it is the proven macOS capture path for
/// this app and lets Core Audio own buffering, conversion and WAV finalization.
@MainActor
final class AudioRecorder {
    private static let originalInputRecoveryKey = "audio.originalInputUID"

    private var recorder: AVAudioRecorder?
    private var outputURL: URL?
    private var isRecording = false
    private var previousDefaultInputUID: String?

    /// Delete only genuinely stale files so another active instance is never disrupted.
    static func cleanupStaleTempRecordings() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: fm.temporaryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var removed = 0
        for url in items {
            let name = url.lastPathComponent
            guard name.hasPrefix("Dictabar-"), name.hasSuffix(".wav"),
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate,
                  Date().timeIntervalSince(modified) > 24 * 60 * 60 else { continue }
            try? fm.removeItem(at: url)
            removed += 1
        }
        if removed > 0 {
            DiagnosticsLogger.shared.log("audio: cleaned \(removed) stale temp recording(s)")
        }
    }

    /// Restore a device left selected if the previous process died during recording.
    static func recoverInputDeviceIfNeeded() {
        let defaults = UserDefaults.standard
        guard let uid = defaults.string(forKey: originalInputRecoveryKey) else { return }
        if setDefaultInputDevice(uniqueID: uid) {
            defaults.removeObject(forKey: originalInputRecoveryKey)
            DiagnosticsLogger.shared.log("audio: recovered original input device")
        }
    }

    func start(deviceID: String) async throws -> URL {
        if isRecording { cancel() }

        try selectInputIfNeeded(deviceID)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Dictabar-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let recorder: AVAudioRecorder
        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
        } catch {
            restoreDefaultInputIfNeeded()
            throw AudioRecorderError.cannotStart(error.localizedDescription)
        }

        recorder.isMeteringEnabled = false
        guard recorder.prepareToRecord() else {
            restoreDefaultInputIfNeeded()
            try? FileManager.default.removeItem(at: url)
            throw AudioRecorderError.cannotStart("prepareToRecord returned false")
        }
        guard recorder.record() else {
            restoreDefaultInputIfNeeded()
            try? FileManager.default.removeItem(at: url)
            throw AudioRecorderError.cannotStart(
                "record() returned false — check microphone permission and input device"
            )
        }

        self.recorder = recorder
        outputURL = url
        isRecording = true
        DiagnosticsLogger.shared.log("audio: recording started \(url.lastPathComponent)")
        return url
    }

    func stop() async throws -> URL {
        guard isRecording, let recorder, let url = outputURL else {
            throw AudioRecorderError.notRecording
        }

        recorder.stop()
        self.recorder = nil
        outputURL = nil
        isRecording = false
        restoreDefaultInputIfNeeded()

        // AVAudioRecorder finalizes the WAV asynchronously on some macOS versions.
        try? await Task.sleep(for: .milliseconds(80))

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let frames = (try? AVAudioFile(forReading: url).length) ?? 0
        DiagnosticsLogger.shared.log("audio: stopped size=\(size) frames=\(frames)")
        guard size > 4_096, frames > 0 else {
            try? FileManager.default.removeItem(at: url)
            throw AudioRecorderError.emptyRecording
        }
        return url
    }

    func cancel() {
        recorder?.stop()
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
        recorder = nil
        outputURL = nil
        isRecording = false
        restoreDefaultInputIfNeeded()
        DiagnosticsLogger.shared.log("audio: cancelled")
    }

    private func selectInputIfNeeded(_ deviceID: String) throws {
        guard !deviceID.isEmpty else { return }
        guard Self.coreAudioDeviceID(uniqueID: deviceID) != nil else {
            throw AudioRecorderError.deviceUnavailable
        }
        guard let current = Self.currentDefaultInputUID(), current != deviceID else { return }

        UserDefaults.standard.set(current, forKey: Self.originalInputRecoveryKey)
        guard Self.setDefaultInputDevice(uniqueID: deviceID) else {
            UserDefaults.standard.removeObject(forKey: Self.originalInputRecoveryKey)
            throw AudioRecorderError.cannotStart("selected microphone could not be activated")
        }
        previousDefaultInputUID = current
    }

    private func restoreDefaultInputIfNeeded() {
        guard let uid = previousDefaultInputUID else { return }
        previousDefaultInputUID = nil
        if Self.setDefaultInputDevice(uniqueID: uid) {
            UserDefaults.standard.removeObject(forKey: Self.originalInputRecoveryKey)
            DiagnosticsLogger.shared.log("audio: restored original input device")
        }
    }

    private static func currentDefaultInputUID() -> String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else { return nil }
        return uniqueID(for: deviceID)
    }

    @discardableResult
    private static func setDefaultInputDevice(uniqueID: String) -> Bool {
        guard let deviceID = coreAudioDeviceID(uniqueID: uniqueID) else { return false }
        var selected = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &selected
        ) == noErr
    }

    private static func coreAudioDeviceID(uniqueID: String) -> AudioDeviceID? {
        var propertySize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize
        ) == noErr else { return nil }

        var devices = [AudioDeviceID](
            repeating: 0,
            count: Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize, &devices
        ) == noErr else { return nil }
        return devices.first { Self.uniqueID(for: $0) == uniqueID }
    }

    private static func uniqueID(for device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value?.takeUnretainedValue() as String?
    }
}

enum AudioRecorderError: LocalizedError {
    case notRecording
    case cannotStart(String)
    case emptyRecording
    case deviceUnavailable

    var errorDescription: String? {
        switch self {
        case .notRecording:
            "Recording is not active."
        case let .cannotStart(detail):
            "Could not start the microphone recorder (\(detail))."
        case .emptyRecording:
            "Recording produced no audio. Hold a bit longer and try again."
        case .deviceUnavailable:
            "The selected microphone is unavailable. Choose another microphone in Settings."
        }
    }
}
