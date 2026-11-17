import Foundation
import UIKit

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
        projects[index].pages.append(MangaPage(title: url.deletingPathExtension().lastPathComponent, imageFileName: destination.lastPathComponent))
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
