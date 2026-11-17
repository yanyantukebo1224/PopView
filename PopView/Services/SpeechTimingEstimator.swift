import Foundation
import NaturalLanguage
import IrodoriTTS

enum SpeechTimingEstimator {
    /// Estimates subtitle intervals from audio duration. Irodori's public API does not
    /// currently expose token- or phoneme-alignment timestamps.
    static func estimate(text: String, duration: TimeInterval) -> [WordTiming] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var units: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let token = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty { units.append(token) }
            return true
        }
        if units.isEmpty { units = text.map(String.init).filter { !$0.isWhitespace } }
        let weights = units.map { max(1, $0.count) }
        let total = max(1, weights.reduce(0, +))
        var cursor = 0.0
        return zip(units, weights).map { unit, weight in
            let start = cursor
            cursor += duration * Double(weight) / Double(total)
            return WordTiming(text: unit, start: start, end: cursor)
        }
    }
}
