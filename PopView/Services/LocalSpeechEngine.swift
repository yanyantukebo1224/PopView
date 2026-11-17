import Foundation
import CoreML
import AVFoundation

/// Integration boundary for the Irodori-TTS Core ML export.
/// The exact exported model graph and tokenizer/codec assets must be supplied before synthesis can run.
@MainActor
final class LocalSpeechEngine: ObservableObject {
    @Published private(set) var modelStatus = "Core MLモデル未配置"
    @Published private(set) var isReady = false
    private(set) var loadedModels: [MLModel] = []

    func loadBundledModels() async {
        let names = ["IrodoriTextEncoder", "IrodoriMeanFlow", "IrodoriCodecDecoder"]
        var loaded: [MLModel] = []
        for name in names {
            guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else {
                modelStatus = "モデル不足：\(name).mlmodelc が見つかりません"
                isReady = false
                return
            }
            do {
                let configuration = MLModelConfiguration()
                configuration.computeUnits = .all
                loaded.append(try MLModel(contentsOf: url, configuration: configuration))
            } catch {
                modelStatus = "モデル読み込み失敗：\(error.localizedDescription)"
                isReady = false
                return
            }
        }
        loadedModels = loaded
        isReady = true
        modelStatus = "Core MLモデル読み込み済み（推論アダプター接続待ち）"
    }

    func playAudioFile(at url: URL) throws -> AVAudioPlayer {
        try AVAudioPlayer(contentsOf: url)
    }
}
