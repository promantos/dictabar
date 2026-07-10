import CoreAudio
import Foundation

/// Mutes the default output device for the duration of microphone capture.
/// Falls back to volume=0 when the device has no mute property.
enum SystemAudioMuteService {
    private static let lock = NSLock()
    // Protected by `lock`; marked unsafe for Swift 6 static mutable state rules.
    nonisolated(unsafe) private static var activeRestore: RestoreState?

    private struct RestoreState {
        let deviceID: AudioObjectID
        let muted: UInt32?
        let volume: Float32?
    }

    static func beginMute() {
        lock.lock()
        defer { lock.unlock() }
        guard activeRestore == nil else { return }

        let deviceID = defaultOutputDevice()
        guard deviceID != kAudioObjectUnknown else { return }

        let previousMute = muteValue(deviceID: deviceID)
        let previousVolume = volumeValue(deviceID: deviceID)
        activeRestore = RestoreState(deviceID: deviceID, muted: previousMute, volume: previousVolume)

        if setMuted(true, deviceID: deviceID) {
            return
        }
        // Fallback: pull volume to zero when mute is unsupported (Bluetooth, aggregate, etc.).
        _ = setVolume(0, deviceID: deviceID)
    }

    static func endMute() {
        lock.lock()
        defer { lock.unlock() }
        guard let state = activeRestore else { return }
        activeRestore = nil

        if let muted = state.muted {
            _ = setMuted(muted != 0, deviceID: state.deviceID)
        } else {
            _ = setMuted(false, deviceID: state.deviceID)
        }
        if let volume = state.volume {
            _ = setVolume(volume, deviceID: state.deviceID)
        }
    }

    /// Legacy helper used by older call sites.
    static func withTemporaryMute<T>(_ enabled: Bool, operation: () async throws -> T) async rethrows -> T {
        guard enabled else { return try await operation() }
        beginMute()
        defer { endMute() }
        return try await operation()
    }

    // MARK: - HAL helpers

    @discardableResult
    private static func setMuted(_ muted: Bool, deviceID: AudioObjectID) -> Bool {
        var value: UInt32 = muted ? 1 : 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &value
        )
        return status == noErr
    }

    private static func muteValue(deviceID: AudioObjectID) -> UInt32? {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func volumeValue(deviceID: AudioObjectID) -> Float32? {
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    @discardableResult
    private static func setVolume(_ volume: Float32, deviceID: AudioObjectID) -> Bool {
        var value = max(0, min(1, volume))
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &value
        )
        return status == noErr
    }

    private static func defaultOutputDevice() -> AudioObjectID {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return deviceID
    }
}
