import Foundation
import Combine
import AVFoundation
import IrodoriTTS

@MainActor
final class LocalSpeechEngine: ObservableObject {
    @Published private(set) var modelStatus = "モデル未確認"
    @Published private(set) var isReady = false
    @Published private(set) var isGenerating = false
    @Published private(set) var lastRTF: Double?
    @Published private(set) var downloadError: String?

    let modelManager = LocalModelManager()
    private let engine = IrodoriEngine()
    private let fileManager = FileManager.default
    private var preparedModelPath: String?

    func installModelAtLaunch() async {
        do {
            try await modelManager.installIfNeeded()
            modelStatus = modelManager.status
        } catch {
            modelStatus = modelManager.status
            downloadError = error.localizedDescription
        }
    }

    func refreshStatus() { modelStatus = modelManager.status }

    func synthesize(_ text: String, referenceURL: URL?, caption: String = "") async throws -> (URL, SynthesisResult) {
        if let modelURL = modelManager.modelDirectory {
            return try await synthesizeWithModel(text, modelURL: modelURL, referenceURL: referenceURL, caption: caption)
        }
        try await modelManager.installIfNeeded()
        guard let modelURL = modelManager.modelDirectory else {
            throw NSError(domain: "PopView.TTS", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "音声モデルがインストールされていません。"])
        }
        return try await synthesizeWithModel(text, modelURL: modelURL, referenceURL: referenceURL, caption: caption)
    }

    private func synthesizeWithModel(_ text: String, modelURL: URL, referenceURL: URL?, caption: String) async throws -> (URL, SynthesisResult) {
        isGenerating = true
        defer { isGenerating = false }
        if preparedModelPath != modelURL.path {
            modelStatus = "Core MLモデルを初期化しています（初回は時間がかかります）"
            _ = try await engine.prepare(modelDirectory: modelURL)
            preparedModelPath = modelURL.path
        }
        _ = try await engine.registerReference(referenceURL)
        let result = try await engine.synthesize(text, caption: caption)
        let outputFolder = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PopView/GeneratedAudio", isDirectory: true)
        try fileManager.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        let outputURL = outputFolder.appendingPathComponent("\(UUID().uuidString).wav")
        try result.writeWAV(to: outputURL)
        lastRTF = result.rtf
        isReady = true
        modelStatus = "音声生成完了"
        return (outputURL, result)
    }

    func release() async {
        await engine.release()
        preparedModelPath = nil
        isReady = false
    }
}
