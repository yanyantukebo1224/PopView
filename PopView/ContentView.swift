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
    @State private var isScanningInbox = false
    @State private var inboxMessage: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if speechEngine.isStartupReady {
                mainInterface
            } else {
                ModelStartupView(speechEngine: speechEngine)
            }
        }
        .task {
            await speechEngine.installModelAtLaunch()
            if speechEngine.isStartupReady { await scanInbox() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && speechEngine.isStartupReady {
                Task { await scanInbox() }
            }
        }
    }

    @MainActor
    private func scanInbox() async {
        guard !isScanningInbox else { return }
        isScanningInbox = true
        defer { isScanningInbox = false }
        do {
            let count = try await store.importInboxItems()
            if count > 0 {
                inboxMessage = "\(count)ページを取り込みました。自動解析を開始します…"
                await analyzePendingPages()
                inboxMessage = "\(count)ページを取り込み、OCR・話者解析を完了しました。"
            } else {
                inboxMessage = "新しいファイルはありません。"
            }
        } catch {
            inboxMessage = "取り込みに失敗しました: " + error.localizedDescription
        }
    }

    @MainActor
    private func analyzePendingPages() async {
        let pending = store.projects.flatMap { project in
            project.pages.filter { $0.textRegions.isEmpty }.map { (project.id, $0) }
        }
        guard !pending.isEmpty else { return }

        var completed = 0
        for (projectID, page) in pending {
            guard let image = store.image(for: page, projectID: projectID) else { continue }
            let knownCharacters = store.projects.first(where: { $0.id == projectID })?.characters ?? []
            do {
                let result = try await MangaPageAnalysisService().analyze(
                    image: image,
                    knownCharacters: knownCharacters
                )
                for character in result.newCharacters {
                    store.addCharacter(character, to: projectID)
                }
                var updated = page
                updated.textRegions = result.regions
                store.updatePage(updated, projectID: projectID)
                completed += 1
                inboxMessage = "自動解析中… \(completed) / \(pending.count) ページ"
            } catch {
                completed += 1
                inboxMessage = "自動解析中… \(completed) / \(pending.count) ページ（\(error.localizedDescription)）"
            }
        }
    }

    private var mainInterface: some View {
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

                Section("ファイルアプリから自動取り込み") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("このiPhone内 > PopView > Import", systemImage: "folder.badge.plus")
                            .font(.subheadline.weight(.semibold))
                        Text("画像・PDF・ZIP・CBZ・RAR、または漫画フォルダをここに置いてください。PopView起動時やアプリに戻ったときに自動で読み込みます。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("取り込み済みファイルは「Imported」へ移動します。")
                            .font(.caption2).foregroundStyle(.secondary)
                        Button {
                            Task { await scanInbox() }
                        } label: {
                            Label(isScanningInbox ? "確認中…" : "Importフォルダを今すぐ確認",
                                  systemImage: "arrow.clockwise")
                        }
                        .disabled(isScanningInbox)
                        if let inboxMessage {
                            Text(inboxMessage).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
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
                    .onDelete { store.deleteProjects(at: $0) }
                }
            }
            .navigationTitle("PopView")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
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
    }
}

private struct ModelStartupView: View {
    @ObservedObject var speechEngine: LocalSpeechEngine
    @ObservedObject private var modelManager: LocalModelManager

    init(speechEngine: LocalSpeechEngine) {
        self.speechEngine = speechEngine
        self.modelManager = speechEngine.modelManager
    }

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 54, weight: .medium))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("PopView")
                    .font(.largeTitle.bold())
                Text("音声モデルを準備しています")
                    .font(.headline)
                Text("初回は約2 GBのモデルをダウンロードします。取得と検証が完了すると利用できます。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal)
            if modelManager.totalFiles > 0 {
                ProgressView(value: modelManager.progress)
                    .padding(.horizontal, 32)
                Text("ファイル \(modelManager.completedFiles) / \(modelManager.totalFiles)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            Text(modelManager.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            if let error = speechEngine.downloadError {
                VStack(spacing: 12) {
                    Text("モデルを取得できませんでした")
                        .font(.headline)
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                    Button {
                        Task { await speechEngine.installModelAtLaunch() }
                    } label: {
                        Label("再試行", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(speechEngine.isStartupAttempting)
                }
                .padding(.horizontal, 28)
            } else if speechEngine.isStartupAttempting {
                Text("アプリの利用開始前に、モデルの取得と整合性検証を行っています。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}

private struct ProjectView: View {
    let projectID: UUID
    @ObservedObject var store: LocalProjectStore
    @ObservedObject var speechEngine: LocalSpeechEngine
    @ObservedObject var modelManager: LocalModelManager
    @State private var selectedTab = 1

    private var project: MangaProject? { store.projects.first(where: { $0.id == projectID }) }

    var body: some View {
        TabView(selection: $selectedTab) {
            ProjectEditList(
                projectID: projectID,
                store: store,
                speechEngine: speechEngine,
                modelManager: modelManager
            )
            .tabItem { Label("編集モード", systemImage: "slider.horizontal.3") }
            .tag(0)

            MangaReaderView(projectID: projectID, store: store)
                .tabItem { Label("リードモード", systemImage: "book.pages") }
                .tag(1)
        }
        .navigationTitle(project?.title ?? "作品")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ProjectEditList: View {
    let projectID: UUID
    @ObservedObject var store: LocalProjectStore
    @ObservedObject var speechEngine: LocalSpeechEngine
    @ObservedObject var modelManager: LocalModelManager

    private var project: MangaProject? { store.projects.first(where: { $0.id == projectID }) }

    var body: some View {
        List {
            Section("ページ・解析結果") {
                if let project, project.pages.isEmpty {
                    ContentUnavailableView("ページがありません", systemImage: "doc.text.image")
                }
                if let project {
                    ForEach(Array(project.pages.enumerated()), id: \.element.id) { index, page in
                        NavigationLink {
                            PageEditorView(
                                projectID: projectID,
                                pageID: page.id,
                                store: store,
                                speechEngine: speechEngine,
                                modelManager: modelManager
                            )
                        } label: {
                            HStack(spacing: 12) {
                                if let image = store.image(for: page, projectID: projectID) {
                                    Image(uiImage: image).resizable().scaledToFill()
                                        .frame(width: 58, height: 76).clipped().cornerRadius(5)
                                } else {
                                    Image(systemName: "doc").frame(width: 58, height: 76)
                                }
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(page.title).font(.headline)
                                    Text("ページ \(index + 1) ・ \(page.textRegions.count) セリフ")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if page.textRegions.isEmpty {
                                        Label("未解析", systemImage: "circle.dashed")
                                            .font(.caption2).foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                    }
                    .onDelete { store.deletePages(at: $0, from: projectID) }
                }
            }

            Section("音声モデル") {
                Label(speechEngine.modelStatus, systemImage: modelManager.isInstalled ? "checkmark.circle.fill" : "arrow.down.circle")
                    .font(.caption)
                if modelManager.totalFiles > 0 {
                    ProgressView()
                    Text("取得済み \(modelManager.completedFiles)/\(modelManager.totalFiles) ファイル")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let error = speechEngine.downloadError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Text("音声生成はモデル取得後、端末内で動作します。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
    }
}

private struct MangaReaderView: View {
    let projectID: UUID
    @ObservedObject var store: LocalProjectStore
    @State private var selectedPageIndex = 0
    @State private var audioPlayer: AVAudioPlayer?
    @State private var playingRegionID: UUID?

    private var project: MangaProject? { store.projects.first(where: { $0.id == projectID }) }

    var body: some View {
        Group {
            if let project, !project.pages.isEmpty {
                VStack(spacing: 0) {
                    TabView(selection: $selectedPageIndex) {
                        ForEach(Array(project.pages.enumerated()), id: \.element.id) { index, page in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 14) {
                                    if let image = store.image(for: page, projectID: projectID) {
                                        Image(uiImage: image)
                                            .resizable()
                                            .scaledToFit()
                                            .frame(maxWidth: .infinity)
                                            .padding(.horizontal, 8)
                                    } else {
                                        ContentUnavailableView("ページ画像を開けません", systemImage: "photo")
                                    }

                                    if !page.textRegions.isEmpty {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text("セリフ").font(.headline)
                                            ForEach(page.textRegions.sorted {
                                                ($0.readingOrder ?? 0) < ($1.readingOrder ?? 0)
                                            }) { region in
                                                HStack(alignment: .top, spacing: 10) {
                                                    VStack(alignment: .leading, spacing: 3) {
                                                        Text(region.text)
                                                            .font(.body)
                                                        if let name = region.speakerID.flatMap({ id in
                                                            project.characters.first(where: { $0.id == id })?.name
                                                        }) {
                                                            Text(name).font(.caption2).foregroundStyle(.secondary)
                                                        }
                                                    }
                                                    Spacer(minLength: 4)
                                                    if let fileName = region.audioFileName {
                                                        Button {
                                                            play(fileName, regionID: region.id)
                                                        } label: {
                                                            Image(systemName: playingRegionID == region.id ? "speaker.wave.2.fill" : "play.fill")
                                                        }
                                                        .buttonStyle(.borderless)
                                                    }
                                                }
                                                .padding(10)
                                                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                                            }
                                        }
                                        .padding(.horizontal)
                                        .padding(.bottom, 12)
                                    }
                                }
                            }
                            .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))

                    HStack {
                        Button {
                            selectedPageIndex = max(0, selectedPageIndex - 1)
                        } label: {
                            Label("前へ", systemImage: "chevron.left")
                        }
                        .disabled(selectedPageIndex == 0)
                        Spacer()
                        Text("\(selectedPageIndex + 1) / \(project.pages.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            selectedPageIndex = min(project.pages.count - 1, selectedPageIndex + 1)
                        } label: {
                            Label("次へ", systemImage: "chevron.right")
                        }
                        .disabled(selectedPageIndex >= project.pages.count - 1)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .background(.bar)
                }
            } else {
                ContentUnavailableView("読むページがありません", systemImage: "book")
            }
        }
        .onChange(of: project?.pages.count ?? 0) { _, count in
            selectedPageIndex = min(selectedPageIndex, max(0, count - 1))
        }
    }

    private func play(_ fileName: String, regionID: UUID) {
        do {
            let player = try AVAudioPlayer(contentsOf: store.audioURL(name: fileName, projectID: projectID))
            audioPlayer = player
            playingRegionID = regionID
            player.play()
        } catch {
            playingRegionID = nil
        }
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
                        if let region,
                           let index = page.textRegions.firstIndex(where: { $0.id == region.id }) {
                            var updated = page
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

        do {
            let knownCharacters = project?.characters ?? []
            let result = try await MangaPageAnalysisService().analyze(
                image: image,
                knownCharacters: knownCharacters
            )
            for character in result.newCharacters {
                store.addCharacter(character, to: projectID)
            }
            var updated = page
            updated.textRegions = result.regions
            store.updatePage(updated, projectID: projectID)
            analysisNotice = result.notice + " 座標と話者は編集モードで修正できます。"
        } catch {
            errorMessage = error.localizedDescription
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
