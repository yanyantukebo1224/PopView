import Foundation
import UIKit
import Combine

@MainActor
final class LocalProjectStore: ObservableObject {
    @Published private(set) var projects: [MangaProject] = []
    private let root: URL
    private let indexURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("PopView", isDirectory: true)
        indexURL = root.appendingPathComponent("projects.json")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: inboxFolderURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: importedInboxFolderURL, withIntermediateDirectories: true)
        loadIndex()
    }

    func createProject(title: String) -> MangaProject {
        let project = MangaProject(title: title)
        projects.insert(project, at: 0)
        persist()
        return project
    }

    func deleteProjects(at offsets: IndexSet) {
        let ids = offsets.compactMap { projects.indices.contains($0) ? projects[$0].id : nil }
        for id in ids {
            try? FileManager.default.removeItem(at: projectFolder(id))
        }
        projects.removeAll { ids.contains($0.id) }
        persist()
    }

    func deletePages(at offsets: IndexSet, from projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].pages = projects[index].pages.enumerated()
            .filter { !offsets.contains($0.offset) }
            .map(\.element)
        persist()
    }

    /// Files app path: On My iPhone > PopView > Import.
    var inboxFolderURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Import", isDirectory: true)
    }

    private var importedInboxFolderURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Imported", isDirectory: true)
    }

    /// Each dropped folder becomes a project; loose files are imported as one batch.
    /// Successfully imported source items are moved into Imported to prevent duplicates.
    func importInboxItems() async throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: inboxFolderURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: importedInboxFolderURL, withIntermediateDirectories: true)
        let items = try fm.contentsOfDirectory(at: inboxFolderURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles])
        let supportedExtensions: Set<String> = [
            "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tif", "tiff", "bmp",
            "pdf", "zip", "cbz", "rar"
        ]
        let supported = items.filter { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey])
            if values?.isHidden == true { return false }
            return values?.isDirectory == true || supportedExtensions.contains(url.pathExtension.lowercased())
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        let folders = supported.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        let looseFiles = supported.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
        }
        var importedPageCount = 0

        for folder in folders {
            importedPageCount += try await importInboxGroup([folder], title: folder.lastPathComponent)
        }
        if !looseFiles.isEmpty {
            let title: String
            if looseFiles.count == 1 {
                title = looseFiles[0].deletingPathExtension().lastPathComponent
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "ja_JP")
                formatter.dateFormat = "yyyy-MM-dd HH-mm"
                title = "ファイル取り込み " + formatter.string(from: Date())
            }
            importedPageCount += try await importInboxGroup(looseFiles, title: title)
        }
        return importedPageCount
    }

    private func importInboxGroup(_ urls: [URL], title: String) async throws -> Int {
        let project = createProject(title: title)
        do {
            let count = try await addImportedItems(urls: urls, to: project.id)
            guard count > 0 else {
                deleteProject(project.id)
                throw MangaImportService.ImportError.noReadablePages
            }
            for source in urls {
                try FileManager.default.moveItem(at: source,
                    to: uniqueInboxDestination(for: source.lastPathComponent))
            }
            return count
        } catch {
            deleteProject(project.id)
            throw error
        }
    }

    private func uniqueInboxDestination(for fileName: String) -> URL {
        let fm = FileManager.default
        var destination = importedInboxFolderURL.appendingPathComponent(fileName)
        if fm.fileExists(atPath: destination.path) {
            let ext = destination.pathExtension
            let base = destination.deletingPathExtension().lastPathComponent
            let uniqueName = base + "-" + String(UUID().uuidString.prefix(8))
                + (ext.isEmpty ? "" : "." + ext)
            destination = importedInboxFolderURL.appendingPathComponent(uniqueName)
        }
        return destination
    }

    func deleteProject(_ id: UUID) {
        try? FileManager.default.removeItem(at: projectFolder(id))
        projects.removeAll { $0.id == id }
        persist()
    }

    func addImportedItems(urls: [URL], to projectID: UUID) async throws -> Int {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else { return 0 }
        let destination = projectFolder(projectID)
        // Keep each security-scoped grant alive until the coordinated copy
        // into the app container has completed.
        let scopedURLs = urls.map { url in
            (url, url.startAccessingSecurityScopedResource())
        }
        defer {
            for (url, didStart) in scopedURLs where didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let prepared = try await Task.detached(priority: .userInitiated) {
            try MangaImportService.prepare(urls: scopedURLs.map(\.0), destination: destination)
        }.value
        guard projects.indices.contains(projectIndex),
              projects[projectIndex].id == projectID else { return 0 }

        var ordered = prepared
        if (2...12).contains(prepared.count) {
            let pageNumbers = prepared.map { item -> Int? in
                let digits = item.title.reversed().prefix { $0.isNumber }.reversed()
                return digits.isEmpty ? nil : Int(String(digits))
            }
            let reliableNumbering = pageNumbers.allSatisfy { $0 != nil }
                && Set(pageNumbers.compactMap { $0 }).count == prepared.count
                && ((pageNumbers.compactMap { $0 }.max() ?? 0)
                    - (pageNumbers.compactMap { $0 }.min() ?? 0) <= prepared.count * 3)
            if !reliableNumbering {
                let thumbnails = prepared.compactMap { item -> UIImage? in
                    let url = destination.appendingPathComponent(item.fileName)
                    if item.fileName.lowercased().hasSuffix(".pdf") {
                        return PDFPageRenderer.render(url: url, pageIndex: item.sourcePageIndex ?? 0)
                    }
                    return UIImage(contentsOfFile: url.path)
                }
                if thumbnails.count == prepared.count,
                   let visualOrder = await MangaImportOrderAssistant.suggestedOrder(for: thumbnails) {
                    ordered = visualOrder.map { prepared[$0] }
                }
            }
        }

        projects[projectIndex].pages.append(contentsOf: ordered.map {
            MangaPage(title: $0.title, imageFileName: $0.fileName, sourcePageIndex: $0.sourcePageIndex)
        })
        persist()
        return ordered.count
    }

    func addImagePages(urls: [URL], to projectID: UUID) throws {
        guard let index = projects.firstIndex(where: {$0.id == projectID}) else { return }
        let folder = projectFolder(projectID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            guard UIImage(data: data) != nil else { continue }
            let name = UUID().uuidString + "." + (url.pathExtension.isEmpty ? "jpg" : url.pathExtension)
            try data.write(to: folder.appendingPathComponent(name), options: .atomic)
            projects[index].pages.append(MangaPage(title: url.deletingPathExtension().lastPathComponent, imageFileName: name))
        }
        persist()
    }

    func addPDF(url: URL, to projectID: UUID) throws {
        guard let index = projects.firstIndex(where: {$0.id == projectID}) else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let destination = projectFolder(projectID).appendingPathComponent(UUID().uuidString + ".pdf")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: destination)
        let count = PDFPageRenderer.pageCount(url: destination)
        guard count > 0 else { throw CocoaError(.fileReadCorruptFile) }
        for pageIndex in 0..<count {
            let suffix = count > 1 ? " - \(pageIndex + 1)" : ""
            projects[index].pages.append(MangaPage(
                title: url.deletingPathExtension().lastPathComponent + suffix,
                imageFileName: destination.lastPathComponent,
                sourcePageIndex: pageIndex
            ))
        }
        persist()
    }

    func imageURL(for page: MangaPage, projectID: UUID) -> URL {
        projectFolder(projectID).appendingPathComponent(page.imageFileName)
    }

    func image(for page: MangaPage, projectID: UUID) -> UIImage? {
        let url = imageURL(for: page, projectID: projectID)
        if url.pathExtension.lowercased() == "pdf" {
            return PDFPageRenderer.render(url: url, pageIndex: page.sourcePageIndex ?? 0)
        }
        return UIImage(contentsOfFile: url.path)
    }

    func updatePage(_ page: MangaPage, projectID: UUID) {
        guard let p = projects.firstIndex(where: {$0.id == projectID}),
              let i = projects[p].pages.firstIndex(where: {$0.id == page.id}) else { return }
        projects[p].pages[i] = page
        persist()
    }

    func addCharacter(_ character: CharacterVoice, to projectID: UUID) {
        guard let i = projects.firstIndex(where: {$0.id == projectID}) else { return }
        projects[i].characters.append(character)
        persist()
    }

    func updateCharacter(_ character: CharacterVoice, to projectID: UUID) {
        guard let p = projects.firstIndex(where: {$0.id == projectID}),
              let i = projects[p].characters.firstIndex(where: {$0.id == character.id}) else { return }
        projects[p].characters[i] = character
        persist()
    }

    func storeAudio(data: Data, fileExtension: String, projectID: UUID) throws -> String {
        let name = UUID().uuidString + "." + fileExtension
        try data.write(to: projectFolder(projectID).appendingPathComponent(name), options: .atomic)
        return name
    }

    func audioURL(name: String, projectID: UUID) -> URL {
        projectFolder(projectID).appendingPathComponent(name)
    }

    private func projectFolder(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([MangaProject].self, from: data) else { return }
        projects = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
