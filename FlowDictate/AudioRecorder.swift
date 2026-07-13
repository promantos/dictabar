import AVFoundation
import CoreAudio
import Foundation

/// Records microphone audio to a WAV file (linear PCM).
/// Uses the main thread — AVAudioRecorder is unreliable off-main on macOS.
@MainActor
final class AudioRecorder {
    private var recorder: AVAudioRecorder?
    private var outputURL: URL?
    private var isRecording = false
    /// System default input restored after recording when we temporarily switched devices.
    private var previousDefaultInputUID: String?

    /// Delete leftover FlowDictate-*.wav files from temp (e.g. after crash).
    static func cleanupStaleTempRecordings() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let items = try? fm.contentsOfDirectory(
            at: tmp,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        var removed = 0
        for url in items {
            let name = url.lastPathComponent
            guard name.hasPrefix("FlowDictate-"), name.hasSuffix(".wav") else { continue }
            try? fm.removeItem(at: url)
            removed += 1
        }
        if removed > 0 {
            DiagnosticsLogger.shared.log("audio: cleaned \(removed) stale temp recording(s)")
        }
    }

    func start(deviceID: String) async throws -> URL {
        if isRecording {
            cancel()
        }

        // Prefer system default; optional device switch via Core Audio UID — always restore later.
        if !deviceID.isEmpty {
            previousDefaultInputUID = currentDefaultInputUID()
            setDefaultInputDeviceIfPossible(uniqueID: deviceID)
        } else {
            previousDefaultInputUID = nil
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowDictate-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        // Linear PCM WAV — most compatible for STT APIs and AVAudioRecorder on macOS.
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
            DiagnosticsLogger.shared.log("audio: AVAudioRecorder init failed: \(error)")
            throw AudioRecorderError.cannotStart(error.localizedDescription)
        }

        recorder.isMeteringEnabled = false
        guard recorder.prepareToRecord() else {
            restoreDefaultInputIfNeeded()
            DiagnosticsLogger.shared.log("audio: prepareToRecord failed path=\(url.path)")
            throw AudioRecorderError.cannotStart("prepareToRecord returned false")
        }
        guard recorder.record() else {
            restoreDefaultInputIfNeeded()
            DiagnosticsLogger.shared.log("audio: record() returned false path=\(url.path)")
            throw AudioRecorderError.cannotStart("record() returned false — check microphone permission and input device")
        }

        self.recorder = recorder
        self.outputURL = url
        self.isRecording = true
        DiagnosticsLogger.shared.log("audio: recording started \(url.lastPathComponent)")
        return url
    }

    func stop() async throws -> URL {
        guard isRecording, let recorder, let url = outputURL else {
            throw AudioRecorderError.notRecording
        }
        recorder.stop()
        self.recorder = nil
        self.outputURL = nil
        self.isRecording = false
        restoreDefaultInputIfNeeded()

        // Ensure file is flushed.
        try? await Task.sleep(for: .milliseconds(40))

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        DiagnosticsLogger.shared.log("audio: stopped size=\(size)")
        guard size > 44 else { // WAV header is 44 bytes
            try? FileManager.default.removeItem(at: url)
            throw AudioRecorderError.emptyRecording
        }
        return url
    }

    func cancel() {
        if let recorder {
            recorder.stop()
        }
        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
        }
        recorder = nil
        outputURL = nil
        isRecording = false
        restoreDefaultInputIfNeeded()
        DiagnosticsLogger.shared.log("audio: cancelled")
    }

    // MARK: - Optional input device selection

    private func restoreDefaultInputIfNeeded() {
        guard let uid = previousDefaultInputUID else { return }
        previousDefaultInputUID = nil
        setDefaultInputDeviceIfPossible(uniqueID: uid)
        DiagnosticsLogger.shared.log("audio: restored previous default input")
    }

    private func currentDefaultInputUID() -> String? {
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

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = withUnsafeMutablePointer(to: &cfUID) { ptr in
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, ptr)
        }
        guard err == noErr, let uid = cfUID?.takeUnretainedValue() as String? else { return nil }
        return uid
    }

    private func setDefaultInputDeviceIfPossible(uniqueID: String) {
        guard let deviceID = coreAudioDeviceID(uniqueID: uniqueID) else {
            DiagnosticsLogger.shared.log("audio: device UID not found, using system default")
            return
        }
        var dev = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &dev
        )
        DiagnosticsLogger.shared.log("audio: set default input status=\(status)")
    }

    private func coreAudioDeviceID(uniqueID: String) -> AudioDeviceID? {
        var propertySize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize
        ) == noErr else { return nil }

        let count = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: max(count, 0))
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize, &devices
        ) == noErr else { return nil }

        for device in devices {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var cfUID: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let err = withUnsafeMutablePointer(to: &cfUID) { ptr in
                AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, ptr)
            }
            guard err == noErr, let uid = cfUID?.takeUnretainedValue() as String?, uid == uniqueID else {
                continue
            }
            return device
        }
        return nil
    }
}

enum AudioRecorderError: LocalizedError {
    case notRecording
    case cannotStart(String)
    case emptyRecording

    var errorDescription: String? {
        switch self {
        case .notRecording: "Recording is not active."
        case let .cannotStart(detail): "Could not start the microphone recorder (\(detail))."
        case .emptyRecording: "Recording produced no audio. Hold a bit longer and try again."
        }
    }
}
