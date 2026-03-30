import SwiftUI
import WebKit

struct AcademicCalendarPDFView: View {
    @State private var documents = AcademicCalendarPDFDocument.documents
    @State private var selectedDocument = AcademicCalendarPDFDocument.defaultDocument
    @State private var webLoadError: String?
    @State private var autoFallbackAttempted: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            filterBar

            Divider()

            if let webLoadError {
                pdfErrorView(message: webLoadError)
            } else {
                AcademicCalendarPDFWebView(
                    urlString: selectedDocument.url,
                    onLoadError: { message in
                        handleWebLoadError(message)
                    }
                )
                .background(Color(.systemBackground))
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle("學年度行事曆")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadDocumentsFromOverview()
        }
        .onChange(of: selectedDocument.id) { _, _ in
            webLoadError = nil
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: openInBrowser) {
                    Image(systemName: "safari")
                }
            }
        }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("年度")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)

                Picker("年度", selection: selectedYearBinding) {
                    ForEach(availableYears, id: \.self) { year in
                        Text(year).tag(year)
                    }
                }
                .pickerStyle(.menu)
                .tint(.primary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(availableDocumentsForSelectedYear) { document in
                        Button {
                            selectedDocument = document
                        } label: {
                            Text(document.category)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(selectedDocument.id == document.id ? Color(.systemBackground) : .primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule()
                                        .fill(selectedDocument.id == document.id ? Color.primary : Color.primary.opacity(0.12))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Text(selectedDocument.title)
                .font(.system(size: 13, weight: .light))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.medium)
    }

    private var selectedYearBinding: Binding<String> {
        Binding(
            get: { selectedDocument.year },
            set: { newYear in
                if let first = documents.first(where: { $0.year == newYear }) {
                    selectedDocument = first
                }
            }
        )
    }

    private var availableYears: [String] {
        Array(Set(documents.map(\.year))).sorted(by: >)
    }

    private var availableDocumentsForSelectedYear: [AcademicCalendarPDFDocument] {
        documents.filter { $0.year == selectedDocument.year }
    }

    private func openInBrowser() {
        guard let url = URL(string: selectedDocument.url) else { return }
        UIApplication.shared.open(url)
    }

    private func handleWebLoadError(_ message: String?) {
        guard let message else {
            webLoadError = nil
            return
        }

        let failedID = selectedDocument.id
        let fallbackCandidates = availableDocumentsForSelectedYear.filter { $0.id != failedID }

        if !autoFallbackAttempted.contains(failedID),
           let fallback = fallbackCandidates.first {
            autoFallbackAttempted.insert(failedID)
            selectedDocument = fallback
            webLoadError = nil
            return
        }

        webLoadError = message
    }

    private func loadDocumentsFromOverview() async {
        guard let url = URL(string: AcademicCalendarPDFDocument.overviewURL) else { return }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return
            }

            let html = String(decoding: data, as: UTF8.self)
            let fetched = AcademicCalendarPDFDocument.parseFromOverviewHTML(html, baseURL: url)
            guard !fetched.isEmpty else { return }

            let selectedYear = selectedDocument.year
            let selectedCategory = selectedDocument.category

            documents = fetched

            if let sameSelection = fetched.first(where: { $0.year == selectedYear && $0.category == selectedCategory }) {
                selectedDocument = sameSelection
            } else if let sameYearFirst = fetched.first(where: { $0.year == selectedYear }) {
                selectedDocument = sameYearFirst
            } else {
                selectedDocument = AcademicCalendarPDFDocument.preferredDefault(in: fetched) ?? fetched[0]
            }
        } catch {
            // 忽略動態抓取失敗，保留靜態清單作為 fallback。
            return
        }
    }

    private func pdfErrorView(message: String) -> some View {
        VStack(spacing: Theme.Spacing.medium) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(.orange)

            Text("目前無法載入此 PDF")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.primary)

            Text(message)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.large)

            HStack(spacing: 12) {
                Button("重新載入") {
                    webLoadError = nil
                }
                .buttonStyle(.bordered)

                Button("用 Safari 開啟") {
                    openInBrowser()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Theme.Spacing.large)
        .background(Color(.systemBackground))
    }
}

private struct AcademicCalendarPDFDocument: Identifiable, Equatable {
    let id: String
    let year: String
    let category: String
    let title: String
    let url: String

    static let overviewURL = "https://academic.niu.edu.tw/p/412-1003-5555.php"

    static let documents: [AcademicCalendarPDFDocument] = [
        .init(
            id: "114-main",
            year: "114",
            category: "學年度",
            title: "114學年度行事曆",
            url: "https://academic.niu.edu.tw/var/file/3/1003/img/1202/391251909.pdf"
        ),
        .init(
            id: "114-winter",
            year: "114",
            category: "寒假",
            title: "114學年度寒假行事曆",
            url: "https://academic.niu.edu.tw/var/file/3/1003/img/1202/121201515.pdf"
        ),
        .init(
            id: "113-main",
            year: "113",
            category: "學年度",
            title: "113學年度行事曆",
            url: "https://academic.niu.edu.tw/var/file/3/1003/img/1202/896509134.pdf"
        ),
        .init(
            id: "113-winter",
            year: "113",
            category: "寒假",
            title: "113學年度寒假行事曆",
            url: "https://academic.niu.edu.tw/var/file/3/1003/img/1202/231219790.pdf"
        ),
        .init(
            id: "113-summer",
            year: "113",
            category: "暑假",
            title: "113學年度暑假行事曆",
            url: "https://academic.niu.edu.tw/var/file/3/1003/img/1202/186790610.pdf"
        )
    ]

    static let availableYears: [String] = Array(Set(documents.map(\.year))).sorted(by: >)
    static let defaultDocument = documents.first { $0.id == "114-main" } ?? documents[0]

    static func preferredDefault(in list: [AcademicCalendarPDFDocument]) -> AcademicCalendarPDFDocument? {
        let sorted = list.sorted(by: sortRule)
        return sorted.first { $0.category == "學年度" } ?? sorted.first
    }

    static func parseFromOverviewHTML(_ html: String, baseURL: URL) -> [AcademicCalendarPDFDocument] {
        let pattern = #"<a[^>]+href=\"([^\"]+\.pdf)\"[^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }

        let nsHTML = html as NSString
        let range = NSRange(location: 0, length: nsHTML.length)
        let matches = regex.matches(in: html, options: [], range: range)

        var parsed: [AcademicCalendarPDFDocument] = []
        var seenURLs: Set<String> = []

        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }

            let rawHref = nsHTML.substring(with: match.range(at: 1))
            let anchorHTML = nsHTML.substring(with: match.range(at: 2))
            let title = normalizeAnchorText(anchorHTML)

            guard title.contains("學年度") else { continue }
            guard let year = extractAcademicYear(from: title) else { continue }

            let category: String = if title.contains("寒假") {
                "寒假"
            } else if title.contains("暑假") {
                "暑假"
            } else {
                "學年度"
            }

            let resolvedURL = URL(string: rawHref, relativeTo: baseURL)?.absoluteURL.absoluteString ?? rawHref
            let normalizedURL = resolvedURL.replacingOccurrences(of: "http://", with: "https://")

            guard !seenURLs.contains(normalizedURL) else { continue }
            seenURLs.insert(normalizedURL)

            let id = "\(year)-\(category)-\(abs(normalizedURL.hashValue))"
            parsed.append(
                .init(
                    id: id,
                    year: year,
                    category: category,
                    title: title,
                    url: normalizedURL
                )
            )
        }

        return parsed.sorted(by: sortRule)
    }

    private static func extractAcademicYear(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d{3})\s*學年度"#) else {
            return nil
        }

        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2 else {
            return nil
        }

        return nsText.substring(with: match.range(at: 1))
    }

    private static func normalizeAnchorText(_ html: String) -> String {
        var text = html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "🔔", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")

        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func sortRule(_ lhs: AcademicCalendarPDFDocument, _ rhs: AcademicCalendarPDFDocument) -> Bool {
        let leftYear = Int(lhs.year) ?? 0
        let rightYear = Int(rhs.year) ?? 0
        if leftYear != rightYear {
            return leftYear > rightYear
        }

        let order: [String: Int] = ["學年度": 0, "寒假": 1, "暑假": 2]
        let leftOrder = order[lhs.category] ?? 99
        let rightOrder = order[rhs.category] ?? 99
        if leftOrder != rightOrder {
            return leftOrder < rightOrder
        }

        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
}

private struct AcademicCalendarPDFWebView: UIViewRepresentable {
    let urlString: String
    let onLoadError: (String?) -> Void

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onLoadError: (String?) -> Void

        init(onLoadError: @escaping (String?) -> Void) {
            self.onLoadError = onLoadError
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            defer { decisionHandler(.allow) }

            guard let response = navigationResponse.response as? HTTPURLResponse else {
                return
            }

            let statusCode = response.statusCode
            let mimeType = response.mimeType?.lowercased() ?? ""

            if statusCode >= 300 {
                onLoadError("伺服器回應狀態：\(statusCode)。可能是校方站台限制直接載入，請改用 Safari 開啟。")
                return
            }

            if mimeType.contains("text/plain") {
                onLoadError("伺服器未回傳 PDF 內容（\(mimeType)），請改用 Safari 開啟或稍後重試。")
                return
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoadError(nil)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            onLoadError("載入失敗：\(error.localizedDescription)")
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            onLoadError("載入失敗：\(error.localizedDescription)")
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoadError: onLoadError)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard let url = URL(string: urlString) else { return }
        if uiView.url?.absoluteString != url.absoluteString {
            var request = URLRequest(url: url)
            request.setValue("https://academic.niu.edu.tw/", forHTTPHeaderField: "Referer")
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue("application/pdf,text/html;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            uiView.load(request)
        }
    }
}
