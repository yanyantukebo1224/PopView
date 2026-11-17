import Foundation
import UIKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Uses the on-device Apple Foundation Model to read a manga page directly from pixels.
/// Coordinates returned by a language model are estimates, so the editor must allow review.
struct FoundationModelsMangaAnalyzer {
    struct Speaker: Decodable {
        let key: String
        let name: String
        let appearance: String?
    }

    struct Dialogue: Decodable {
        struct Box: Decodable {
            let x: Double
            let y: Double
            let width: Double
            let height: Double
        }

        let text: String
        let speakerKey: String?
        let box: Box
        let readingOrder: Int
        let emotion: String?
        let actingDirection: String?
    }

    private struct Response: Decodable {
        let speakers: [Speaker]
        let dialogues: [Dialogue]
    }

    enum AnalysisError: LocalizedError {
        case unavailable(String)
        case invalidImage
        case emptyResult
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): return "Apple Foundation Modelsを利用できません: \(reason)"
            case .invalidImage: return "画像を読み込めませんでした。"
            case .emptyResult: return "漫画ページからセリフを検出できませんでした。"
            case .invalidResponse: return "AIの解析結果を読み取れませんでした。"
            }
        }
    }

    func analyze(image: UIImage) async throws -> (speakers: [Speaker], dialogues: [Dialogue]) {
        guard let cgImage = image.cgImage else { throw AnalysisError.invalidImage }
        #if canImport(FoundationModels)
        guard #available(iOS 27.0, *) else {
            throw AnalysisError.unavailable("画像入力にはiOS 27以降が必要です。")
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw AnalysisError.unavailable(String(describing: reason))
        }

        let session = LanguageModelSession()
        let response = try await session.respond {
            """
            あなたは漫画ページを解析する専門家です。添付されたページ画像だけを見て、読めるセリフを抽出してください。
            OCRテキストは別途与えられていません。画像内の日本語・英語をできるだけ原文どおりに読み取ってください。
            吹き出し、話者、コマの配置、視線、会話の流れを手掛かりに読み順と話者を推定してください。
            同じ人物には同じspeaker key（speaker_1, speaker_2...）を割り当て、外見の特徴をappearanceに短く記述してください。
            話者が特定できない場合はspeakerKeyをnullにしてください。ナレーションや効果音は通常の会話と区別してください。
            各セリフのboxは画像全体に対する正規化座標です。xとyは左上原点、widthとheightは幅と高さで、すべて0.0から1.0の範囲です。
            boxは吹き出し全体のおおよその範囲を指定してください。座標は推定値でよく、ページ外にはみ出さないようにしてください。
            readingOrderは最初に読むセリフを0とする整数です。
            emotionには感情を短く、actingDirectionには声の演技指示を日本語で記述してください。
            読めない文字を創作しないでください。確信がない場合は読めた範囲だけを記述してください。
            出力は説明文やMarkdownを付けず、次のJSON形式だけにしてください:
            {"speakers":[{"key":"speaker_1","name":"人物1","appearance":"黒髪で眼鏡"}],
             "dialogues":[{"text":"セリフ","speakerKey":"speaker_1","box":{"x":0.1,"y":0.2,"width":0.3,"height":0.1},"readingOrder":0,"emotion":"驚き","actingDirection":"少し高めの声で驚いて"}]}
            """
            Attachment(cgImage)
        }
        let content = response.content
        guard let first = content.firstIndex(of: "{"),
              let last = content.lastIndex(of: "}"), first <= last else {
            throw AnalysisError.invalidResponse
        }
        let json = String(content[first...last])
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw AnalysisError.invalidResponse
        }
        guard !decoded.dialogues.isEmpty else { throw AnalysisError.emptyResult }
        return (decoded.speakers, decoded.dialogues)
        #else
        throw AnalysisError.unavailable("このSDKではFoundationModelsを利用できません。Xcode 27以降でビルドしてください。")
        #endif
    }
}
