import Foundation
import Combine
import IrodoriTTS

@MainActor
final class LocalModelManager: ObservableObject {
    @Published private(set) var status = "モデル未確認"
    @Published private(set) var completedFiles = 0
    @Published private(set) var totalFiles = 0
    @Published private(set) var isInstalled = false
    @Published private(set) var modelDirectory: URL?

    private let fileManager = FileManager.default

    private var modelsRoot: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PopView/Models", isDirectory: true)
    }

    var progress: Double {
        guard totalFiles > 0 else { return 0 }
        return Double(completedFiles) / Double(totalFiles)
    }

    var selectedVariant: ModelVariant {
        if #available(iOS 18, *), ModelVariant.lightINT8.isSupported { return .lightINT8 }
        return .standard
    }

    func installIfNeeded() async {
        do {
            try fileManager.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
            let variant = selectedVariant
            let destination = modelsRoot.appendingPathComponent("Irodori-\(variant.rawValue)", isDirectory: true)
            if fileManager.fileExists(atPath: destination.path) {
                try ModelBundle.validate(at: destination)
                modelDirectory = destination
                isInstalled = true
                status = "モデル準備済み（\(variant.title)）"
                return
            }

            status = "\(variant.title)をダウンロードしています（約\(String(format: "%.2f", Double(variant.approximateBytes) / 1_000_000_000)) GB）"
            completedFiles = 0
            totalFiles = 0
            try await ModelDownloader().download(manifestURL: variant.manifestURL, to: destination) { [weak self] done, total, file in
                Task { @MainActor in
                    self?.completedFiles = done
                    self?.totalFiles = total
                    self?.status = "モデル取得 \(done)/\(total)：\(file)"
                }
            }
            try Task.checkCancellation()
            modelDirectory = destination
            isInstalled = true
            status = "モデルの取得・SHA-256検証が完了しました"
        } catch is CancellationError {
            status = "モデル取得をキャンセルしました"
            throw CancellationError()
        } catch {
            isInstalled = false
            status = "モデル取得エラー：\(error.localizedDescription)"
            throw error
        }
    }
}
