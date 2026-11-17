import Foundation
import UIKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Uses Apple Intelligence only when filenames do not provide a reliable order.
/// A result is accepted only when it is a complete permutation of the supplied pages.
enum MangaImportOrderAssistant {
    static func suggestedOrder(for images: [UIImage]) async -> [Int]? {
        guard (2...12).contains(images.count) else { return nil }
        #if canImport(FoundationModels)
        guard #available(iOS 27.0, *),
              case .available = SystemLanguageModel.default.availability else { return nil }

        let columns = 3
        let rows = 4
        let cell = CGSize(width: 300, height: 300)
        let sheet = UIGraphicsImageRenderer(size: CGSize(width: cell.width * CGFloat(columns),
                                                          height: cell.height * CGFloat(rows))).image { context in
            let fullSize = CGSize(width: cell.width * CGFloat(columns), height: cell.height * CGFloat(rows))
            context.cgContext.setFillColor(UIColor.white.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: fullSize))
            for (index, image) in images.enumerated() {
                let column = index % columns
                let row = index / columns
                let origin = CGPoint(x: CGFloat(column) * cell.width, y: CGFloat(row) * cell.height)
                let label = "PAGE \(index + 1)"
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: 22),
                    .foregroundColor: UIColor.black
                ]
                (label as NSString).draw(at: CGPoint(x: origin.x + 12, y: origin.y + 8),
                                         withAttributes: attributes)
                let available = CGRect(x: origin.x + 12, y: origin.y + 42,
                                       width: cell.width - 24, height: cell.height - 54)
                let scale = min(available.width / image.size.width,
                                available.height / image.size.height)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: CGRect(x: available.midX - size.width / 2,
                                      y: available.midY - size.height / 2,
                                      width: size.width, height: size.height))
                context.cgContext.setStrokeColor(UIColor.lightGray.cgColor)
                context.cgContext.stroke(CGRect(origin: origin, size: cell))
            }
        }
        guard let cgImage = sheet.cgImage else { return nil }

        do {
            let session = LanguageModelSession()
            let response = try await session.respond {
                """
                これはファイル名が不規則な漫画ページの一覧です。各サムネイルの絵・コマ・会話の連続性を見て、物語として自然なページ順を推定してください。
                各サムネイルにはPAGE 1からPAGE \(images.count)まで番号があります。
                すべての番号を一度ずつ使い、存在しない番号を追加しないでください。
                判別できない場合は番号順を返してください。
                JSONだけを返してください。形式: {"order":[1,2,3]}
                """
                Attachment(cgImage)
            }
            guard let first = response.content.firstIndex(of: "{"),
                  let last = response.content.lastIndex(of: "}"),
                  let data = String(response.content[first...last]).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: [Int]],
                  let oneBased = object["order"], oneBased.count == images.count else { return nil }
            let zeroBased = oneBased.map { $0 - 1 }
            guard Set(zeroBased) == Set(images.indices) else { return nil }
            return zeroBased
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}
