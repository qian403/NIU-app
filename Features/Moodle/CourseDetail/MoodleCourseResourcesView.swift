import Combine
import SwiftUI

@MainActor
final class MoodleResourcesViewModel: ObservableObject {
    @Published private(set) var sections: [MoodleCourseSection] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let repository: any MoodleResourcesRepositoryProtocol
    private var hasLoaded = false

    init(repository: any MoodleResourcesRepositoryProtocol) {
        self.repository = repository
    }

    func load(courseId: Int, force: Bool = false) async {
        guard force || !hasLoaded else { return }
        isLoading = true
        errorMessage = nil
        do {
            sections = try await repository.fetchSections(courseId: courseId)
            hasLoaded = true
        } catch is CancellationError {
            isLoading = false
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct MoodleCourseResourcesView: View {
    let courseId: Int
    private let repository: any MoodleResourcesRepositoryProtocol
    @ObservedObject var viewModel: MoodleResourcesViewModel

    init(
        courseId: Int,
        viewModel: MoodleResourcesViewModel,
        repository: any MoodleResourcesRepositoryProtocol
    ) {
        self.courseId = courseId
        self.viewModel = viewModel
        self.repository = repository
    }

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.sections.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.errorMessage, viewModel.sections.isEmpty {
                ContentUnavailableView {
                    Label("資源載入失敗", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("重試") { Task { await viewModel.load(courseId: courseId, force: true) } }
                }
            } else if viewModel.sections.isEmpty {
                ScrollView {
                    ContentUnavailableView {
                        Label("目前沒有資源", systemImage: "folder")
                    } actions: {
                        Button("重新整理") {
                            Task { await viewModel.load(courseId: courseId, force: true) }
                        }
                    }
                    .frame(minHeight: 420)
                }
                .refreshable { await viewModel.load(courseId: courseId, force: true) }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let error = viewModel.errorMessage {
                            Label("更新失敗，以下為上次資料：\(error)", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(10)
                        }
                        ForEach(viewModel.sections) { section in
                            SectionView(section: section, courseId: courseId, repository: repository)
                        }
                    }
                    .padding(Theme.Spacing.medium)
                }
                .refreshable { await viewModel.load(courseId: courseId, force: true) }
            }
        }
        .background(Color(.systemGroupedBackground))
        .task { await viewModel.load(courseId: courseId) }
    }
}

// MARK: - Section View (Resources)

private struct SectionView: View {
    let section: MoodleCourseSection
    let courseId: Int
    let repository: any MoodleResourcesRepositoryProtocol

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            Text(section.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.03))

            // Modules
            ForEach(section.modules.filter { $0.modname != "label" }) { module in
                ModuleRow(courseId: courseId, module: module, repository: repository)
            }
        }
    }
}

private struct ModuleRow: View {
    let courseId: Int
    let module: MoodleModule
    let repository: any MoodleResourcesRepositoryProtocol

    var body: some View {
        Group {
            if let attendanceTarget = attendanceTarget {
                NavigationLink(
                    destination: MoodleAttendanceModuleDetailView(
                        module: module,
                        presetAttendanceId: attendanceTarget.attendanceId,
                        courseModuleId: attendanceTarget.courseModuleId
                    )
                ) {
                    moduleContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .buttonStyle(PlainButtonStyle())
            } else if module.modname == "assign" {
                NavigationLink(destination: MoodleModuleAssignmentView(courseId: courseId, module: module)) {
                    moduleContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .buttonStyle(PlainButtonStyle())
            } else if module.modname == "forum" {
                NavigationLink(destination: MoodleModuleForumView(module: module)) {
                    moduleContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .buttonStyle(PlainButtonStyle())
            } else if module.modname == "page", module.url != nil {
                NavigationLink(
                    destination: MoodlePageContentView(
                        courseId: courseId,
                        module: module,
                        repository: repository
                    )
                ) {
                    moduleContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .buttonStyle(PlainButtonStyle())
            } else if let file = preferredFileContent, let fileURL = tokenFileURL(for: file) {
                // Resource/file: view in-app with QuickLook
                NavigationLink(destination: MoodleFileViewer(fileName: file.filename ?? module.name, fileURL: fileURL)) {
                    moduleContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .buttonStyle(PlainButtonStyle())
            } else if let urlStr = browserTargetURL {
                // Other module types: open in WebView
                NavigationLink(destination: MoodleWebPageView(title: module.name, targetURL: urlStr)) {
                    moduleContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .buttonStyle(PlainButtonStyle())
            } else {
                moduleContent
            }
        }
        .overlay(
            Rectangle()
                .fill(Color.primary.opacity(0.05))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private var attendanceTarget: (attendanceId: Int?, courseModuleId: Int?)? {
        if module.modname == "attendance" {
            return (module.instance, module.id)
        }
        guard let url = module.url,
              let comps = URLComponents(string: url),
              comps.path.lowercased().contains("/mod/attendance/") else {
            return nil
        }
        let cmid = comps.queryItems?.first(where: { $0.name == "id" })?.value.flatMap(Int.init)
        return (nil, cmid)
    }

    /// Some locally-installed Moodle activities do not expose `url` through
    /// `core_course_get_contents`, even though their regular `view.php` page
    /// is available. IRS is one of those browser-only activities, so keep it
    /// actionable by reconstructing the canonical course-module URL.
    private var browserTargetURL: String? {
        if let url = module.url, !url.isEmpty {
            return url
        }
        guard module.modname.lowercased() == "irs" else { return nil }
        return "https://euni.niu.edu.tw/mod/irs/view.php?id=\(module.id)"
    }

    /// For resource modules, build a token-authenticated download URL
    private var preferredFileContent: MoodleContent? {
        module.contents?.first(where: { content in
            let type = content.type?.lowercased()
            return type == "file" || content.fileurl != nil
        })
    }

    private func tokenFileURL(for content: MoodleContent) -> URL? {
        guard module.modname == "resource" || module.modname == "folder",
              let rawURL = content.fileurl else { return nil }
        return repository.authenticatedFileURL(for: rawURL)
    }

    private var moduleContent: some View {
        HStack(spacing: 12) {
            Image(systemName: module.iconName)
                .font(.system(size: 16))
                .foregroundColor(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(module.name)
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(module.modname)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.001))
        .contentShape(Rectangle())
    }
}

private struct MoodleModuleAssignmentView: View {
    let courseId: Int
    let module: MoodleModule
    private let repository: any MoodleAssignmentsRepositoryProtocol

    @State private var assignment: MoodleAssignment?
    @State private var isLoading = true
    @State private var errorMessage: String?

    init(
        courseId: Int,
        module: MoodleModule,
        repository: (any MoodleAssignmentsRepositoryProtocol)? = nil
    ) {
        self.courseId = courseId
        self.module = module
        self.repository = repository ?? MoodleAssignmentsRepository()
    }

    var body: some View {
        Group {
            if isLoading {
                VStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if let assignment {
                MoodleAssignmentView(assignment: assignment)
            } else {
                VStack(spacing: 10) {
                    Spacer()
                    Text(errorMessage ?? "找不到此作業資料")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Spacer()
                }
            }
        }
        .navigationTitle(module.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadAssignment() }
    }

    private func loadAssignment() async {
        do {
            assignment = try await repository.findAssignment(courseId: courseId, module: module)
        } catch {
            errorMessage = "作業資料載入失敗：\(error.localizedDescription)"
        }
        isLoading = false
    }
}

private struct MoodleModuleForumView: View {
    let module: MoodleModule
    private let repository: any MoodleAnnouncementsRepositoryProtocol

    @State private var discussions: [MoodleDiscussion] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    init(
        module: MoodleModule,
        repository: (any MoodleAnnouncementsRepositoryProtocol)? = nil
    ) {
        self.module = module
        self.repository = repository ?? MoodleAnnouncementsRepository()
    }

    var body: some View {
        Group {
            if isLoading {
                VStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if let errorMessage {
                VStack(spacing: 10) {
                    Spacer()
                    Text(errorMessage)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Spacer()
                }
            } else if discussions.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Text("目前沒有公告內容")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(discussions) { discussion in
                            NavigationLink(destination: MoodleForumView(discussion: discussion)) {
                                MoodleDiscussionRow(discussion: discussion)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
                .background(Color(.systemBackground))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.systemBackground))
        .navigationTitle(module.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadDiscussions() }
    }

    private func loadDiscussions() async {
        guard let forumId = module.instance else {
            errorMessage = "無法識別公告版資料"
            isLoading = false
            return
        }
        do {
            let resp = try await repository.fetchDiscussions(forumId: forumId)
            discussions = resp.discussions.sorted { $0.timemodified > $1.timemodified }
        } catch {
            errorMessage = "公告資料載入失敗：\(error.localizedDescription)"
        }
        isLoading = false
    }
}

private struct MoodlePageContentView: View {
    let courseId: Int
    let module: MoodleModule
    private let repository: any MoodleResourcesRepositoryProtocol

    @State private var extractedText: String?
    @State private var imageURLs: [URL] = []
    @State private var errorMessage: String?

    init(
        courseId: Int,
        module: MoodleModule,
        repository: any MoodleResourcesRepositoryProtocol
    ) {
        self.courseId = courseId
        self.module = module
        self.repository = repository
    }

    var body: some View {
        ZStack {
            if hasDisplayContent {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let text = extractedText, !text.isEmpty {
                            Text(text)
                                .font(.system(size: 16))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }

                        ForEach(Array(imageURLs.enumerated()), id: \.offset) { pair in
                            let url = pair.element
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxWidth: .infinity)
                                        .cornerRadius(10)
                                case .failure:
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.primary.opacity(0.04))
                                        .frame(height: 180)
                                        .overlay(
                                            Text("圖片載入失敗")
                                                .font(.system(size: 13))
                                                .foregroundColor(.secondary)
                                        )
                                default:
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.primary.opacity(0.04))
                                        .frame(height: 180)
                                        .overlay(ProgressView())
                                }
                            }
                        }
                    }
                    .padding(Theme.Spacing.medium)
                }
                .background(Color(.systemBackground))
            } else if let error = errorMessage {
                VStack(spacing: 10) {
                    Spacer()
                    Text(error)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack {
                    Spacer()
                    ProgressView()
                    Text("正在載入...")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
        .navigationTitle(module.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadPageContent() }
    }

    private var hasDisplayContent: Bool {
        let hasText = !(extractedText?.isEmpty ?? true)
        return hasText || !imageURLs.isEmpty
    }

    private func loadPageContent() async {
        do {
            let pages = try await repository.fetchPages(courseId: courseId)
            let matched =
                pages.first(where: { page in page.id == module.instance }) ??
                pages.first(where: { page in page.coursemodule == module.id }) ??
                pages.first(where: { page in page.name == module.name })

            let html = (matched?.content ?? matched?.intro ?? "")
            let parsed = parseHTMLContent(html)
            extractedText = parsed.text
            imageURLs = parsed.images

            if !hasDisplayContent {
                errorMessage = "目前無法擷取可顯示內容"
            }
        } catch {
            errorMessage = "內容載入失敗，請稍後再試。"
            print("[Moodle] Page content load failed: \(error.localizedDescription)")
        }
    }

    private func parseHTMLContent(_ html: String) -> (text: String, images: [URL]) {
        let normalizedHTML = html.replacingOccurrences(of: "&amp;", with: "&")

        let imageRegex = try? NSRegularExpression(
            pattern: "<img[^>]*src=[\"']([^\"']+)[\"'][^>]*>",
            options: [.caseInsensitive]
        )
        let nsRange = NSRange(normalizedHTML.startIndex..<normalizedHTML.endIndex, in: normalizedHTML)
        let imageMatches = imageRegex?.matches(in: normalizedHTML, options: [], range: nsRange) ?? []

        let imageLinks: [URL] = imageMatches.compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: normalizedHTML) else { return nil }
            return tokenizedImageURL(from: String(normalizedHTML[range]))
        }

        var text = normalizedHTML
        text = text.replacingOccurrences(of: "<img[^>]*>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        return (text, imageLinks)
    }

    private func tokenizedImageURL(from rawPath: String) -> URL? {
        guard !rawPath.isEmpty else { return nil }

        let base = URL(string: "https://euni.niu.edu.tw")
        guard let absoluteURL = URL(string: rawPath, relativeTo: base)?.absoluteURL else { return nil }

        var components = URLComponents(url: absoluteURL, resolvingAgainstBaseURL: false)
        if let path = components?.path,
           path.contains("/pluginfile.php"),
           !path.contains("/webservice/pluginfile.php") {
            components?.path = path.replacingOccurrences(of: "/pluginfile.php", with: "/webservice/pluginfile.php")
        }

        guard let rewritten = components?.url?.absoluteString else { return nil }
        return repository.authenticatedFileURL(for: rewritten)
    }
}
