import Foundation

struct LocalTranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        throw ProviderError.unsupported("Not used in the network fixture.")
    }
}

private final class ResponseFixtureProtocol: URLProtocol {
    static let lock = NSLock()
    static var requests: [String: Int] = [:]

    static func requestCount(for host: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requests[host] ?? 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.requests[url.host ?? ""] = (Self.requests[url.host ?? ""] ?? 0) + 1
        Self.lock.unlock()

        if url.path == "/same-redirect" || url.path == "/cross-redirect" {
            let host = url.path == "/same-redirect" ? "fixture.test" : "other.fixture.test"
            let destination = URL(string: "https://\(host)/final")!
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": destination.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: destination), redirectResponse: response)
            return
        }

        if url.path == "/cancel" {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
                guard let self, !self.stopped else { return }
                self.client?.urlProtocol(self, didLoad: Data("late".utf8))
                self.client?.urlProtocolDidFinishLoading(self)
            }
            return
        }

        let status = url.path == "/error" ? 503 : 200
        var headers: [String: String] = ["Content-Type": "application/octet-stream"]
        let byteCount: Int
        switch url.path {
        case "/exact", "/upload-exact":
            byteCount = Network.maxResponseBytes
            headers["Content-Length"] = String(byteCount)
        case "/known-over":
            byteCount = Network.maxResponseBytes + 1
            headers["Content-Length"] = String(byteCount)
        case "/lied-length":
            byteCount = Network.maxResponseBytes + 1
            headers["Content-Length"] = "1"
        case "/error":
            byteCount = 5
            headers["Content-Length"] = "5"
        case "/final":
            byteCount = 1
            headers["Content-Length"] = "1"
        default:
            byteCount = Network.maxResponseBytes + 1
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        guard url.path != "/known-over" else { return }

        let chunk = Data(repeating: 0x61, count: 32 * 1024)
        var remaining = byteCount
        while remaining > 0 && !stopped {
            let size = min(remaining, chunk.count)
            client?.urlProtocol(self, didLoad: size == chunk.count ? chunk : chunk.prefix(size))
            remaining -= size
        }
        if !stopped { client?.urlProtocolDidFinishLoading(self) }
    }

    private var stopped = false
    override func stopLoading() { stopped = true }
}

@main
enum NetworkResponseCheck {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponseFixtureProtocol.self]
        let session = Network.makeSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let exact = try await Network.boundedTransfer(request("/exact"), bodyFile: nil, using: session)
        precondition(exact.0.count == Network.maxResponseBytes)

        let uploadFile = FileManager.default.temporaryDirectory.appendingPathComponent("network-upload-\(UUID().uuidString)")
        try Data("fixture upload".utf8).write(to: uploadFile)
        defer { try? FileManager.default.removeItem(at: uploadFile) }
        let uploaded = try await Network.boundedTransfer(request("/upload-exact"), bodyFile: uploadFile, using: session)
        precondition(uploaded.0.count == Network.maxResponseBytes)
        try await expectTooLargeUpload("/upload-over", file: uploadFile, using: session)

        try await expectTooLarge("/known-over", using: session)
        try await expectTooLarge("/unknown-over", using: session)
        try await expectTooLarge("/lied-length", using: session)

        let error = try await fetch(request("/error"), bodyFile: nil, using: session)
        precondition(error.response.statusCode == 503 && String(decoding: error.data, as: UTF8.self) == "aaaaa")

        let cancellation = Task { try await fetch(request("/cancel"), bodyFile: nil, using: session) }
        try await Task.sleep(for: .milliseconds(30))
        cancellation.cancel()
        do {
            _ = try await cancellation.value
            preconditionFailure("Cancelled response completed successfully")
        } catch is CancellationError { }

        let same = try await Network.boundedTransfer(request("/same-redirect"), bodyFile: nil, using: session)
        precondition(String(decoding: same.0, as: UTF8.self).hasPrefix("a"))
        do {
            _ = try await Network.boundedTransfer(request("/cross-redirect"), bodyFile: nil, using: session)
            preconditionFailure("Cross-host redirect was followed")
        } catch { }
        let externalRequests = ResponseFixtureProtocol.requestCount(for: "other.fixture.test")
        precondition(externalRequests == 0)
        print("Bounded data and upload responses, overflow, HTTP errors, cancellation, and redirect policy OK.")
    }

    private static func request(_ path: String) -> URLRequest {
        URLRequest(url: URL(string: "https://fixture.test\(path)")!)
    }

    private static func expectTooLarge(_ path: String, using session: URLSession) async throws {
        do {
            _ = try await Network.boundedTransfer(request(path), bodyFile: nil, using: session)
            preconditionFailure("Oversized response was accepted: \(path)")
        } catch ProviderError.http(let status, _) {
            precondition(status == 413)
        }
    }

    private static func expectTooLargeUpload(_ path: String, file: URL, using session: URLSession) async throws {
        do {
            _ = try await Network.boundedTransfer(request(path), bodyFile: file, using: session)
            preconditionFailure("Oversized upload response was accepted: \(path)")
        } catch ProviderError.http(let status, _) {
            precondition(status == 413)
        }
    }
}
