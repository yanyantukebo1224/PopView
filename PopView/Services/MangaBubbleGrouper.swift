import Foundation
import CoreGraphics

/// Groups nearby OCR text lines into likely speech balloons.
/// This is deliberately conservative: uncertain lines remain separate instead
/// of being merged into an unrelated neighboring balloon.
enum MangaBubbleGrouper {
    struct Bubble: Identifiable {
        let id: UUID
        let text: String
        let box: CGRect
        let confidence: Float
        let sourceIndices: [Int]
        let readingOrder: Int
    }

    static func group(_ regions: [MangaAnalyzer.ResultRegion]) -> [Bubble] {
        guard !regions.isEmpty else { return [] }

        var parent = Array(regions.indices)
        func root(_ value: Int) -> Int {
            var index = value
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }

        func shouldJoin(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
            let xOverlap = overlapRatio(lhs.minX, lhs.maxX, rhs.minX, rhs.maxX)
            let yOverlap = overlapRatio(lhs.minY, lhs.maxY, rhs.minY, rhs.maxY)
            let horizontalGap = max(0, max(lhs.minX, rhs.minX) - min(lhs.maxX, rhs.maxX))
            let verticalGap = max(0, max(lhs.minY, rhs.minY) - min(lhs.maxY, rhs.maxY))

            // Adjacent vertical text columns, or adjacent fragments in one column.
            let neighboringColumns = yOverlap >= 0.22 && horizontalGap <= 0.035
            let sameColumn = xOverlap >= 0.28 && verticalGap <= 0.025
            guard neighboringColumns || sameColumn else { return false }

            let union = lhs.union(rhs)
            // Avoid chaining distant lines across most of a panel/page.
            return union.width <= 0.34 && union.height <= 0.62
        }

        for i in regions.indices {
            for j in regions.indices where j > i {
                if shouldJoin(regions[i].box, regions[j].box) {
                    let a = root(i)
                    let b = root(j)
                    if a != b { parent[b] = a }
                }
            }
        }

        var buckets: [Int: [Int]] = [:]
        for index in regions.indices {
            buckets[root(index), default: []].append(index)
        }

        let unsorted = buckets.values.map { indices -> Bubble in
            let ordered = indices.sorted {
                let a = regions[$0].box
                let b = regions[$1].box
                if abs(a.midX - b.midX) > 0.012 { return a.midX > b.midX }
                return a.midY > b.midY
            }
            let boxes = ordered.map { regions[$0].box }
            let union = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
            // Preserve the OCR text verbatim; line breaks separate detected lines.
            let text = ordered.map { regions[$0].text }.joined(separator: "\n")
            let confidence = ordered.map { regions[$0].confidence }.min() ?? 0
            return Bubble(id: UUID(), text: text, box: union,
                          confidence: confidence, sourceIndices: ordered, readingOrder: 0)
        }

        let pageOrdered = unsorted.sorted {
            if abs($0.box.midX - $1.box.midX) > 0.055 {
                return $0.box.midX > $1.box.midX
            }
            return $0.box.midY > $1.box.midY
        }
        return pageOrdered.enumerated().map { index, bubble in
            Bubble(id: bubble.id, text: bubble.text, box: bubble.box,
                   confidence: bubble.confidence, sourceIndices: bubble.sourceIndices,
                   readingOrder: index)
        }
    }

    private static func overlapRatio(_ a0: CGFloat, _ a1: CGFloat,
                                     _ b0: CGFloat, _ b1: CGFloat) -> CGFloat {
        let intersection = max(0, min(a1, b1) - max(a0, b0))
        let denominator = max(0.0001, min(a1 - a0, b1 - b0))
        return intersection / denominator
    }
}
