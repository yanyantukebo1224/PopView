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

        var regions = recognized.enumerated().map { index, item in
            var region = SpeechRegion(
                text: item.text,
                box: CGRectCodable(item.box),
                confidence: item.confidence
            )
            region.readingOrder = index
            return region
        }

        var newCharacters: [CharacterVoice] = []
        var speakerIDs: [String: UUID] = [:]
        var notice = "Apple Visionの高精度OCRで文字を検出しました。"

        do {
            let semantic = try await FoundationModelsMangaAnalyzer().analyze(
                image: image,
                recognizedTexts: recognized.map(\.text),
                recognizedBoxes: recognized.map(\.box),
                knownCharacters: knownCharacters
            )
            for speaker in semantic.speakers {
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
                regions[index].speakerID = annotation.speakerKey.flatMap { speakerIDs[$0] }
                regions[index].speakerLabel = annotation.speakerKey
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
