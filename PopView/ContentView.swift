import SwiftUI
import UniformTypeIdentifiers
import UIKit
import PDFKit
import AVFoundation

struct ContentView: View {
    @StateObject private var store = LocalProjectStore()
    @StateObject private var speechEngine = LocalSpeechEngine()
    @State private var selectedProjectID: UUID?
    @State private var showingImport = false
    @State private var showingNewProject = false
    @State private var newTitle = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("漫画を、声と動きで楽しもう。")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("作品・キャラクター・音声を端末内で管理するモーションコミック制作ビューア。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }

                Section("ライブラリ") {
                    if store.projects.isEmpty {
                        ContentUnavailableView("作品がありません", systemImage: "books.vertical",
                            description: Text("画像・PDF・ZIP・RAR・フォルダをまとめて読み込めます。"))
                    }
                    ForEach(store.projects) { project in
                        NavigationLink {
                            ProjectView(projectID: project.id, store: store, speechEngine: speechEngine, modelManager: speechEngine.modelManager)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "book.closed")
                                    .font(.title2).frame(width: 42, height: 52)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(project.title).font(.headline)
                                    Text("\(project.pages.count) ページ・\(project.characters.count) キャラクター")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("PopView")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { newTitle = ""; showingNewProject = true } label: {
                        Label("新規作品", systemImage: "plus")
                    }
                }
            }
            .alert("新しい作品", isPresented: $showingNewProject) {
                TextField("作品名", text: $newTitle)
                Button("作成") {
                    let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty {
                        let project = store.createProject(title: title)
                        selectedProjectID = project.id
                    }
                }
                Button("キャンセル", role: .cancel) {}
            }
            .alert("エラー", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
        .task { await speechEngine.installModelAtLaunch() }
    }
}

private struct ProjectView: View {
    let projectID: UUID
    @ObservedObject var store: LocalProjectStore
    @ObservedObject var speechEngine: LocalSpeechEngine
    @ObservedObject var modelManager: LocalModelManager
    @State private var showingImporter = false
    @State private var errorMessage: String?
    @State private var selectedPageID: UUID?
    @State private var isImporting = false

    private var project: MangaProject? { store.projects.first(where: {$0.id == projectID}) }

    var body: some View {
        List {
            Section {
                Button { showingImporter = true } label: {
                    Label("漫画ファイル・ZIP・RAR・フォルダを追加", systemImage: "plus.rectangle.on.folder")
                }
            }
            Section("ページ") {
                if let project, project.pages.isEmpty {
                    ContentUnavailableView("ページがありません", systemImage: "doc.text.image")
                }
                if let project {
                    ForEach(Array(project.pages.enumerated()), id: \.element.id) { index, page in
                        NavigationLink {
                            PageEditorView(projectID: projectID, pageID: page.id, store: store, speechEngine: speechEngine, modelManager: modelManager)
                        } label: {
                            HStack {
                                if let image = store.image(for: page, projectID: projectID) {
                                    Image(uiImage: image).resizable().scaledToFill()
                                        .frame(width: 52, height: 68).clipped().cornerRadius(5)
                                } else {
                                    Image(systemName: "doc").frame(width: 52, height: 68)
                                }
                                VStack(alignment: .leading) {
                                    Text(page.title)
                                    Text("ページ \(index + 1) ・ \(page.textRegions.count) セリフ")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            Section("音声モデル") {
                Label(speechEngine.modelStatus, systemImage: modelManager.isInstalled ? "checkmark.circle.fill" : "arrow.down.circle")
                    .font(.caption)
                if modelManager.totalFiles > 0 {
                    ProgressView()
                    Text("取得済み \(modelManager.completedFiles)/\(modelManager.totalFiles) ファイル（ファイル単位の検証中）")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let error = speechEngine.downloadError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Text("初回起動時にIrodori-TTS Core MLモデルを取得します。取得後の音声生成は端末内で動作します。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(project?.title ?? "作品")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [
                        .image, .pdf, .zip, .folder,
                        UTType(filenameExtension: "cbz") ?? .zip,
                        UTType(filenameExtension: "rar") ?? .archive
                      ],
                      allowsMultipleSelection: true) { result in
            do {
                let urls = try result.get()
                guard !urls.isEmpty else { return }
                isImporting = true
                Task {
                    defer { isImporting = false }
                    do {
                        let count = try await store.addImportedItems(urls: urls, to: projectID)
                        if count == 0 { errorMessage = "読み込めるページがありませんでした。" }
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            } catch { errorMessage = error.localizedDescription }
        }
        .overlay {
            if isImporting {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("漫画ファイルを解析・取り込み中…").font(.headline)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .alert("読み込みエラー", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
}

private struct PageEditorView: View {
    let projectID: UUID
    let pageID: UUID
    @ObservedObject var store: LocalProjectStore
    @ObservedObject var speechEngine: LocalSpeechEngine
    @ObservedObject var modelManager: LocalModelManager
    @State private var isAnalyzing = false
    @State private var errorMessage: String?
    @State private var showingCharacter = false
    @State private var characterName = ""
    @State private var characterVoiceDescription = ""
    @State private var activeRegionID: UUID?
    @State private var selectedAudioRegion: SpeechRegion?
    @State private var activeWords: [WordTiming] = []
    @State private var showingAudioImporter = false
    @State private var showingReferenceImporter = false
    @State private var selectedCharacterID: UUID?
    @State private var generatingRegionID: UUID?
    @State private var analysisNotice: String?
    @StateObject private var playback = KaraokePlaybackController()

    private var project: MangaProject? { store.projects.first(where: {$0.id == projectID}) }
    private var page: MangaPage? { project?.pages.first(where: {$0.id == pageID}) }

    var body: some View {
        Group {
            if let page, let image = store.image(for: page, projectID: projectID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ZStack(alignment: .topLeading) {
                            Image(uiImage: image).resizable().scaledToFit()
                            GeometryReader { proxy in
                                ForEach(page.textRegions) { region in
                                    let r = region.box.cgRect
                                    RoundedRectangle(cornerRadius: 5)
                                        .stroke(region.id == playbackRegionID ? .orange : .blue, lineWidth: 2)
                                        .background(.blue.opacity(0.08))
                                        .frame(width: r.width * proxy.size.width, height: r.height * proxy.size.height)
                                        .position(x: (r.midX) * proxy.size.width,
                                                  y: (1 - r.midY) * proxy.size.height)
                                }
                            }
                        }
                        HStack {
                            Button { Task { await analyze(image, page: page) } } label: {
                                Label(isAnalyzing ? "解析中…" : "AI画像解析", systemImage: "sparkles")
                            }
                            .disabled(isAnalyzing)
                            Spacer()
                            Button { showingCharacter = true } label: {
                                Label("キャラ追加", systemImage: "person.badge.plus")
                            }
                        }
                        if let analysisNotice {
                            Text(analysisNotice)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !page.textRegions.isEmpty {
                            karaokeControls(page: page)
                            Text("認識したセリフ").font(.headline)
                            ForEach(page.textRegions) { region in
                                regionEditor(region, page: page)
                            }
                        }
                    }
                    .padding()
                }
            } else {
                ContentUnavailableView("ページを開けません", systemImage: "photo")
            }
        }
        .navigationTitle(page?.title ?? "ページ")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingCharacter) {
            NavigationStack {
                Form {
                    TextField("キャラクター名", text: $characterName)
                    TextField("声・話し方の指示（任意）", text: $characterVoiceDescription, axis: .vertical)
                    Section {
                        Text("キャラクターごとに使用許可のある参照音声を登録すると、その声を使ってセリフを生成できます。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("キャラクター追加")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("閉じる") { showingCharacter = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("追加") {
                            let name = characterName.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !name.isEmpty {
                                var character = CharacterVoice(name: name)
                                character.voiceDescription = characterVoiceDescription
                                store.addCharacter(character, to: projectID)
                            }
                            characterName = ""; characterVoiceDescription = ""; showingCharacter = false
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .fileImporter(isPresented: $showingReferenceImporter, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first, let selectedCharacterID,
                      var current = project?.characters.first(where: { $0.id == selectedCharacterID }) else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                let name = try store.storeAudio(data: data, fileExtension: url.pathExtension.isEmpty ? "m4a" : url.pathExtension, projectID: projectID)
                current.referenceAudioFileName = name
                store.updateCharacter(current, to: projectID)
            } catch { errorMessage = error.localizedDescription }
        }
        .fileImporter(isPresented: $showingAudioImporter, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first, let page else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                let name = try store.storeAudio(data: data, fileExtension: url.pathExtension.isEmpty ? "m4a" : url.pathExtension, projectID: projectID)
                let localURL = store.audioURL(name: name, projectID: projectID)
                let asset = AVURLAsset(url: localURL)
                Task {
                    do {
                        let loadedDuration = try await asset.load(.duration)
                        let duration = loadedDuration.seconds
                        let region = selectedAudioRegion
                        let words = region.map { SpeechTimingEstimator.estimate(text: $0.text, duration: duration) } ?? []
                        if var updated = page, let region,
                           let index = updated.textRegions.firstIndex(where: { $0.id == region.id }) {
                            updated.textRegions[index].audioFileName = name
                            updated.textRegions[index].wordTimings = words
                            store.updatePage(updated, projectID: projectID)
                        }
                        try playback.load(url: localURL, timings: words)
                        activeWords = words
                        activeRegionID = region?.id
                        playback.play()
                    } catch { errorMessage = error.localizedDescription }
                }
            } catch { errorMessage = error.localizedDescription }
        }
        .alert("エラー", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var playbackRegionID: UUID? { playback.isPlaying ? activeRegionID : nil }

    private func analyze(_ image: UIImage, page: MangaPage) async {
        isAnalyzing = true
        analysisNotice = nil
        defer { isAnalyzing = false }

        // Primary path: analyze the page pixels directly with Apple's on-device
        // multimodal Foundation Model. This path does not run a separate OCR pass.
        do {
            let result = try await FoundationModelsMangaAnalyzer().analyze(image: image)
            var speakerIDs: [String: UUID] = [:]

            for speaker in result.speakers {
                if let existing = store.projects.first(where: { $0.id == projectID })?
                    .characters.first(where: { $0.name == speaker.name }) {
                    speakerIDs[speaker.key] = existing.id
                } else {
                    var character = CharacterVoice(name: speaker.name)
                    character.visualDescription = speaker.appearance
                    store.addCharacter(character, to: projectID)
                    speakerIDs[speaker.key] = character.id
                }
            }

            let regions = result.dialogues
                .sorted { $0.readingOrder < $1.readingOrder }
                .compactMap { dialogue -> SpeechRegion? in
                    let x = min(max(dialogue.box.x, 0), 1)
                    let y = min(max(dialogue.box.y, 0), 1)
                    let width = min(max(dialogue.box.width, 0), 1 - x)
                    let height = min(max(dialogue.box.height, 0), 1 - y)
                    guard width > 0.005, height > 0.005,
                          !dialogue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return nil
                    }
                    // Foundation Models uses a top-left origin; stored page geometry
                    // follows Vision's normalized lower-left origin.
                    let rect = CGRect(x: x, y: 1 - y - height, width: width, height: height)
                    var region = SpeechRegion(
                        text: dialogue.text,
                        box: CGRectCodable(rect),
                        speakerID: dialogue.speakerKey.flatMap { speakerIDs[$0] },
                        confidence: 0.55
                    )
                    region.speakerLabel = dialogue.speakerKey
                    region.emotion = dialogue.emotion
                    region.actingDirection = dialogue.actingDirection
                    region.readingOrder = dialogue.readingOrder
                    return region
                }

            guard !regions.isEmpty else {
                throw FoundationModelsMangaAnalyzer.AnalysisError.emptyResult
            }
            var updated = page
            updated.textRegions = regions
            store.updatePage(updated, projectID: projectID)
            analysisNotice = "Apple Foundation Modelsで画像を直接解析しました。座標・話者・セリフは推定結果なので確認してください。"
            return
        } catch {
            // Fallback for older OS versions, unavailable Apple Intelligence,
            // or an image response that could not be parsed.
            let aiReason = error.localizedDescription
            do {
                let analyzer = MangaAnalyzer()
                let text = try await analyzer.recognizeText(in: image)
                let boxes = try await analyzer.detectBalloonCandidates(in: image)
                var regions = text.map { item in
                    SpeechRegion(text: item.text, box: CGRectCodable(item.box), confidence: item.confidence)
                }
                for index in regions.indices {
                    let center = regions[index].box.cgRect
                    if let candidate = boxes.filter({ $0.insetBy(dx: -0.025, dy: -0.025).contains(center) })
                        .min(by: { $0.width * $0.height < $1.width * $1.height }) {
                        regions[index].box = CGRectCodable(candidate)
                    }
                }
                var updated = page
                updated.textRegions = regions
                store.updatePage(updated, projectID: projectID)
                analysisNotice = "Foundation Modelsを利用できなかったため、Vision OCRに切り替えました。理由: \(aiReason)"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func regionEditor(_ region: SpeechRegion, page: MangaPage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let emotion = region.emotion {
                Text("感情: \(emotion)").font(.caption).foregroundStyle(.secondary)
            }
            if let actingDirection = region.actingDirection {
                Text("演技指示: \(actingDirection)").font(.caption).foregroundStyle(.secondary)
            }
            TextField("セリフ", text: Binding(
                get: { page.textRegions.first(where: {$0.id == region.id})?.text ?? region.text },
                set: { value in
                    var updated = page
                    if let i = updated.textRegions.firstIndex(where: {$0.id == region.id}) {
                        updated.textRegions[i].text = value
                        store.updatePage(updated, projectID: projectID)
                    }
                }
            ), axis: .vertical)
            HStack {
                Menu("話者：\(speakerName(region.speakerID))") {
                    Button("未設定") { assign(nil, to: region, page: page) }
                    ForEach(project?.characters ?? []) { character in
                        Button(character.name) { assign(character.id, to: region, page: page) }
                        Button("「\(character.name)」の参照音声を設定") {
                            selectedCharacterID = character.id
                            showingReferenceImporter = true
                        }
                    }
                }
                Spacer()
                Button {
                    Task { await generateSpeech(for: region, page: page) }
                } label: {
                    Label(generatingRegionID == region.id ? "生成中…" : "このセリフを音声生成",
                          systemImage: "waveform")
                }
                .font(.caption)
                .disabled(generatingRegionID != nil || modelManager.modelDirectory == nil)
                if let fileName = region.audioFileName {
                    Button {
                        let url = store.audioURL(name: fileName, projectID: projectID)
                        do {
                            try playback.load(url: url, timings: region.wordTimings)
                            activeWords = region.wordTimings
                            activeRegionID = region.id
                            playback.play()
                        } catch { errorMessage = error.localizedDescription }
                    } label: { Label("再生", systemImage: "play.fill") }
                    .font(.caption)
                }
                Button { selectedAudioRegion = region; showingAudioImporter = true } label: {
                    Label("音声ファイルを割り当て", systemImage: "folder")
                }
                .font(.caption2)
            }
        }
        .padding(12).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private func generateSpeech(for region: SpeechRegion, page: MangaPage) async {
        guard generatingRegionID == nil else { return }
        generatingRegionID = region.id
        defer { generatingRegionID = nil }
        do {
            let character = region.speakerID.flatMap { id in project?.characters.first(where: { $0.id == id }) }
            let referenceURL = character?.referenceAudioFileName.map { store.audioURL(name: $0, projectID: projectID) }
            let actingCaption = [
                character?.voiceDescription,
                region.emotion.map { "感情: " + $0 },
                region.actingDirection
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "。")
            let (generatedURL, result) = try await speechEngine.synthesize(
                region.text, referenceURL: referenceURL, caption: actingCaption
            )
            let data = try Data(contentsOf: generatedURL)
            try? FileManager.default.removeItem(at: generatedURL)
            let storedName = try store.storeAudio(data: data, fileExtension: "wav", projectID: projectID)
            let timings = SpeechTimingEstimator.estimate(text: region.text, duration: result.audioSeconds)
            var updated = page
            guard let index = updated.textRegions.firstIndex(where: { $0.id == region.id }) else { return }
            updated.textRegions[index].audioFileName = storedName
            updated.textRegions[index].wordTimings = timings
            store.updatePage(updated, projectID: projectID)
            let localURL = store.audioURL(name: storedName, projectID: projectID)
            try playback.load(url: localURL, timings: timings)
            activeWords = timings
            activeRegionID = region.id
            playback.play()
        } catch { errorMessage = error.localizedDescription }
    }

    private func speakerName(_ id: UUID?) -> String {
        guard let id, let character = project?.characters.first(where: {$0.id == id}) else { return "未設定" }
        return character.name
    }

    private func assign(_ id: UUID?, to region: SpeechRegion, page: MangaPage) {
        var updated = page
        guard let index = updated.textRegions.firstIndex(where: {$0.id == region.id}) else { return }
        updated.textRegions[index].speakerID = id
        store.updatePage(updated, projectID: projectID)
    }

    private func karaokeControls(page: MangaPage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("カラオケ再生").font(.headline)
                Spacer()
                Button { playback.pause() } label: { Image(systemName: "pause.fill") }
                Button { playback.play() } label: { Image(systemName: "play.fill") }
                Button { playback.stop() } label: { Image(systemName: "stop.fill") }
            }
            Text("現在の音声：\(playback.currentTime, format: .number.precision(.fractionLength(2))) 秒")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(activeWords) { word in
                        Text(word.text)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(playback.activeWordID == word.id ? .orange : .primary)
                            .background(playback.activeWordID == word.id ? Color.orange.opacity(0.18) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
            }
            Text("単語タイミングは現在、音声長からの仮推定です。TTSの音素タイムスタンプまたは強制アライメントに置き換えます。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func estimatedTimings(text: String, duration: TimeInterval) -> [WordTiming] {
        SpeechTimingEstimator.estimate(text: text, duration: duration)
    }
}
