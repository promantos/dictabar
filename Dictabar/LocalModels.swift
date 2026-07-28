import AudioCommon
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

    private init() {
        refresh()
    }

    func state(for model: LocalSpeechModel) -> LocalModelState {
        states[model] ?? .notInstalled
    }

    func download(_ model: LocalSpeechModel) {
        states[model] = .downloading(0, L10n.t("local.preparing"))
        Task { [self] in
            do {
                try await LocalModelRuntime.shared.prepare(model)
                try Data().write(to: LocalModelStorage.markerURL(for: model), options: .atomic)
                await LocalModelRuntime.shared.unloadAll()
                loadedModel = nil
                loadingModel = nil
                states[model] = .installed
            } catch {
                states[model] = .failed(error.localizedDescription)
            }
        }
    }

    func remove(_ model: LocalSpeechModel) {
        guard let directory = try? LocalModelStorage.cacheDirectory(for: model) else { return }
        Task {
            await LocalModelRuntime.shared.unload(model)
            if loadedModel == model { loadedModel = nil }
            if loadingModel == model { loadingModel = nil }
            do {
                if FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.removeItem(at: directory)
                }
                states[model] = .notInstalled
            } catch {
                states[model] = .failed(error.localizedDescription)
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
        loadedModel = nil
        loadingModel = nil
        Task { [weak self] in
            await LocalModelRuntime.shared.unloadAll()
            self?.loadedModel = nil
            self?.loadingModel = nil
        }
    }

    func markLoading(_ model: LocalSpeechModel) {
        loadingModel = model
    }

    func markLoaded(_ model: LocalSpeechModel) {
        loadingModel = nil
        loadedModel = model
    }

    func markLoadFailed(_ model: LocalSpeechModel) {
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

    private enum Loaded {
        case parakeet(ParakeetASRModel)
        case nemotron(NemotronStreamingASRModel)
        case qwen(Qwen3ASRModel)
        case moss(MossMLXModel)
    }

    private var loaded: (model: LocalSpeechModel, runtime: Loaded)?

    func prepare(_ model: LocalSpeechModel) async throws {
        if loaded?.model == model { return }
        releaseLoaded()

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
        loaded = (model, runtime)
    }

    func unload(_ model: LocalSpeechModel) {
        if loaded?.model == model { releaseLoaded() }
    }

    func unloadAll() {
        releaseLoaded()
    }

    func transcribe(audioURL: URL, model: LocalSpeechModel, language: OutputLanguage) async throws -> String {
        try await prepare(model)
        guard let loaded, loaded.model == model else {
            throw ProviderError.unsupported("The local model could not be loaded.")
        }
        let audio = try AudioFileLoader.load(url: audioURL, targetSampleRate: 16_000)
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
            text = runtime.transcribe(audio: audio, sampleRate: 16_000, language: language.apiCode)
        }
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

struct LocalTranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        let model = LocalSpeechModel.named(settings.model)
        guard LocalModelStorage.isInstalled(model) else {
            throw ProviderError.unsupported("Download \(model.rawValue) in Settings → Local Models first.")
        }
        await LocalModelManager.shared.markLoading(model)
        let text: String
        do {
            text = try await LocalModelRuntime.shared.transcribe(
                audioURL: audioURL,
                model: model,
                language: settings.language
            )
            await LocalModelManager.shared.markLoaded(model)
        } catch {
            await LocalModelManager.shared.markLoadFailed(model)
            throw error
        }
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
