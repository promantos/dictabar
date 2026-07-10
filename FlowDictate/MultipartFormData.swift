import Foundation

struct MultipartFormData {
    let boundary = "FlowDictate-\(UUID().uuidString)"
    private(set) var data = Data()

    mutating func addField(_ name: String, _ value: String) {
        data.append("--\(boundary)\r\n")
        data.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        data.append("\(value)\r\n")
    }

    mutating func addFile(_ name: String, url: URL, mimeType: String) throws {
        data.append("--\(boundary)\r\n")
        data.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(url.lastPathComponent)\"\r\n")
        data.append("Content-Type: \(mimeType)\r\n\r\n")
        data.append(try Data(contentsOf: url))
        data.append("\r\n")
    }

    mutating func close() {
        data.append("--\(boundary)--\r\n")
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
