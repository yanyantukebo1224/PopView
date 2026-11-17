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
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "webp",
        "bmp", "tif", "tiff", "avif", "jxl"
    ]
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

    static func prepare(urls: [URL], destination: URL) throws -> [PreparedMangaPage] {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let staging = destination.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let state = ScanState()
        for (index, url) in urls.enumerated() {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try collect(url: url, relativePath: String(format: "%04d/", index) + url.lastPathComponent,
                        staging: staging, state: state, depth: 0)
        }

        guard !state.candidates.isEmpty else {
            throw ImportError.noReadablePages
        }

        let ordered = state.candidates.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }

        var pages: [PreparedMangaPage] = []
        for candidate in ordered {
            if candidate.url.pathExtension.lowercased() == "pdf",
               let document = PDFDocument(url: candidate.url), document.pageCount > 0 {
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
                try fm.copyItem(at: candidate.url, to: destination.appendingPathComponent(storedName))
                pages.append(PreparedMangaPage(fileName: storedName,
                    title: candidate.title, sourcePageIndex: nil))
            }
        }
        return pages
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
                // The directory enumerator is already recursive. Let it descend
                // naturally instead of scanning a nested folder twice.
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

        if ext == "pdf" {
            if PDFDocument(url: url)?.pageCount ?? 0 > 0 {
                state.candidates.append(Candidate(url: url, relativePath: relativePath,
                    title: url.deletingPathExtension().lastPathComponent))
            }
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
            guard archive.count <= maximumArchiveEntries else { throw ImportError.tooManyFiles }
            for entry in archive {
                guard entry.type == .file, entry.uncompressedSize <= maximumEntryBytes else { continue }
                try addUncompressedBytes(entry.uncompressedSize, to: state)
                guard let output = safeDestination(for: entry.path, in: archiveFolder) else { continue }
                try archive.extract(entry, to: output, skipCRC32: false)
                try collect(url: output, relativePath: relativePath + "/" + entry.path,
                            staging: staging, state: state, depth: depth)
            }
        } else if ext == "rar" {
            let archive = try Unrar.Archive(fileURL: url)
            if archive.isVolume && !archive.isFirstVolume {
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

        var errorDescription: String? {
            switch self {
            case .noReadablePages:
                return "選択したファイル内に読み込める画像またはPDFがありませんでした。"
            case .tooManyFiles:
                return "ファイル数が多すぎるため、安全のため読み込みを中止しました。"
            case .archiveTooLarge:
                return "展開後のデータ量が上限を超えるため読み込みを中止しました。"
            case .encryptedRAR:
                return "パスワード付きRARには現在対応していません。"
            case .unsupportedRARVolume:
                return "分割RARの途中ファイルです。最初のRARファイルを選択してください。"
            }
        }
    }
}
