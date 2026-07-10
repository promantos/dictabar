import AVFoundation
import Foundation

struct MicrophoneDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

@MainActor
final class MicrophoneDeviceManager: ObservableObject {
    @Published private(set) var devices: [MicrophoneDevice] = []

    func refresh() {
        devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
            .devices
            .map { MicrophoneDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    func deviceName(for id: String) -> String {
        guard !id.isEmpty else { return "System default input" }
        return devices.first { $0.id == id }?.name ?? "Unavailable microphone"
    }
}
