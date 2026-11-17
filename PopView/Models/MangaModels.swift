import Foundation
import CoreGraphics

struct MangaPage: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var imageFileName: String
    var sourcePageIndex: Int?
    var textRegions: [SpeechRegion] = []
}

struct SpeechRegion: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var text: String
    /// Normalized Vision coordinates: origin at lower-left.
    var box: CGRectCodable
    var speakerID: UUID?
    var confidence: Float
    var wordTimings: [WordTiming] = []
    var audioFileName: String?
    /// Estimated emotional tone inferred from the page image.
    var emotion: String?
    /// Suggested performance direction for speech synthesis.
    var actingDirection: String?
    /// Stable speaker label assigned by page analysis, when available.
    var speakerLabel: String?
    /// Reading order inferred from the page layout.
    var readingOrder: Int?
}

struct CGRectCodable: Codable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    init(x: Double, y: Double, width: Double, height: Double) {
        self.x=x; self.y=y; self.width=width; self.height=height
    }
    init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }
    var cgRect: CGRect { CGRect(x:x, y:y, width:width, height:height) }
}

struct WordTiming: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

struct CharacterVoice: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var voiceDescription: String = ""
    /// Visual description inferred from manga artwork; does not affect voice synthesis.
    var visualDescription: String?
    var referenceAudioFileName: String?
    var createdAt: Date = .now
}

struct MangaProject: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var createdAt: Date = .now
    var pages: [MangaPage] = []
    var characters: [CharacterVoice] = []
}
