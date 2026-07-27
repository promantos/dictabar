import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Records the selected microphone to a mono 16 kHz LINEAR16 WAV without
/// changing the user's system-wide default input device.
@MainActor
final class AudioRecorder {
    private var engine: AVAudioEngine?
    private var writer: AudioCaptureWriter?
    private var outputURL: URL?
    private var isRecording = false

    /// Delete only genuinely stale files so a second active instance is never disrupted.
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
            guard name.hasPrefix("FlowDictate-"), name.hasSuffix(".wav"),
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

    func start(deviceID: String) async throws -> URL {
        if isRecording { cancel() }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowDictate-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let engine = AVAudioEngine()
        let input = engine.inputNode

        if !deviceID.isEmpty {
            guard let coreDevice = Self.coreAudioDeviceID(uniqueID: deviceID),
                  let unit = input.audioUnit else {
                throw AudioRecorderError.deviceUnavailable
            }
            var selected = coreDevice
            let status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &selected,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                DiagnosticsLogger.shared.log("audio: select device failed status=\(status)")
                throw AudioRecorderError.cannotStart("selected microphone could not be activated")
            }
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.cannotStart("microphone returned an invalid audio format")
        }
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
        let writer = try AudioCaptureWriter(url: url, inputFormat: inputFormat, targetFormat: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { buffer, _ in
            writer.consume(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            try? FileManager.default.removeItem(at: url)
            throw AudioRecorderError.cannotStart(error.localizedDescription)
        }

        self.engine = engine
        self.writer = writer
        outputURL = url
        isRecording = true
        DiagnosticsLogger.shared.log(
            "audio: recording started rate=\(Int(inputFormat.sampleRate)) channels=\(inputFormat.channelCount)"
        )
        return url
    }

    func stop() async throws -> URL {
        guard isRecording, let engine, let writer, let url = outputURL else {
            throw AudioRecorderError.notRecording
        }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
        self.writer = nil
        outputURL = nil
        isRecording = false

        if let error = writer.error {
            try? FileManager.default.removeItem(at: url)
            throw AudioRecorderError.cannotStart(error.localizedDescription)
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        DiagnosticsLogger.shared.log("audio: stopped size=\(size)")
        guard size > 44 else {
            try? FileManager.default.removeItem(at: url)
            throw AudioRecorderError.emptyRecording
        }
        return url
    }

    func cancel() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
        engine = nil
        writer = nil
        outputURL = nil
        isRecording = false
        DiagnosticsLogger.shared.log("audio: cancelled")
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

        return devices.first { device in
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var value: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = withUnsafeMutablePointer(to: &value) {
                AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &size, $0)
            }
            return status == noErr && value?.takeUnretainedValue() as String? == uniqueID
        }
    }
}

private final class AudioCaptureWriter: @unchecked Sendable {
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    private let lock = NSLock()
    private var storedError: Error?

    init(url: URL, inputFormat: AVAudioFormat, targetFormat: AVAudioFormat) throws {
        file = try AVAudioFile(
            forWriting: url,
            settings: targetFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioRecorderError.cannotStart("audio format conversion is unavailable")
        }
        self.converter = converter
        self.targetFormat = targetFormat
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func consume(_ input: AVAudioPCMBuffer) {
        guard error == nil else { return }
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio) + 16)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, state in
            if supplied {
                state.pointee = .noDataNow
                return nil
            }
            supplied = true
            state.pointee = .haveData
            return input
        }
        guard status != .error, conversionError == nil else {
            store(conversionError ?? AudioRecorderError.cannotStart("audio conversion failed"))
            return
        }
        guard output.frameLength > 0 else { return }
        do {
            try file.write(from: output)
        } catch {
            store(error)
        }
    }

    private func store(_ error: Error) {
        lock.lock()
        if storedError == nil { storedError = error }
        lock.unlock()
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
