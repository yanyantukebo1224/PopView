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
        loadIndex()
    }

    func createProject(title: String) -> MangaProject {
        let project = MangaProject(title: title)
        projects.insert(project, at: 0)
        persist()
        return project
    }

    func addImportedItems(urls: [URL], to projectID: UUID) async throws -> Int {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else { return 0 }
        let destination = projectFolder(projectID)
        let prepared = try await Task.detached(priority: .userInitiated) {
            try MangaImportService.prepare(urls: urls, destination: destination)
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
