import Foundation

/// File-backed multipart body. Large recordings are copied in bounded chunks
/// instead of being duplicated in process memory.
final class MultipartFormData {
    let boundary = "Dictabar-\(UUID().uuidString)"
    let fileURL: URL

    private var handle: FileHandle?

    init() throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Dictabar-form-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: fileURL)
    }

    deinit {
        try? handle?.close()
        try? FileManager.default.removeItem(at: fileURL)
    }

    func addField(_ name: String, _ value: String) throws {
        try append("--\(boundary)\r\n")
        try append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        try append("\(value)\r\n")
    }

    func addFile(_ name: String, url: URL, mimeType: String) throws {
        try append("--\(boundary)\r\n")
        try append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(url.lastPathComponent)\"\r\n")
        try append("Content-Type: \(mimeType)\r\n\r\n")

        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            try handle?.write(contentsOf: chunk)
        }
        try append("\r\n")
    }

    func close() throws {
        try append("--\(boundary)--\r\n")
        try handle?.synchronize()
        try handle?.close()
        handle = nil
    }

    func apply(to request: inout URLRequest) throws {
        let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")
    }

    private func append(_ string: String) throws {
        try handle?.write(contentsOf: Data(string.utf8))
    }
}
