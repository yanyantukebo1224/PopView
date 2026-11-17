import Foundation
import Vision
import UIKit

struct MangaAnalyzer {
    struct ResultRegion {
        var text: String
        var box: CGRect
        var confidence: Float
    }

    func recognizeText(in image: UIImage) async throws -> [ResultRegion] {
        guard let cgImage = image.cgImage else { throw AnalysisError.invalidImage }
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error { continuation.resume(throwing: error); return }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let results = observations.compactMap { observation -> ResultRegion? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    return ResultRegion(text: candidate.string, box: observation.boundingBox, confidence: candidate.confidence)
                }.sorted {
                    if abs($0.box.midY - $1.box.midY) > 0.025 { return $0.box.midY > $1.box.midY }
                    return $0.box.midX > $1.box.midX
                }
                continuation.resume(returning: results)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["ja-JP", "en-US"]
            request.minimumTextHeight = 0.008
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Detects likely balloon frames. This is a proposal generator, not semantic balloon classification.
    func detectBalloonCandidates(in image: UIImage) async throws -> [CGRect] {
        guard let cgImage = image.cgImage else { throw AnalysisError.invalidImage }
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNDetectRectanglesRequest { request, error in
                if let error { continuation.resume(throwing: error); return }
                let boxes = ((request.results as? [VNRectangleObservation]) ?? [])
                    .filter { $0.boundingBox.width > 0.06 && $0.boundingBox.height > 0.035 }
                    .map(\.boundingBox)
                continuation.resume(returning: boxes)
            }
            request.minimumConfidence = 0.25
            request.minimumAspectRatio = 0.15
            request.maximumObservations = 80
            DispatchQueue.global(qos: .userInitiated).async {
                do { try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request]) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    enum AnalysisError: Error { case invalidImage }
}
