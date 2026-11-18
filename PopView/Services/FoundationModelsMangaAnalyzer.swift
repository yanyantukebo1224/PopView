import Foundation
import UIKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Uses Apple Intelligence for semantic interpretation only.
/// Exact dialogue text and geometry always come from Vision OCR.
struct FoundationModelsMangaAnalyzer {
    struct Speaker: Decodable {
        let key: String
        let name: String
        let appearance: String?
    }

    struct Annotation: Decodable {
        let lineIndex: Int
        let speakerKey: String?
        let emotion: String?
        let actingDirection: String?
        let confidence: Double?
    }

    private struct Response: Decodable {
        let speakers: [Speaker]
        let annotations: [Annotation]
    }

    enum AnalysisError: LocalizedError {
        case unavailable(String)
        case invalidImage
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): return "Apple Foundation Modelsを利用できません: \(reason)"
            case .invalidImage: return "画像を読み込めませんでした。"
            case .invalidResponse: return "話者・演技解析の結果を読み取れませんでした。"
            }
        }
    }

    func analyze(
        image: UIImage,
        recognizedTexts: [String],
        recognizedBoxes: [CGRect],
        knownCharacters: [CharacterVoice]
    ) async throws -> (speakers: [Speaker], annotations: [Annotation]) {
        guard let cgImage = image.cgImage else { throw AnalysisError.invalidImage }
        guard !recognizedTexts.isEmpty else { return ([], []) }

        #if canImport(FoundationModels)
        guard #available(iOS 27.0, *) else {
            throw AnalysisError.unavailable("この機能にはiOS 27以降が必要です。")
        }
        switch SystemLanguageModel.default.availability {
        case .available: break
        case .unavailable(let reason):
            throw AnalysisError.unavailable(String(describing: reason))
        }

        let known = knownCharacters.map {
            "名前: \($0.name) / 外見: \($0.visualDescription ?? "未登録") / 声の特徴: \($0.voiceDescription)"
        }.joined(separator: "\n")
        let numberedLines = recognizedTexts.enumerated().map { index, text in
            let box = recognizedBoxes.indices.contains(index) ? recognizedBoxes[index] : .zero
            return String(
                format: "[%d] %@ | 吹き出し位置: x=%.3f y=%.3f 幅=%.3f 高さ=%.3f",
                index, text, box.minX, box.minY, box.width, box.height
            )
        }.joined(separator: "\n")

        let session = LanguageModelSession()
        let response = try await session.respond {
            """
            あなたは漫画の演出・配役アシスタントです。画像とOCR済みセリフ一覧を照合し、各セリフの話者と演技だけを判定してください。

            最重要ルール:
            - セリフ本文はOCR結果が正本です。本文を書き換えたり、新しいセリフを追加したりしないでください。
            - OCR一覧の番号をlineIndexとしてそのまま使い、各行に最大1つの注釈を返してください。
            - OCR一覧には画像内の正規化座標（左下原点）が含まれます。まず座標から吹き出しのおおよその位置を把握してください。
            - 吹き出しの位置と人物の口元・視線・表情、コマの連続性を組み合わせて話者を推定してください。
            - 吹き出しと人物の距離だけで決めず、同じコマ内で発話している人物か、視線が誰に向いているかも確認してください。
            - 既知キャラクターの外見説明と画像を照合し、同一人物だと視覚的に判断できる場合は既知キャラクター名を再利用してください。
            - 1つの人物に別名を付けて重複登録しないでください。
            - 既知キャラクター一覧に一致する人物がいれば、その名前をそのまま使ってください。確信がない場合はspeakerKeyをnullにしてください。
            - 新しい人物を特定できた場合だけspeakerを追加し、外見の特徴を短く書いてください。
            - emotionは短い感情ラベル、actingDirectionは声の高さ・速さ・強さ・間・息づかいなどの演技指示を日本語で具体的に書いてください。
            - ナレーション、効果音、環境音は人物の発話として無理に割り当てないでください。
            - 画像だけで確定できない場合は断定せずnullにしてください。
            - 各annotationにconfidenceを0.0〜1.0で必ず付けてください。人物の口元・視線・吹き出しのしっぽなど複数の根拠が一致しない場合は0.0〜0.69にしてください。0.72未満の話者はアプリ側で未割り当てになります。

            既知キャラクター:
            \(known.isEmpty ? "なし" : known)

            OCRセリフ一覧:
            \(numberedLines)

            次のJSONだけを返してください:
            {"speakers":[{"key":"speaker_1","name":"人物名","appearance":"外見"}],
             "annotations":[{"lineIndex":0,"speakerKey":"speaker_1","emotion":"驚き","actingDirection":"少し息を吸ってから、短く高めの声で驚く","confidence":0.85}]}
            """
            Attachment(cgImage)
        }

        let content = response.content
        guard let first = content.firstIndex(of: "{"),
              let last = content.lastIndex(of: "}"), first <= last,
              let data = String(content[first...last]).data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw AnalysisError.invalidResponse
        }
        let validAnnotations = decoded.annotations.filter {
            recognizedTexts.indices.contains($0.lineIndex)
        }
        return (decoded.speakers, validAnnotations)
        #else
        throw AnalysisError.unavailable("このSDKではFoundationModelsを利用できません。")
        #endif
    }
}
