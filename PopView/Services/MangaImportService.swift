import Foundation
import ImageIO
import PDFKit
import ZIPFoundation
import Unrar

struct PreparedMangaPage: Sendable {
    let fileName: String
    let title: String
    let sourcePageIndex: Int?
}

struct MangaImportService {
    private static let maximumArchiveEntries = 8_000
    private static let maximumEntryBytes: UInt64 = 160 * 1_024 * 1_024
    private static let maximumTotalBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024
    private static let maximumNestingDepth = 4
    private static let archiveExtensions: Set<String> = ["zip", "cbz", "rar"]

    private struct Candidate {
        let url: URL
        let relativePath: String
        let title: String
    }

    private final class ScanState {
        var candidates: [Candidate] = []
        var totalUncompressedBytes: UInt64 = 0
        var visitedFiles = 0
    }

    /// File-provider URLs are first coordinated and copied into the app's
    /// container. The scanner then works only with local files, avoiding
    /// expired security scopes and iCloud/File Provider placeholder URLs.
    static func prepare(urls: [URL], destination: URL) throws -> [PreparedMangaPage] {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let staging = destination.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let state = ScanState()
        for (index, sourceURL) in urls.enumerated() {
            let values = try? sourceURL.resourceValues(forKeys: [.isDirectoryKey])
            let isDirectory = values?.isDirectory == true
            let coordinatedName = String(format: "%04d-", index) + safeFileName(sourceURL.lastPathComponent)
            let targetExtension = isDirectory ? "zip" : sourceURL.pathExtension
            let localName = targetExtension.isEmpty
                ? coordinatedName
                : URL(fileURLWithPath: coordinatedName).deletingPathExtension().lastPathComponent + "." + targetExtension
            let localURL = staging.appendingPathComponent(localName)

            var coordinationError: NSError?
            var copyError: Error?
            let coordinator = NSFileCoordinator(filePresenter: nil)
            coordinator.coordinate(
                readingItemAt: sourceURL,
                options: isDirectory ? .forUploading : [],
                error: &coordinationError
            ) { coordinatedURL in
                do {
                    try fm.copyItem(at: coordinatedURL, to: localURL)
                } catch {
                    copyError = error
                }
            }
            if let coordinationError { throw ImportError.fileAccessFailed(sourceURL.lastPathComponent, coordinationError.localizedDescription) }
            if let copyError { throw copyError }

            try collect(
                url: localURL,
                relativePath: String(format: "%04d/", index) + sourceURL.lastPathComponent,
                staging: staging,
                state: state,
                depth: 0
            )
        }

        guard !state.candidates.isEmpty else {
            throw ImportError.noReadablePages
        }

        let sortedCandidates = state.candidates.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        // Explicit thumbnail/preview assets and tiny image renditions are not manga pages.
        // Keep small images when they are the only available content to avoid empty imports.
        let filteredCandidates = sortedCandidates.filter { !isLikelyThumbnail($0.url) }
        let ordered = filteredCandidates.isEmpty ? sortedCandidates : filteredCandidates

        var pages: [PreparedMangaPage] = []
        for candidate in ordered {
            if let document = PDFDocument(url: candidate.url), document.pageCount > 0 {
                let storedName = UUID().uuidString + ".pdf"
                let storedURL = destination.appendingPathComponent(storedName)
                try fm.copyItem(at: candidate.url, to: storedURL)
                for pageIndex in 0..<document.pageCount {
                    let suffix = document.pageCount > 1 ? " - \(pageIndex + 1)" : ""
                    pages.append(PreparedMangaPage(fileName: storedName,
                        title: candidate.title + suffix, sourcePageIndex: pageIndex))
                }
            } else {
                let ext = candidate.url.pathExtension.isEmpty ? "img" : candidate.url.pathExtension.lowercased()
                let storedName = UUID().uuidString + "." + ext
                let storedURL = destination.appendingPathComponent(storedName)
                try fm.copyItem(at: candidate.url, to: storedURL)
                let splitPages = try splitSpreadIfNeeded(at: storedURL, title: candidate.title, destination: destination)
                pages.append(contentsOf: splitPages)
            }
        }
        return pages
    }

    private static func isLikelyThumbnail(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        let pathParts = url.path.lowercased().split(separator: "/")
        let directoryMarkers = ["thumbs", "thumbnails", "previews", "cache"]
        if pathParts.contains(where: { directoryMarkers.contains(String($0)) }) { return true }
        let tokens = ["thumbnail", "thumb", "preview", "small", "poster", "icon"]
        if tokens.contains(where: { name.contains($0) }) { return true }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return max(width, height) < 420
    }

    /// Converts a landscape double-page scan into two portrait page images.
    /// Manga reading order is right page first, then left page.
    private static func splitSpreadIfNeeded(at sourceURL: URL, title: String, destination: URL) throws -> [PreparedMangaPage] {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 12_000
              ] as CFDictionary) else {
            return [PreparedMangaPage(fileName: sourceURL.lastPathComponent, title: title, sourcePageIndex: nil)]
        }

        let ratio = Double(image.width) / Double(image.height)
        guard ratio >= 1.32, image.width >= 1_200, image.height >= 700 else {
            return [PreparedMangaPage(fileName: sourceURL.lastPathComponent, title: title, sourcePageIndex: nil)]
        }

        let center = image.width / 2
        let rightRect = CGRect(x: center, y: 0, width: image.width - center, height: image.height)
        let leftRect = CGRect(x: 0, y: 0, width: center, height: image.height)
        guard let right = image.cropping(to: rightRect), let left = image.cropping(to: leftRect) else {
            return [PreparedMangaPage(fileName: sourceURL.lastPathComponent, title: title, sourcePageIndex: nil)]
        }

        func write(_ cgImage: CGImage) throws -> String {
            let name = UUID().uuidString + ".jpg"
            let url = destination.appendingPathComponent(name)
            guard let output = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            CGImageDestinationAddImage(output, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.94] as CFDictionary)
            guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
            return name
        }

        // Remove the temporary full-spread copy once both split pages are safely written.
        let rightName = try write(right)
        let leftName = try write(left)
        try? FileManager.default.removeItem(at: sourceURL)
        return [
            PreparedMangaPage(fileName: rightName, title: title + " - 右ページ", sourcePageIndex: nil),
            PreparedMangaPage(fileName: leftName, title: title + " - 左ページ", sourcePageIndex: nil)
        ]
    }

    private static func safeFileName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return cleaned.isEmpty ? "imported-file" : cleaned
    }

    private static func collect(url: URL, relativePath: String, staging: URL,
                                state: ScanState, depth: Int) throws {
        guard depth <= maximumNestingDepth else { return }
        let fm = FileManager.default
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey])
        if values?.isHidden == true || values?.isSymbolicLink == true { return }

        if values?.isDirectory == true {
            guard let enumerator = fm.enumerator(at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
            for case let child as URL in enumerator {
                let childValues = try? child.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey])
                if childValues?.isHidden == true || childValues?.isSymbolicLink == true {
                    if childValues?.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }
                if childValues?.isDirectory == true { continue }
                let relative = child.path.replacingOccurrences(of: url.path + "/", with: "")
                try collect(url: child, relativePath: relativePath + "/" + relative,
                            staging: staging, state: state, depth: depth)
            }
            return
        }

        guard values?.isRegularFile != false else { return }
        state.visitedFiles += 1
        guard state.visitedFiles <= maximumArchiveEntries * 4 else {
            throw ImportError.tooManyFiles
        }
        let ext = url.pathExtension.lowercased()

        if archiveExtensions.contains(ext) {
            try collectArchive(url: url, relativePath: relativePath, staging: staging,
                               state: state, depth: depth + 1)
            return
        }

        if let document = PDFDocument(url: url), document.pageCount > 0 {
            state.candidates.append(Candidate(url: url, relativePath: relativePath,
                title: url.deletingPathExtension().lastPathComponent))
            return
        }

        if isDecodableImage(url) {
            state.candidates.append(Candidate(url: url, relativePath: relativePath,
                title: url.deletingPathExtension().lastPathComponent))
        }
    }

    private static func collectArchive(url: URL, relativePath: String, staging: URL,
                                       state: ScanState, depth: Int) throws {
        let ext = url.pathExtension.lowercased()
        let archiveFolder = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: archiveFolder, withIntermediateDirectories: true)

        if ext == "zip" || ext == "cbz" {
            let archive = try ZIPFoundation.Archive(url: url, accessMode: .read)
            var entryCount = 0
            for entry in archive {
                entryCount += 1
                guard entryCount <= maximumArchiveEntries else { throw ImportError.tooManyFiles }
                guard entry.type == .file, entry.uncompressedSize <= maximumEntryBytes else { continue }
                try addUncompressedBytes(entry.uncompressedSize, to: state)
                guard let output = safeDestination(for: entry.path, in: archiveFolder) else { continue }
                try archive.extract(entry, to: output, skipCRC32: false)
                try collect(url: output, relativePath: relativePath + "/" + entry.path,
                            staging: staging, state: state, depth: depth)
            }
        } else if ext == "rar" {
            let archive = try Unrar.Archive(fileURL: url)
            if archive.isVolume {
                throw ImportError.unsupportedRARVolume
            }
            let entries = try archive.entries()
            guard entries.count <= maximumArchiveEntries else { throw ImportError.tooManyFiles }
            for entry in entries where !entry.directory {
                guard entry.uncompressedSize <= maximumEntryBytes else { continue }
                if entry.encrypted { throw ImportError.encryptedRAR }
                try addUncompressedBytes(entry.uncompressedSize, to: state)
                guard let output = safeDestination(for: entry.fileName, in: archiveFolder) else { continue }
                let data = try archive.extract(entry)
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try data.write(to: output, options: .atomic)
                try collect(url: output, relativePath: relativePath + "/" + entry.fileName,
                            staging: staging, state: state, depth: depth)
            }
        }
    }

    private static func addUncompressedBytes(_ amount: UInt64, to state: ScanState) throws {
        let (sum, overflow) = state.totalUncompressedBytes.addingReportingOverflow(amount)
        guard !overflow, sum <= maximumTotalBytes else { throw ImportError.archiveTooLarge }
        state.totalUncompressedBytes = sum
    }

    private static func safeDestination(for archivePath: String, in root: URL) -> URL? {
        let normalized = archivePath.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/"),
              !normalized.split(separator: "/").contains("..") else { return nil }
        let destination = root.appendingPathComponent(normalized).standardizedFileURL
        let rootPath = root.standardizedFileURL.path + "/"
        guard destination.path.hasPrefix(rootPath) else { return nil }
        return destination
    }

    private static func isDecodableImage(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { return false }
        return true
    }

    enum ImportError: LocalizedError {
        case noReadablePages
        case tooManyFiles
        case archiveTooLarge
        case encryptedRAR
        case unsupportedRARVolume
        case fileAccessFailed(String, String)

        var errorDescription: String? {
            switch self {
            case .noReadablePages:
                return "選択したファイル内に読み込める画像またはPDFがありませんでした。画像・PDF・ZIP/CBZ/RAR、またはそれらを含むフォルダを選択してください。"
            case .tooManyFiles:
                return "ファイル数が多すぎるため、安全のため読み込みを中止しました。"
            case .archiveTooLarge:
                return "展開後のデータ量が上限を超えるため読み込みを中止しました。"
            case .encryptedRAR:
                return "パスワード付きRARには現在対応していません。"
            case .unsupportedRARVolume:
                return "分割RARの途中ファイルです。最初のRARファイルを選択してください。"
            case .fileAccessFailed(let name, let reason):
                return "「\(name)」をファイルアプリから読み取れませんでした。ファイルを端末にダウンロードしてから再度選択してください。\n\(reason)"
            }
        }
    }
}
