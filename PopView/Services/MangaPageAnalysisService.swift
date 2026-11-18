import Foundation
import UIKit

struct MangaPageAnalysisService {
    struct Result {
        let regions: [SpeechRegion]
        let newCharacters: [CharacterVoice]
        let notice: String
    }

    func analyze(image: UIImage, knownCharacters: [CharacterVoice]) async throws -> Result {
        let analyzer = MangaAnalyzer()
        let recognized = try await analyzer.recognizeText(in: image)
        guard !recognized.isEmpty else {
            throw MangaAnalyzer.AnalysisError.invalidImage
        }

        let bubbles = MangaBubbleGrouper.group(recognized)
        var regions = bubbles.map { bubble in
            var region = SpeechRegion(
                text: bubble.text,
                box: CGRectCodable(bubble.box),
                confidence: bubble.confidence
            )
            region.readingOrder = bubble.readingOrder
            return region
        }

        var newCharacters: [CharacterVoice] = []
        var speakerIDs: [String: UUID] = [:]
        var notice = "Vision OCRの文字領域を吹き出し候補ごとにまとめました。話者は確信度が低い場合、自動割り当てしません。"

        do {
            let semantic = try await FoundationModelsMangaAnalyzer().analyze(
                image: image,
                recognizedTexts: bubbles.map(\.text),
                recognizedBoxes: bubbles.map(\.box),
                knownCharacters: knownCharacters
            )
            let confidentSpeakerKeys = Set(semantic.annotations.compactMap { annotation -> String? in
                guard (annotation.confidence ?? 0) >= 0.72 else { return nil }
                return annotation.speakerKey
            })
            for speaker in semantic.speakers where confidentSpeakerKeys.contains(speaker.key) {
                if let existing = knownCharacters.first(where: {
                    $0.name.localizedCaseInsensitiveCompare(speaker.name) == .orderedSame
                }) {
                    speakerIDs[speaker.key] = existing.id
                } else if let existing = newCharacters.first(where: {
                    $0.name.localizedCaseInsensitiveCompare(speaker.name) == .orderedSame
                }) {
                    speakerIDs[speaker.key] = existing.id
                } else {
                    var character = CharacterVoice(name: speaker.name)
                    character.visualDescription = speaker.appearance
                    newCharacters.append(character)
                    speakerIDs[speaker.key] = character.id
                }
            }

            for annotation in semantic.annotations {
                guard regions.indices.contains(annotation.lineIndex) else { continue }
                let index = annotation.lineIndex
                let speakerIsConfident = (annotation.confidence ?? 0) >= 0.72
                let validatedKey = speakerIsConfident ? annotation.speakerKey : nil
                regions[index].speakerID = validatedKey.flatMap { speakerIDs[$0] }
                regions[index].speakerLabel = validatedKey
                regions[index].emotion = annotation.emotion
                regions[index].actingDirection = annotation.actingDirection
            }
            notice += " Apple Intelligenceで話者・感情・声の演技も推定しました。"
        } catch {
            notice += " 話者・演技のAI判定は利用できなかったため、後から編集できます。"
        }

        return Result(regions: regions, newCharacters: newCharacters, notice: notice)
    }
}
