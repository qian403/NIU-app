import SwiftUI
import QuickLook
import WebKit

/// In-app file viewer for Moodle resources.
/// Downloads the file using token auth, then displays it with QuickLook
/// (PDF, images, Office docs, etc.) or WKWebView as fallback.
struct MoodleFileViewer: View {
    let fileName: String
    let fileURL: URL

    @State private var localFileURL: URL?
    @State private var downloadAttempt = 0
    @State private var downloadDirectory: URL?
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            if let localURL = localFileURL {
                QuickLookPreview(url: localURL)
                    .ignoresSafeArea(edges: .bottom)
            } else if let error = errorMessage {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36, weight: .light))
                        .foregroundColor(.secondary)
                    Text(error)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Button("重試") { downloadAttempt += 1 }
                        .font(.system(size: 14, weight: .medium))
                        .padding(.top, 4)
                    Spacer()
                }
            } else {
                VStack {
                    Spacer()
                    ProgressView()
                    Text("下載中...")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                    Spacer()
                }
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle(fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if let localURL = localFileURL {
                    ShareLink(item: localURL)
                }
            }
        }
        .task(id: downloadAttempt) { await download() }
        .onDisappear {
            if let downloadDirectory { try? FileManager.default.removeItem(at: downloadDirectory) }
            downloadDirectory = nil
            localFileURL = nil
        }
    }

    private func download() async {
        guard localFileURL == nil else { return }
        errorMessage = nil
        do {
            let (tempURL, response) = try await URLSession.shared.download(from: fileURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            try Task.checkCancellation()
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            // Each viewer owns its files; identical attachment names cannot collide.
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("MoodleFiles", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            do {
                let name = URL(fileURLWithPath: fileName).lastPathComponent
                let dest = dir.appendingPathComponent(name.isEmpty ? "attachment" : name)
                try FileManager.default.moveItem(at: tempURL, to: dest)
                downloadDirectory = dir
                localFileURL = dest
            } catch {
                try? FileManager.default.removeItem(at: dir)
                throw error
            }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "下載失敗：\(error.localizedDescription)"
        }
    }

}

// MARK: - QuickLook wrapper

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as QLPreviewItem
        }
    }
}
