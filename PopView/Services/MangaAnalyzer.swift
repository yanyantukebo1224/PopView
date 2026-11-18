import Foundation
import Vision
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

struct MangaAnalyzer {
    struct ResultRegion {
        var text: String
        var box: CGRect
        var confidence: Float
    }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Manga OCR pipeline:
    /// 1) normalize UIImage orientation
    /// 2) OCR the complete page at native and enhanced resolution
    /// 3) OCR overlapping 3x3 crops so small dialogue is enlarged
    /// 4) run Japanese OCR both with and without language correction
    /// 5) merge overlapping detections without dropping distinct nearby lines
    func recognizeText(in image: UIImage) async throws -> [ResultRegion] {
        guard let normalized = Self.normalizedCGImage(from: image) else {
            throw AnalysisError.invalidImage
        }

        return try await Task.detached(priority: .userInitiated) {
            var results: [ResultRegion] = []
            let enhancedPage = Self.enhanceAndUpscale(normalized, scale: 1.35)

            results += try Self.recognize(normalized, languages: ["ja-JP"], correction: false)
            results += try Self.recognize(normalized, languages: ["ja-JP"], correction: true)
            results += try Self.recognize(enhancedPage, languages: ["ja-JP"], correction: false)
            results += try Self.recognize(normalized, languages: ["en-US"], correction: false)

            let width = normalized.width
            let height = normalized.height
            let columns = 3
            let rows = 3
            let overlap = 0.24
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
                    let rect = CGRect(x: minX, y: minY,
                                      width: maxX - minX, height: maxY - minY)
                    guard let crop = normalized.cropping(to: rect) else { continue }

                    // Upscaling the crop is especially important for small furigana
                    // and dialogue printed at low source resolution.
                    let enlarged = Self.enhanceAndUpscale(crop, scale: 1.8)
                    let cropResults =
                        try Self.recognize(enlarged, languages: ["ja-JP"], correction: false)
                        + Self.recognize(enlarged, languages: ["ja-JP"], correction: true)
                        + Self.recognize(crop, languages: ["en-US"], correction: false)

                    let xOffset = Double(minX) / Double(width)
                    let yBottomOffset = Double(height - maxY) / Double(height)
                    let xScale = Double(crop.width) / Double(width)
                    let yScale = Double(crop.height) / Double(height)

                    results += cropResults.map { item in
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

    private static func normalizedCGImage(from image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cgImage = image.cgImage {
            return cgImage
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale > 0 ? image.scale : 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return rendered.cgImage
    }

    /// Grayscale/contrast enhancement plus high-quality enlargement.
    /// Keep the original image path too, since aggressive enhancement can hurt
    /// thin fonts, pale text, and screentone backgrounds.
    private static func enhanceAndUpscale(_ image: CGImage, scale: CGFloat) -> CGImage {
        let input = CIImage(cgImage: image)
        let controls = CIFilter.colorControls()
        controls.inputImage = input
        controls.saturation = 0
        controls.contrast = 1.38
        controls.brightness = 0.025

        let sharpen = CIFilter.unsharpMask()
        sharpen.inputImage = controls.outputImage
        sharpen.radius = 1.15
        sharpen.intensity = 0.62

        let output = sharpen.outputImage ?? controls.outputImage ?? input
        let extent = output.extent.integral
        guard let filtered = ciContext.createCGImage(output, from: extent) else {
            return image
        }
        return Self.resize(filtered, scale: scale) ?? filtered
    }

    private static func resize(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func recognize(
        _ image: CGImage,
        languages: [String],
        correction: Bool
    ) throws -> [ResultRegion] {
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequest.currentRevision
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = correction
        request.automaticallyDetectsLanguage = false
        request.recognitionLanguages = languages
        request.minimumTextHeight = 0.001
        request.customWords = [
            "えっ", "うそ", "まさか", "ありがとう", "ごめん", "大丈夫", "どうして", "なぜ",
            "ほんと", "本当", "好き", "嫌い", "お願い", "待って", "行こう", "わかった",
            "ちょっと", "なんで", "だから", "でも", "いや", "あの", "ええ", "お前",
            "私", "僕", "俺", "あなた", "先生", "先輩", "ちゃん", "くん"
        ]

        try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(3).first else { return nil }
            let value = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            return ResultRegion(
                text: value,
                box: observation.boundingBox,
                confidence: candidate.confidence
            )
        }
    }

    private static func normalizedText(_ text: String) -> String {
        text.lowercased()
            .filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol }
    }

    private static func mergeAndSort(_ regions: [ResultRegion]) -> [ResultRegion] {
        var merged: [ResultRegion] = []
        for candidate in regions.sorted(by: { $0.confidence > $1.confidence }) {
            let candidateArea = max(0, candidate.box.width * candidate.box.height)
            let duplicateIndex = merged.firstIndex { existing in
                let intersection = existing.box.intersection(candidate.box)
                guard !intersection.isNull else { return false }
                let intersectionArea = max(0, intersection.width * intersection.height)
                let existingArea = max(0, existing.box.width * existing.box.height)
                let smallerArea = min(existingArea, candidateArea)
                guard smallerArea > 0 else { return false }
                let overlapOfSmaller = intersectionArea / smallerArea
                let sameCenter = abs(existing.box.midX - candidate.box.midX) < 0.012
                    && abs(existing.box.midY - candidate.box.midY) < 0.012
                let sameText = normalizedText(existing.text) == normalizedText(candidate.text)
                return overlapOfSmaller > 0.72 || (sameText && sameCenter)
            }
            if let index = duplicateIndex {
                // Prefer the more legible/high-confidence recognition, but retain
                // the tighter geometry when both candidates describe the same line.
                if candidate.confidence > merged[index].confidence {
                    merged[index] = candidate
                }
            } else {
                merged.append(candidate)
            }
        }

        // Standard Japanese manga order: right to left, then top to bottom.
        return merged.sorted {
            if abs($0.box.midX - $1.box.midX) > 0.055 {
                return $0.box.midX > $1.box.midX
            }
            return $0.box.midY > $1.box.midY
        }
    }

    /// Geometry hints for balloon-aware review and speaker association.
    func detectBalloonCandidates(in image: UIImage) async throws -> [CGRect] {
        guard let cgImage = Self.normalizedCGImage(from: image) else {
            throw AnalysisError.invalidImage
        }
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
