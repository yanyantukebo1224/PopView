import Foundation
import Vision
import UIKit

struct MangaAnalyzer {
    struct ResultRegion {
        var text: String
        var box: CGRect
        var confidence: Float
    }

    /// Runs full-page OCR plus overlapping crops. Crops give Vision a larger
    /// effective text size, recovering dialogue that is too small on a full page.
    func recognizeText(in image: UIImage) async throws -> [ResultRegion] {
        guard let cgImage = image.cgImage else { throw AnalysisError.invalidImage }
        return try await Task.detached(priority: .userInitiated) {
            var results: [ResultRegion] = []
            results += try Self.recognize(cgImage, languages: ["ja-JP"])
            results += try Self.recognize(cgImage, languages: ["en-US"])

            // 2x2 tiles with overlap preserve bubbles that straddle tile edges.
            let width = cgImage.width
            let height = cgImage.height
            let columns = 2
            let rows = 2
            let overlap = 0.18
            let tileWidth = Double(width) / Double(columns)
            let tileHeight = Double(height) / Double(rows)
            let padX = tileWidth * overlap / 2
            let padY = tileHeight * overlap / 2

            for row in 0..<rows {
                for column in 0..<columns {
                    let minX = max(0, Int(Double(column) * tileWidth - padX))
                    let maxX = min(width, Int(Double(column + 1) * tileWidth + padX))
                    let minY = max(0, Int(Double(row) * tileHeight - padY))
                    let maxY = min(height, Int(Double(row + 1) * tileHeight + padY))
                    let cropRect = CGRect(x: minX, y: minY,
                                          width: maxX - minX, height: maxY - minY)
                    guard let crop = cgImage.cropping(to: cropRect) else { continue }

                    let tileResults = try Self.recognize(crop, languages: ["ja-JP"])
                        + Self.recognize(crop, languages: ["en-US"])
                    let xOffset = Double(minX) / Double(width)
                    let yBottomOffset = Double(height - maxY) / Double(height)
                    let xScale = Double(crop.width) / Double(width)
                    let yScale = Double(crop.height) / Double(height)

                    results += tileResults.map { item in
                        var mapped = item
                        mapped.box = CGRect(
                            x: xOffset + item.box.minX * xScale,
                            y: yBottomOffset + item.box.minY * yScale,
                            width: item.box.width * xScale,
                            height: item.box.height * yScale
                        )
                        return mapped
                    }
                }
            }
            return Self.mergeAndSort(results)
        }.value
    }

    private static func recognize(_ image: CGImage, languages: [String]) throws -> [ResultRegion] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = false
        request.recognitionLanguages = languages
        request.minimumTextHeight = 0.0025
        request.customWords = [
            "えっ", "うそ", "まさか", "ありがとう", "ごめん", "大丈夫", "どうして", "なぜ",
            "ほんと", "本当", "好き", "嫌い", "お願い", "待って", "行こう", "わかった"
        ]

        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
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
                let union = existing.box.union(candidate.box)
                let unionArea = union.width * union.height
                let overlap = unionArea > 0 ? intersection.width * intersection.height / unionArea : 0
                let sameCenter = abs(existing.box.midX - candidate.box.midX) < 0.018
                    && abs(existing.box.midY - candidate.box.midY) < 0.018
                return overlap > 0.48 || (existing.text == candidate.text && sameCenter)
            }
            if !duplicate { merged.append(candidate) }
        }

        // Japanese manga is generally read from the rightmost column toward the left.
        return merged.sorted {
            if abs($0.box.midX - $1.box.midX) > 0.06 {
                return $0.box.midX > $1.box.midX
            }
            return $0.box.midY > $1.box.midY
        }
    }

    /// Geometry hints for future balloon-aware OCR and speaker association.
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
