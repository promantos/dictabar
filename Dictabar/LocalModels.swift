import AudioCommon
import Darwin
import Foundation
import MLX
import MossTranscribe
import NemotronStreamingASR
import ParakeetASR
import Qwen3ASR

enum LocalModelState: Equatable {
    case notInstalled
    case downloading(Double, String)
    case installed
    case failed(String)
}

private enum LocalModelStorage {
    static func cacheDirectory(for model: LocalSpeechModel) throws -> URL {
        try HuggingFaceDownloader.getCacheDirectory(for: model.modelID)
    }

    static func markerURL(for model: LocalSpeechModel) throws -> URL {
        try cacheDirectory(for: model).appendingPathComponent(".dictabar-installed")
    }

    static func isInstalled(_ model: LocalSpeechModel) -> Bool {
        guard let marker = try? markerURL(for: model),
              let directory = try? cacheDirectory(for: model) else { return false }
        return FileManager.default.fileExists(atPath: marker.path)
            && HuggingFaceDownloader.weightsExist(in: directory)
    }
}

@MainActor
final class LocalModelManager: ObservableObject {
    static let shared = LocalModelManager()

    @Published private(set) var states: [LocalSpeechModel: LocalModelState] = [:]
    @Published private(set) var loadedModel: LocalSpeechModel?
    @Published private(set) var loadingModel: LocalSpeechModel?
    private var idleUnloadTask: Task<Void, Never>?
    private var operationGeneration: UInt64 = 0

    private init() {
        refresh()
    }

    func state(for model: LocalSpeechModel) -> LocalModelState {
        states[model] ?? .notInstalled
    }

    func download(_ model: LocalSpeechModel) {
        operationGeneration &+= 1
        let generation = operationGeneration
        states[model] = .downloading(0, L10n.t("local.preparing"))
        Task { [self] in
            do {
                try await LocalModelRuntime.shared.prepare(model)
                guard operationGeneration == generation else { return }
                try Data().write(to: LocalModelStorage.markerURL(for: model), options: .atomic)
                guard operationGeneration == generation else { return }
                await LocalModelRuntime.shared.unloadAll()
                guard operationGeneration == generation else { return }
                loadedModel = nil
                loadingModel = nil
                states[model] = .installed
            } catch {
                guard operationGeneration == generation else { return }
                states[model] = .failed(error.localizedDescription)
            }
        }
    }

    func remove(_ model: LocalSpeechModel) {
        operationGeneration &+= 1
        let generation = operationGeneration
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        guard let directory = try? LocalModelStorage.cacheDirectory(for: model) else { return }
        Task {
            await LocalModelRuntime.shared.unload(model)
            guard operationGeneration == generation else { return }
            if loadedModel == model { loadedModel = nil }
            if loadingModel == model { loadingModel = nil }
            do {
                if FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.removeItem(at: directory)
                }
                if operationGeneration == generation { states[model] = .notInstalled }
            } catch {
                if operationGeneration == generation { states[model] = .failed(error.localizedDescription) }
            }
        }
    }

    func isInstalled(_ model: LocalSpeechModel) -> Bool {
        if case .installed = state(for: model) { return true }
        return false
    }

    func select(_ model: LocalSpeechModel) {
        guard loadedModel != model else { return }
        unload()
    }

    func unload() {
        operationGeneration &+= 1
        let generation = operationGeneration
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        loadedModel = nil
        loadingModel = nil
        Task { [weak self] in
            await LocalModelRuntime.shared.unloadAll()
            guard let self, self.operationGeneration == generation else { return }
            self.loadedModel = nil
            self.loadingModel = nil
        }
    }

    func markLoading(_ model: LocalSpeechModel) -> UInt64 {
        operationGeneration &+= 1
        let generation = operationGeneration
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        loadingModel = model
        return generation
    }

    func markLoaded(_ model: LocalSpeechModel, generation: UInt64) {
        guard operationGeneration == generation else { return }
        loadingModel = nil
        loadedModel = model
    }

    func scheduleIdleUnload(_ model: LocalSpeechModel, generation: UInt64) {
        guard operationGeneration == generation else { return }
        idleUnloadTask?.cancel()
        idleUnloadTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(300))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.operationGeneration == generation,
                  self.loadedModel == model else { return }
            await LocalModelRuntime.shared.unload(model)
            guard self.operationGeneration == generation,
                  self.loadedModel == model else { return }
            self.loadedModel = nil
            self.idleUnloadTask = nil
            DiagnosticsLogger.shared.log("local: unloaded idle model \(model.rawValue)")
        }
    }

    func markLoadFailed(_ model: LocalSpeechModel, generation: UInt64) {
        guard operationGeneration == generation else { return }
        if loadingModel == model { loadingModel = nil }
    }

    private func refresh() {
        states = Dictionary(uniqueKeysWithValues: LocalSpeechModel.allCases.map { model in
            (model, LocalModelStorage.isInstalled(model) ? .installed : .notInstalled)
        })
    }
}

actor LocalModelRuntime {
    static let shared = LocalModelRuntime()

    private static let responsePrefix = "DICTABAR_LOCAL_IPC:"

    private struct Command: Codable {
        let id: String
        let operation: String
        let model: String?
        let audioPath: String?
        let language: String?
    }

    private struct Response: Codable {
        let id: String
        let ok: Bool
        let text: String?
        let error: String?
    }

    private final class WorkerConnection {
        let id: UUID
        let process: Process
        let input: Pipe
        let output: Pipe

        init(id: UUID, process: Process, input: Pipe, output: Pipe) {
            self.id = id
            self.process = process
            self.input = input
            self.output = output
        }
    }

    private var worker: WorkerConnection?
    private var outputBuffer = Data()
    private var pending: (id: String, continuation: CheckedContinuation<Response, Error>)?
    private var activeModel: LocalSpeechModel?
    private var cachedModel: LocalSpeechModel?
    private var requestInProgress = false
    private var requestQueue: [(id: String, continuation: CheckedContinuation<Void, Error>)] = []
    private let workerExecutableURL: URL?
    private let workerArguments: [String]

    init(
        workerExecutableURL: URL? = Bundle.main.executableURL,
        workerArguments: [String] = ["--local-inference-worker"]
    ) {
        self.workerExecutableURL = workerExecutableURL
        self.workerArguments = workerArguments
    }

    static func stopWorkerProcessOnExit() {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await shared.stopWorkerProcess()
            semaphore.signal()
        }
        semaphore.wait()
    }

    func prepare(_ model: LocalSpeechModel) async throws {
        do {
            let response = try await send(
                operation: "prepare",
                model: model,
                audioURL: nil,
                language: nil
            )
            try requireSuccess(response)
            cachedModel = model
        } catch {
            terminateWorker(with: error)
            throw error
        }
    }

    func unload(_ model: LocalSpeechModel) async {
        if activeModel == model || cachedModel == model {
            terminateWorker(with: CancellationError())
        }
    }

    func unloadAll() {
        terminateWorker(with: CancellationError())
    }

    func transcribe(audioURL: URL, model: LocalSpeechModel, language: OutputLanguage) async throws -> String {
        let response = try await send(
            operation: "transcribe",
            model: model,
            audioURL: audioURL,
            language: language.rawValue
        )
        try requireSuccess(response)
        cachedModel = model
        return response.text ?? ""
    }

    private func send(
        operation: String,
        model: LocalSpeechModel,
        audioURL: URL?,
        language: String?
    ) async throws -> Response {
        let id = UUID().uuidString
        try await acquireRequestSlot(id: id)
        defer { releaseRequestSlot() }
        try Task.checkCancellation()
        activeModel = model
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Response, Error>) in
                do {
                    let connection = try ensureWorker()
                    pending = (id, continuation)
                    let command = Command(
                        id: id,
                        operation: operation,
                        model: model.rawValue,
                        audioPath: audioURL?.path,
                        language: language
                    )
                    var data = try JSONEncoder().encode(command)
                    guard data.count <= 64 * 1_024 else {
                        throw ProviderError.unsupported("The local inference request was too large.")
                    }
                    data.append(0x0A)
                    try connection.input.fileHandleForWriting.write(contentsOf: data)
                } catch {
                    pending = nil
                    activeModel = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id: id) }
        }
    }

    private func acquireRequestSlot(id: String) async throws {
        if !requestInProgress {
            requestInProgress = true
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    requestQueue.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelQueuedRequest(id: id) }
        }
    }

    private func cancelQueuedRequest(id: String) {
        guard let index = requestQueue.firstIndex(where: { $0.id == id }) else { return }
        requestQueue.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func releaseRequestSlot() {
        activeModel = nil
        if requestQueue.isEmpty {
            requestInProgress = false
        } else {
            requestQueue.removeFirst().continuation.resume()
        }
    }

    private func ensureWorker() throws -> WorkerConnection {
        if let worker, worker.process.isRunning { return worker }
        let process = Process()
        guard let executableURL = workerExecutableURL else {
            throw ProviderError.unsupported("The local inference worker could not be started.")
        }
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = workerArguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let id = UUID()
        let connection = WorkerConnection(id: id, process: process, input: input, output: output)
        let (stream, streamContinuation) = AsyncStream<Data>.makeStream()
        outputBuffer.removeAll(keepingCapacity: true)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                streamContinuation.finish()
                return
            }
            streamContinuation.yield(data)
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        worker = connection
        Task { [weak self] in
            for await data in stream {
                await self?.receive(data, from: id)
            }
            await self?.workerDidExit(id: id)
        }
        return connection
    }

    private func receive(_ data: Data, from workerID: UUID) {
        guard worker?.id == workerID else { return }
        guard data.count <= 4 * 1_024 * 1_024 - outputBuffer.count else {
            terminateWorker(with: ProviderError.unsupported("The local inference worker returned invalid output."))
            return
        }
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let lineData = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard let line = String(data: lineData, encoding: .utf8),
                  line.hasPrefix(Self.responsePrefix),
                  let responseData = Data(base64Encoded: String(line.dropFirst(Self.responsePrefix.count))),
                  let response = try? JSONDecoder().decode(Response.self, from: responseData),
                  let pending, pending.id == response.id else { continue }
            self.pending = nil
            pending.continuation.resume(returning: response)
        }
        if outputBuffer.count > 4 * 1_024 * 1_024 {
            terminateWorker(with: ProviderError.unsupported("The local inference worker returned invalid output."))
        }
    }

    private func cancelRequest(id: String) {
        guard pending?.id == id else { return }
        terminateWorker(with: CancellationError())
    }

    private func workerDidExit(id: UUID) {
        guard worker?.id == id else { return }
        terminateWorker(with: ProviderError.unsupported("The local inference worker stopped unexpectedly."))
    }

    private func stopWorkerProcess() {
        terminateWorker(with: CancellationError())
    }

    private func terminateWorker(with error: Error) {
        guard let connection = worker else { return }
        worker = nil
        cachedModel = nil
        outputBuffer.removeAll(keepingCapacity: true)
        connection.output.fileHandleForReading.readabilityHandler = nil
        connection.input.fileHandleForWriting.closeFile()
        connection.output.fileHandleForReading.closeFile()
        if connection.process.isRunning {
            connection.process.terminate()
            let process = connection.process
            let processID = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(250)) {
                if process.isRunning {
                    _ = kill(processID, SIGKILL)
                }
            }
        }
        if let pending {
            self.pending = nil
            pending.continuation.resume(throwing: error)
        }
    }

    private func requireSuccess(_ response: Response) throws {
        guard response.ok else {
            throw ProviderError.unsupported(response.error ?? "Local inference failed.")
        }
    }
}

private actor LocalModelEngine {
    private enum Loaded {
        case parakeet(ParakeetASRModel)
        case nemotron(NemotronStreamingASRModel)
        case qwen(Qwen3ASRModel)
        case moss(MossMLXModel)
    }

    private var loaded: (model: LocalSpeechModel, runtime: Loaded)?
    private var loadingModel: LocalSpeechModel?
    private var generation: UInt64 = 0

    func prepare(_ model: LocalSpeechModel) async throws {
        if loaded?.model == model { return }
        generation &+= 1
        let loadGeneration = generation
        loadingModel = model
        releaseLoaded()

        do {
            let runtime: Loaded
            switch model {
            case .parakeet:
                runtime = .parakeet(try await ParakeetASRModel.fromPretrained())
            case .nemotron:
                runtime = .nemotron(try await NemotronStreamingASRModel.fromPretrained())
            case .qwen:
                runtime = .qwen(try await Qwen3ASRModel.fromPretrained())
            case .moss:
                runtime = .moss(try await MossMLXModel.fromPretrained(variant: .int5))
            }

            try Task.checkCancellation()
            guard generation == loadGeneration, loadingModel == model else {
                throw CancellationError()
            }
            loaded = (model, runtime)
            loadingModel = nil
        } catch {
            if generation == loadGeneration {
                loadingModel = nil
            }
            throw error
        }
    }

    func unload(_ model: LocalSpeechModel) {
        if loadingModel == model {
            generation &+= 1
            loadingModel = nil
        }
        if loaded?.model == model { releaseLoaded() }
    }

    func unloadAll() {
        generation &+= 1
        loadingModel = nil
        releaseLoaded()
    }

    func transcribe(audioURL: URL, model: LocalSpeechModel, language: OutputLanguage) async throws -> String {
        try await prepare(model)
        guard let loaded, loaded.model == model else {
            throw ProviderError.unsupported("The local model could not be loaded.")
        }
        try Task.checkCancellation()
        let audio = try AudioFileLoader.load(url: audioURL, targetSampleRate: 16_000)
        try Task.checkCancellation()
        let text: String
        switch loaded.runtime {
        case let .parakeet(runtime):
            text = try runtime.transcribeAudio(audio, sampleRate: 16_000, language: language.apiCode)
        case let .nemotron(runtime):
            text = try runtime.transcribeAudio(
                audio,
                sampleRate: 16_000,
                language: language == .auto ? nil : language.bcp47
            )
        case let .qwen(runtime):
            text = runtime.transcribe(
                audio: audio,
                sampleRate: 16_000,
                language: language == .auto ? nil : language.rawValue
            )
        case let .moss(runtime):
            text = try runtime.transcribeDetailed(audio: audio, sampleRate: 16_000).text
        }
        try Task.checkCancellation()
        Memory.clearCache()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func releaseLoaded() {
        if let loaded {
            switch loaded.runtime {
            case let .parakeet(runtime): runtime.unload()
            case let .nemotron(runtime): runtime.unload()
            case let .qwen(runtime): runtime.unload()
            case .moss: break
            }
        }
        loaded = nil
        Memory.clearCache()
    }
}

private struct LocalWorkerCommand: Decodable, Sendable {
    let id: String
    let operation: String
    let model: String?
    let audioPath: String?
    let language: String?
}

private struct LocalWorkerResponse: Encodable {
    let id: String
    let ok: Bool
    let text: String?
    let error: String?
}

private final class LocalWorkerResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: LocalWorkerResponse?

    func set(_ response: LocalWorkerResponse) {
        lock.lock()
        value = response
        lock.unlock()
    }

    func get() -> LocalWorkerResponse? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class LocalWorkerSmokeTestResult: @unchecked Sendable {
    private let lock = NSLock()
    private var message: String?

    func setFailure(_ message: String) {
        lock.lock()
        self.message = message
        lock.unlock()
    }

    func failure() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return message
    }
}

enum LocalInferenceWorker {
    static func runIfRequested() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--local-inference-bridge-smoke-test") {
            runBridgeSmokeTest()
            return true
        }
        if arguments.contains("--local-inference-worker-test") {
            runFakeWorker()
            return true
        }
        guard arguments.contains("--local-inference-worker") else { return false }
        let engine = LocalModelEngine()
        while let line = readLine() {
            guard line.utf8.count <= 64 * 1_024 else { return true }
            guard let data = line.data(using: .utf8),
                  let command = try? JSONDecoder().decode(LocalWorkerCommand.self, from: data),
                  let rawModel = command.model,
                  let model = LocalSpeechModel(rawValue: rawModel) else { continue }
            let semaphore = DispatchSemaphore(value: 0)
            let responseBox = LocalWorkerResponseBox()
            Task.detached(priority: .userInitiated) {
                do {
                    let text: String?
                    switch command.operation {
                    case "prepare":
                        try await engine.prepare(model)
                        text = nil
                    case "unload":
                        await engine.unload(model)
                        text = nil
                    case "transcribe":
                        guard let audioPath = command.audioPath,
                              let language = command.language,
                              let outputLanguage = OutputLanguage(rawValue: language) else {
                            throw ProviderError.unsupported("The local inference request was invalid.")
                        }
                        let audioURL = URL(fileURLWithPath: audioPath)
                        guard audioURL.isFileURL,
                              FileManager.default.isReadableFile(atPath: audioURL.path) else {
                            throw ProviderError.unsupported("The local audio file could not be read.")
                        }
                        text = try await engine.transcribe(
                            audioURL: audioURL,
                            model: model,
                            language: outputLanguage
                        )
                    default:
                        throw ProviderError.unsupported("The local inference request was invalid.")
                    }
                    responseBox.set(LocalWorkerResponse(id: command.id, ok: true, text: text, error: nil))
                } catch {
                    responseBox.set(LocalWorkerResponse(
                        id: command.id,
                        ok: false,
                        text: nil,
                        error: error.localizedDescription
                    ))
                }
                semaphore.signal()
            }
            semaphore.wait()
            guard let response = responseBox.get(),
                  let responseData = try? JSONEncoder().encode(response) else { continue }
            let output = "DICTABAR_LOCAL_IPC:\(responseData.base64EncodedString())"
            print(output)
            fflush(stdout)
        }
        return true
    }

    private static func runFakeWorker() {
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let command = try? JSONDecoder().decode(LocalWorkerCommand.self, from: data),
                  let rawModel = command.model,
                  LocalSpeechModel(rawValue: rawModel) != nil else { continue }
            if command.operation == "prepare", rawModel == LocalSpeechModel.qwen.rawValue {
                Darwin.exit(EXIT_SUCCESS)
            }
            if (command.operation == "prepare" && rawModel == LocalSpeechModel.moss.rawValue)
                || (command.operation == "transcribe" && command.audioPath == "/tmp/local-worker-cancel") {
                while true { Thread.sleep(forTimeInterval: 1) }
            }
            let text = command.operation == "transcribe" ? String(getpid()) : nil
            guard let response = try? JSONEncoder().encode(LocalWorkerResponse(
                id: command.id,
                ok: true,
                text: text,
                error: nil
            )) else { continue }
            print("DICTABAR_LOCAL_IPC:\(response.base64EncodedString())")
            fflush(stdout)
        }
    }

    private static func runBridgeSmokeTest() {
        let semaphore = DispatchSemaphore(value: 0)
        let result = LocalWorkerSmokeTestResult()
        Task.detached {
            do {
                try await verifyBridgeLifecycle()
            } catch {
                result.setFailure(error.localizedDescription)
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let failure = result.failure() {
            fputs("local-inference-bridge-check: failed: \(failure)\n", stderr)
            fflush(stderr)
            Darwin.exit(EXIT_FAILURE)
        }
        print("local-inference-bridge-check: ok")
        fflush(stdout)
    }

    private static func verifyBridgeLifecycle() async throws {
        guard let executableURL = Bundle.main.executableURL else {
            throw ProviderError.unsupported("Test executable was unavailable.")
        }
        let runtime = LocalModelRuntime(
            workerExecutableURL: executableURL,
            workerArguments: ["--local-inference-worker-test"]
        )
        try await runtime.prepare(.parakeet)
        let fakeAudio = URL(fileURLWithPath: "/tmp/local-worker-reuse")
        let firstPID = try await runtime.transcribe(audioURL: fakeAudio, model: .parakeet, language: .auto)
        let secondPID = try await runtime.transcribe(audioURL: fakeAudio, model: .parakeet, language: .auto)
        guard firstPID == secondPID else {
            throw ProviderError.unsupported("Repeated requests did not reuse the worker.")
        }

        let cancelled = Task {
            try await runtime.transcribe(
                audioURL: URL(fileURLWithPath: "/tmp/local-worker-cancel"),
                model: .parakeet,
                language: .auto
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        cancelled.cancel()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    _ = try await cancelled.value
                    throw ProviderError.unsupported("Cancelled inference unexpectedly succeeded.")
                } catch is CancellationError {
                    return
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(3))
                throw ProviderError.unsupported("Cancelled inference did not stop promptly.")
            }
            try await group.next()
            group.cancelAll()
        }

        let loading = Task { try await runtime.prepare(.moss) }
        try await Task.sleep(for: .milliseconds(100))
        await runtime.unload(.moss)
        do {
            try await loading.value
            throw ProviderError.unsupported("Unloading during preparation unexpectedly succeeded.")
        } catch is CancellationError {
            // The bridge resumes the pending prepare when unload terminates its worker.
        }

        var exitDetected = false
        do {
            try await runtime.prepare(.qwen)
        } catch is CancellationError {
            throw ProviderError.unsupported("An unexpected worker exit was reported as cancellation.")
        } catch {
            exitDetected = true
            // EOF must fail the pending request instead of leaving it suspended.
        }
        guard exitDetected else { throw ProviderError.unsupported("An unexpected worker exit was not detected.") }
        await runtime.unloadAll()

        let missingWorker = LocalModelRuntime(
            workerExecutableURL: URL(fileURLWithPath: "/does/not/exist/dictabar-worker"),
            workerArguments: []
        )
        var launchFailureDetected = false
        do {
            try await missingWorker.prepare(.parakeet)
        } catch is CancellationError {
            throw ProviderError.unsupported("A missing worker executable was reported as cancellation.")
        } catch {
            launchFailureDetected = true
            // Launch failure must resume the pending request with an error.
        }
        guard launchFailureDetected else { throw ProviderError.unsupported("A missing worker executable unexpectedly launched.") }
    }
}

struct LocalTranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        let model = LocalSpeechModel.named(settings.model)
        guard LocalModelStorage.isInstalled(model) else {
            throw ProviderError.unsupported("Download \(model.rawValue) in Settings → Local Models first.")
        }
        let loadGeneration = await LocalModelManager.shared.markLoading(model)
        let text: String
        do {
            text = try await LocalModelRuntime.shared.transcribe(
                audioURL: audioURL,
                model: model,
                language: settings.language
            )
        } catch {
            await LocalModelManager.shared.markLoadFailed(model, generation: loadGeneration)
            await LocalModelManager.shared.scheduleIdleUnload(model, generation: loadGeneration)
            throw error
        }
        await LocalModelManager.shared.markLoaded(model, generation: loadGeneration)
        await LocalModelManager.shared.scheduleIdleUnload(model, generation: loadGeneration)
        guard !text.isEmpty else { throw ProviderError.noTranscript }
        return TranscriptionResult(
            text: text,
            detectedLanguage: settings.language.apiCode,
            duration: nil,
            providerName: SpeechProvider.local.rawValue,
            modelName: model.rawValue
        )
    }
}
