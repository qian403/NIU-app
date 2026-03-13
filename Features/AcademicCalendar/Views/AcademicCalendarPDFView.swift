import SwiftUI
import WebKit

struct AcademicCalendarPDFView: View {
    @State private var selectedDocument = AcademicCalendarPDFDocument.defaultDocument

    var body: some View {
        VStack(spacing: 0) {
            filterBar

            Divider()

            AcademicCalendarPDFWebView(urlString: selectedDocument.url)
                .background(Color(.systemBackground))
        }
        .background(Color(.systemBackground))
        .navigationTitle("學年度行事曆")
        .navigationBarTitleDisplayMode(.inline)
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
                    ForEach(AcademicCalendarPDFDocument.availableYears, id: \.self) { year in
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
                                .foregroundColor(selectedDocument.id == document.id ? .white : .primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule()
                                        .fill(selectedDocument.id == document.id ? Color.primary : Color.primary.opacity(0.08))
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
                if let first = AcademicCalendarPDFDocument.documents.first(where: { $0.year == newYear }) {
                    selectedDocument = first
                }
            }
        )
    }

    private var availableDocumentsForSelectedYear: [AcademicCalendarPDFDocument] {
        AcademicCalendarPDFDocument.documents.filter { $0.year == selectedDocument.year }
    }

    private func openInBrowser() {
        guard let url = URL(string: selectedDocument.url) else { return }
        UIApplication.shared.open(url)
    }
}

private struct AcademicCalendarPDFDocument: Identifiable, Equatable {
    let id: String
    let year: String
    let category: String
    let title: String
    let url: String

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
}

private struct AcademicCalendarPDFWebView: UIViewRepresentable {
    let urlString: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard let url = URL(string: urlString) else { return }
        if uiView.url?.absoluteString != url.absoluteString {
            uiView.load(URLRequest(url: url))
        }
    }
}
