import Foundation
import Vision
import UIKit

struct MangaAnalyzer {
    struct ResultRegion {
        var text: String
        var box: CGRect
        var confidence: Float
    }

    /// Runs separate, accurate Japanese and English passes. Keeping the language
    /// passes separate avoids an English-prioritized model degrading Japanese text.
    func recognizeText(in image: UIImage) async throws -> [ResultRegion] {
        guard let cgImage = image.cgImage else { throw AnalysisError.invalidImage }
        return try await Task.detached(priority: .userInitiated) {
            let japanese = try Self.recognize(cgImage, languages: ["ja-JP"])
            let english = try Self.recognize(cgImage, languages: ["en-US"])
            return Self.mergeAndSort(japanese + english)
        }.value
    }

    private static func recognize(_ image: CGImage, languages: [String]) throws -> [ResultRegion] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = false
        request.recognitionLanguages = languages
        request.minimumTextHeight = 0.004
        request.customWords = ["えっ", "うそ", "まさか", "ありがとう", "ごめん", "大丈夫", "どうして", "なぜ"]

        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let observations = request.results ?? []
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(3).first else { return nil }
            let value = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            return ResultRegion(text: value, box: observation.boundingBox, confidence: candidate.confidence)
        }
    }

    private static func mergeAndSort(_ regions: [ResultRegion]) -> [ResultRegion] {
        var merged: [ResultRegion] = []
        for candidate in regions.sorted(by: { $0.confidence > $1.confidence }) {
            let duplicate = merged.contains { existing in
                let intersection = existing.box.intersection(candidate.box)
                guard !intersection.isNull else { return false }
                let unionArea = existing.box.union(candidate.box).width * existing.box.union(candidate.box).height
                let overlap = unionArea > 0 ? intersection.width * intersection.height / unionArea : 0
                return overlap > 0.55 || (existing.text == candidate.text &&
                    abs(existing.box.midX - candidate.box.midX) < 0.015 &&
                    abs(existing.box.midY - candidate.box.midY) < 0.015)
            }
            if !duplicate { merged.append(candidate) }
        }

        // Japanese manga is generally read from the rightmost column toward the left.
        // Keep nearby lines stable top-to-bottom within each approximate column.
        return merged.sorted {
            if abs($0.box.midX - $1.box.midX) > 0.06 {
                return $0.box.midX > $1.box.midX
            }
            return $0.box.midY > $1.box.midY
        }
    }

    /// Finds likely speech-balloon rectangles. These are geometry hints only;
    /// OCR remains the source of the recognized text.
    func detectBalloonCandidates(in image: UIImage) async throws -> [CGRect] {
        guard let cgImage = image.cgImage else { throw AnalysisError.invalidImage }
        return try await Task.detached(priority: .userInitiated) {
            let request = VNDetectRectanglesRequest()
            request.minimumConfidence = 0.2
            request.minimumAspectRatio = 0.12
            request.maximumObservations = 120
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            return (request.results ?? [])
                .filter { $0.boundingBox.width > 0.035 && $0.boundingBox.height > 0.025 }
                .map(\.boundingBox)
        }.value
    }

    enum AnalysisError: Error { case invalidImage }
}
