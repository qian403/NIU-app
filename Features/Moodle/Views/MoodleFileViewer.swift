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
    @State private var isLoading = true
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
                        .foregroundColor(.black.opacity(0.3))
                    Text(error)
                        .font(.system(size: 14))
                        .foregroundColor(.black.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Button("重試") { download() }
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
                        .foregroundColor(.black.opacity(0.4))
                        .padding(.top, 8)
                    Spacer()
                }
            }
        }
        .background(Color.white)
        .navigationTitle(fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if let localURL = localFileURL {
                    ShareLink(item: localURL)
                }
            }
        }
        .onAppear { download() }
    }

    private func download() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let (tempURL, response) = try await URLSession.shared.download(from: fileURL)
                let httpResponse = response as? HTTPURLResponse
                guard httpResponse == nil || (200...299).contains(httpResponse!.statusCode) else {
                    throw URLError(.badServerResponse)
                }

                // Move to a named file so QuickLook can identify the type
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("MoodleFiles", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = dir.appendingPathComponent(fileName)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tempURL, to: dest)

                await MainActor.run {
                    localFileURL = dest
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "下載失敗：\(error.localizedDescription)"
                    isLoading = false
                }
            }
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
