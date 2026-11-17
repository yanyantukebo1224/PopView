import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ContentView: View {
    @State private var isImporterPresented = false
    @State private var selectedImage: UIImage?
    @State private var selectedFileName: String?
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header
                        if let selectedImage {
                            importedImageCard(selectedImage)
                        } else {
                            importCard
                        }
                        featureSection
                    }
                    .padding(20)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("PopView").font(.headline.weight(.bold))
                }
            }
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: [.image, .pdf],
                allowsMultipleSelection: false,
                onCompletion: handleImport
            )
            .alert("読み込みエラー", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
        }
        .tint(.primary)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("漫画を、声と動きで楽しもう。")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
            Text("作品を端末に読み込み、キャラクターの声と演出を設定できます。")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.top, 12)
    }

    private var importCard: some View {
        Button { isImporterPresented = true } label: {
            VStack(spacing: 16) {
                Image(systemName: "book.closed")
                    .font(.system(size: 42, weight: .light))
                VStack(spacing: 6) {
                    Text("漫画を読み込む").font(.title3.weight(.semibold))
                    Text("画像・PDFに対応").font(.subheadline).foregroundStyle(.secondary)
                }
                Label("ファイルを選択", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .background(.primary, in: Capsule())
                    .foregroundStyle(Color(uiColor: .systemBackground))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 42)
            .background(.background, in: RoundedRectangle(cornerRadius: 24))
            .overlay {
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(.secondary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("端末内の画像またはPDFを選択します")
    }

    private func importedImageCard(_ image: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("読み込み済み", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("変更") { isImporterPresented = true }
                    .font(.subheadline.weight(.semibold))
            }
            Image(uiImage: image)
                .resizable().scaledToFit().frame(maxHeight: 440)
                .frame(maxWidth: .infinity)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            if let selectedFileName {
                Text(selectedFileName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text("次のステップ：吹き出し・セリフの認識")
                .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
        }
        .padding(16).background(.background, in: RoundedRectangle(cornerRadius: 22))
    }

    private var featureSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("PopViewでできること").font(.headline)
            featureRow("text.bubble", title: "吹き出し認識", detail: "セリフと話者を整理")
            featureRow("waveform", title: "キャラクターボイス", detail: "端末内の音声合成を目指す")
            featureRow("captions.bubble", title: "カラオケ字幕", detail: "音声に合わせて文字をハイライト")
            featureRow("square.3.layers.3d", title: "2.5Dモーション", detail: "元の漫画絵を活かして奥行きと動きを追加")
        }
        .padding(18).background(.background, in: RoundedRectangle(cornerRadius: 22))
    }

    private func featureRow(_ symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title3).frame(width: 34).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                selectedFileName = url.lastPathComponent
                if let image = UIImage(data: data) {
                    selectedImage = image
                } else if url.pathExtension.lowercased() == "pdf" {
                    importError = "PDFのページ表示は次の開発段階で追加します。現在は画像ファイルを表示できます。"
                } else {
                    importError = "このファイル形式はまだ表示できません。"
                }
            } catch {
                importError = error.localizedDescription
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }
}
