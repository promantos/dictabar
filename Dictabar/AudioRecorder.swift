import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

private final class CapturedAudioBuffer: @unchecked Sendable {
    let value: AVAudioPCMBuffer

    init(_ value: AVAudioPCMBuffer) {
        self.value = value
    }
}

private final class AudioCaptureState: @unchecked Sendable {
    let lock = NSLock()
    private let writeQueue = DispatchQueue(
        label: "app.dictabar.audio-file-writer",
        qos: .utility
    )
    private let pendingWrites = DispatchGroup()
    let file: AVAudioFile
    let converter: AVAudioConverter
    private var acceptingBuffers = true
    private(set) var failure: String?

    init(file: AVAudioFile, converter: AVAudioConverter) {
        self.file = file
        self.converter = converter
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let canAccept = acceptingBuffers && failure == nil
        lock.unlock()
        guard canAccept else { return }

        guard let copiedBuffer = Self.copy(buffer) else {
            setFailure("Could not copy an audio buffer while recording.")
            return
        }

        lock.lock()
        guard acceptingBuffers, failure == nil else {
            lock.unlock()
            return
        }
        pendingWrites.enter()
        lock.unlock()

        let captured = CapturedAudioBuffer(copiedBuffer)
        writeQueue.async { [self, captured] in
            defer { pendingWrites.leave() }
            write(captured.value)
        }
    }

    func finish() {
        lock.lock()
        acceptingBuffers = false
        lock.unlock()
        pendingWrites.wait()
        writeQueue.sync {}
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let canWrite = failure == nil
        lock.unlock()
        guard canWrite else { return }

        let ratio = converter.outputFormat.sampleRate / max(buffer.format.sampleRate, 1)
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 1
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: max(capacity, 1)
        ) else {
            setFailure("Could not allocate the audio conversion buffer.")
            return
        }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
            guard !supplied else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if let conversionError {
            setFailure(conversionError.localizedDescription)
        } else if status == .error {
            setFailure("The audio converter failed while recording.")
        } else if converted.frameLength > 0 {
            do {
                try file.write(from: converted)
            } catch {
                setFailure(error.localizedDescription)
            }
        }
    }

    private func setFailure(_ message: String) {
        lock.lock()
        if failure == nil { failure = message }
        lock.unlock()
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else { return nil }

        let source = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }

        for index in source.indices {
            let sourceBuffer = source[index]
            guard let sourceData = sourceBuffer.mData,
                  let destinationData = destination[index].mData else { return nil }
            let byteCount = min(sourceBuffer.mDataByteSize, destination[index].mDataByteSize)
            memcpy(destinationData, sourceData, Int(byteCount))
            destination[index].mDataByteSize = byteCount
        }
        copy.frameLength = buffer.frameLength
        return copy
    }

    func takeFailure() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }
}

// AVAudioEngine invokes tap callbacks on its realtime messenger queue, not on the
// main actor. Keep closure formation outside AudioRecorder's @MainActor context.
private func installAudioTap(
    on input: AVAudioInputNode,
    format: AVAudioFormat,
    state: AudioCaptureState
) {
    input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
        state.append(buffer)
    }
}

/// Records microphone audio to the WAV format accepted by every Dictabar provider.
/// AVAudioEngine lets the selected input device stay private to this capture unit instead
/// of changing macOS's system-wide default input device.
@MainActor
final class AudioRecorder {
    // Kept only to recover a device left changed by Dictabar <= 0.6.17 after a crash.
    private static let originalInputRecoveryKey = "audio.originalInputUID"

    private var engine: AVAudioEngine?
    private var captureState: AudioCaptureState?
    private var outputURL: URL?
    private var isRecording = false

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

        let selectedDeviceID = try selectedInputDeviceID(deviceID)

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

        let engine = AVAudioEngine()
        let input = engine.inputNode
        guard let audioUnit = input.audioUnit else {
            throw AudioRecorderError.cannotStart("the input audio unit is unavailable")
        }

        if var selectedDeviceID {
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &selectedDeviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                throw AudioRecorderError.cannotStart("the selected microphone could not be attached to the recorder")
            }
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.cannotStart("the selected microphone format is unsupported")
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
        } catch {
            throw AudioRecorderError.cannotStart(error.localizedDescription)
        }

        guard let converter = AVAudioConverter(
            from: inputFormat,
            to: file.processingFormat
        ) else {
            throw AudioRecorderError.cannotStart("the selected microphone format is unsupported")
        }
        converter.downmix = true
        converter.primeMethod = .none

        let captureState = AudioCaptureState(file: file, converter: converter)
        installAudioTap(on: input, format: inputFormat, state: captureState)
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            engine.stop()
            captureState.finish()
            try? FileManager.default.removeItem(at: url)
            throw AudioRecorderError.cannotStart(error.localizedDescription)
        }

        self.engine = engine
        self.captureState = captureState
        outputURL = url
        isRecording = true
        DiagnosticsLogger.shared.log(
            "audio: recording started \(url.lastPathComponent) device=\(deviceID.isEmpty ? "default" : deviceID)"
        )
        return url
    }

    func stop() async throws -> URL {
        guard isRecording, let engine, let state = captureState, let url = outputURL else {
            throw AudioRecorderError.notRecording
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        state.finish()
        self.engine = nil
        self.captureState = nil
        outputURL = nil
        isRecording = false

        // The writer queue has drained. Poll briefly instead of assuming a fixed
        // finalization delay on every disk/device combination.
        for _ in 0..<10 {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let frames = (try? AVAudioFile(forReading: url).length) ?? 0
            if size > 4_096, frames > 0 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }

        if let failure = state.takeFailure() {
            try? FileManager.default.removeItem(at: url)
            throw AudioRecorderError.cannotStart(failure)
        }

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
        let state = captureState
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        state?.finish()
        engine = nil
        captureState = nil
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
        outputURL = nil
        isRecording = false
        DiagnosticsLogger.shared.log("audio: cancelled")
    }

    private func selectedInputDeviceID(_ deviceID: String) throws -> AudioDeviceID? {
        guard !deviceID.isEmpty else { return nil }
        guard let selectedDeviceID = Self.coreAudioDeviceID(uniqueID: deviceID) else {
            throw AudioRecorderError.deviceUnavailable
        }
        return selectedDeviceID
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
