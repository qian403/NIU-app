import SwiftUI

struct MoodleCourseDetailView: View {
    let course: MoodleCourse
    @StateObject private var viewModel: MoodleCourseDetailViewModel
    
    init(course: MoodleCourse) {
        self.course = course
        _viewModel = StateObject(wrappedValue: MoodleCourseDetailViewModel(course: course))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            tabBar
            
            Divider()
            
            // Content
            if viewModel.isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if let error = viewModel.errorMessage {
                errorView(error)
            } else {
                tabContent
            }
        }
        .background(Color.white.ignoresSafeArea())
        .navigationTitle(course.cleanName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadCurrentTab()
        }
        .onChange(of: viewModel.selectedTab) { _, _ in
            Task { await viewModel.loadCurrentTab() }
        }
    }
    
    // MARK: - Tab Bar
    
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(MoodleCourseDetailViewModel.Tab.allCases, id: \.self) { tab in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.selectedTab = tab
                    }
                }) {
                    VStack(spacing: 6) {
                        Text(tab.rawValue)
                            .font(.system(size: 14, weight: viewModel.selectedTab == tab ? .medium : .regular))
                            .foregroundColor(viewModel.selectedTab == tab ? .black : .black.opacity(0.4))
                        
                        Rectangle()
                            .fill(viewModel.selectedTab == tab ? Color.black : Color.clear)
                            .frame(height: 2)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.top, 8)
    }
    
    // MARK: - Tab Content
    
    @ViewBuilder
    private var tabContent: some View {
        switch viewModel.selectedTab {
        case .announcements:
            announcementsTab
        case .assignments:
            assignmentsTab
        case .resources:
            resourcesTab
        case .attendance:
            attendanceTab
        case .grades:
            gradesTab
        }
    }
    
    // MARK: - Announcements
    
    private var announcementsTab: some View {
        Group {
            if viewModel.discussions.isEmpty {
                emptyView("目前沒有公告")
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(viewModel.discussions) { discussion in
                            NavigationLink(destination: MoodleForumView(discussion: discussion)) {
                                DiscussionRow(discussion: discussion)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Assignments
    
    private var assignmentsTab: some View {
        Group {
            if viewModel.assignments.isEmpty {
                emptyView("目前沒有作業")
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(viewModel.assignments) { assignment in
                            NavigationLink(destination: MoodleAssignmentView(assignment: assignment)) {
                                AssignmentRow(assignment: assignment)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Resources
    
    private var resourcesTab: some View {
        Group {
            if viewModel.sections.isEmpty {
                emptyView("目前沒有資源")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(viewModel.sections) { section in
                            SectionView(section: section, courseId: course.id)
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Grades
    
    private var gradesTab: some View {
        Group {
            if viewModel.gradeItems.isEmpty {
                emptyView("目前沒有成績資料")
            } else {
                MoodleGradeView(items: viewModel.gradeItems)
            }
        }
    }
    
    // MARK: - Attendance
    
    private var attendanceTab: some View {
        Group {
            if viewModel.attendanceSections.isEmpty {
                emptyView("目前沒有出缺席資料")
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.attendanceSections) { section in
                            AttendanceSectionCard(section: section)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.medium)
                    .padding(.vertical, Theme.Spacing.medium)
                }
                .background(Color.white)
            }
        }
    }
    
    // MARK: - Helpers
    
    private func emptyView(_ text: String) -> some View {
        VStack {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 36, weight: .light))
                .foregroundColor(.black.opacity(0.2))
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(.black.opacity(0.4))
                .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
    
    private func errorView(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(.black.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("重試") {
                Task { await viewModel.forceReload() }
            }
            .font(.system(size: 14, weight: .medium))
            .padding(.top, 8)
            Spacer()
        }
    }
}

private struct AttendanceSectionCard: View {
    let section: MoodleCourseDetailViewModel.AttendanceSection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.moduleName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.black)
            if !section.sectionName.isEmpty {
                Text(section.sectionName)
                    .font(.system(size: 12))
                    .foregroundColor(.black.opacity(0.35))
            }

            HStack(spacing: 12) {
                attendanceMetric("總堂數", "\(section.total)")
                attendanceMetric("出席", "\(section.presentCount)")
                attendanceMetric("未到", "\(section.absentCount)")
            }

            if section.records.isEmpty {
                Text("目前沒有可顯示的出缺席紀錄")
                    .font(.system(size: 12))
                    .foregroundColor(.black.opacity(0.45))
            } else {
                ForEach(section.records.prefix(5)) { record in
                    HStack {
                        Text(record.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.system(size: 13))
                            .foregroundColor(.black.opacity(0.6))
                        Spacer()
                        Text(record.statusLabel)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(record.isPresent ? .green : .red)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background((record.isPresent ? Color.green : Color.red).opacity(0.12))
                            .cornerRadius(8)
                    }
                }
            }
        }
        .padding(Theme.Spacing.medium)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
        )
    }

    private func attendanceMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(.black.opacity(0.45))
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.black)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


// MARK: - Discussion Row

private struct DiscussionRow: View {
    let discussion: MoodleDiscussion
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(discussion.subject)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.black)
                .lineLimit(2)
            
            Text(discussion.plainMessage)
                .font(.system(size: 13))
                .foregroundColor(.black.opacity(0.5))
                .lineLimit(2)
            
            HStack {
                Text(discussion.userfullname)
                    .font(.system(size: 12))
                    .foregroundColor(.black.opacity(0.4))
                
                Spacer()
                
                Text(discussion.timeModifiedDate, style: .relative)
                    .font(.system(size: 12))
                    .foregroundColor(.black.opacity(0.3))
            }
        }
        .padding(Theme.Spacing.medium)
        .background(Color.white)
        .overlay(
            Rectangle()
                .fill(Color.black.opacity(0.05))
                .frame(height: 1),
            alignment: .bottom
        )
    }
}

// MARK: - Assignment Row

private struct AssignmentRow: View {
    let assignment: MoodleAssignment
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(assignment.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.black)
                    .lineLimit(2)
                
                Spacer()
                
                if assignment.isOverdue {
                    Text("已截止")
                        .font(.system(size: 11))
                        .foregroundColor(.red.opacity(0.8))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(4)
                }
            }
            
            if !assignment.plainIntro.isEmpty {
                Text(assignment.plainIntro)
                    .font(.system(size: 13))
                    .foregroundColor(.black.opacity(0.5))
                    .lineLimit(2)
            }
            
            if let due = assignment.dueDateValue {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                    Text("截止：\(due.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 12))
                }
                .foregroundColor(assignment.isOverdue ? .red.opacity(0.6) : .black.opacity(0.4))
            }
        }
        .padding(Theme.Spacing.medium)
        .background(Color.white)
        .overlay(
            Rectangle()
                .fill(Color.black.opacity(0.05))
                .frame(height: 1),
            alignment: .bottom
        )
    }
}

// MARK: - Section View (Resources)

private struct SectionView: View {
    let section: MoodleCourseSection
    let courseId: Int
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            Text(section.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.black.opacity(0.5))
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.03))
            
            // Modules
            ForEach(section.modules.filter { $0.modname != "label" }) { module in
                ModuleRow(courseId: courseId, module: module)
            }
        }
    }
}

private struct ModuleRow: View {
    let courseId: Int
    let module: MoodleModule
    
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
                .buttonStyle(PlainButtonStyle())
            } else if module.modname == "assign" {
                NavigationLink(destination: MoodleModuleAssignmentView(courseId: courseId, module: module)) {
                    moduleContent
                }
                .buttonStyle(PlainButtonStyle())
            } else if module.modname == "forum" {
                NavigationLink(destination: MoodleModuleForumView(module: module)) {
                    moduleContent
                }
                .buttonStyle(PlainButtonStyle())
            } else if module.modname == "page", let urlStr = module.url {
                NavigationLink(destination: MoodlePageContentView(courseId: courseId, module: module, fallbackURL: urlStr)) {
                    moduleContent
                }
                .buttonStyle(PlainButtonStyle())
            } else if let file = preferredFileContent, let fileURL = tokenFileURL(for: file) {
                // Resource/file: view in-app with QuickLook
                NavigationLink(destination: MoodleFileViewer(fileName: file.filename ?? module.name, fileURL: fileURL)) {
                    moduleContent
                }
                .buttonStyle(PlainButtonStyle())
            } else if let urlStr = module.url {
                // Other module types: open in WebView
                NavigationLink(destination: MoodleWebPageView(title: module.name, targetURL: urlStr)) {
                    moduleContent
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                moduleContent
            }
        }
        .overlay(
            Rectangle()
                .fill(Color.black.opacity(0.05))
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
    
    /// For resource modules, build a token-authenticated download URL
    private var preferredFileContent: MoodleContent? {
        module.contents?.first(where: { content in
            let type = content.type?.lowercased()
            return type == "file" || content.fileurl != nil
        })
    }
    
    private func tokenFileURL(for content: MoodleContent) -> URL? {
        // Only for resource/file types that have downloadable content
        guard module.modname == "resource" || module.modname == "folder",
              let rawURL = content.fileurl,
              let token = MoodleService.shared.currentToken else { return nil }
        
        var rewritten = rawURL
        if rewritten.contains("/pluginfile.php") &&
           !rewritten.contains("/webservice/pluginfile.php") {
            rewritten = rewritten.replacingOccurrences(
                of: "/pluginfile.php",
                with: "/webservice/pluginfile.php"
            )
        }
        let sep = rewritten.contains("?") ? "&" : "?"
        rewritten += "\(sep)token=\(token)"
        return URL(string: rewritten)
    }
    
    private var moduleContent: some View {
        HStack(spacing: 12) {
            Image(systemName: module.iconName)
                .font(.system(size: 16))
                .foregroundColor(.black.opacity(0.5))
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(module.name)
                    .font(.system(size: 14))
                    .foregroundColor(.black)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                
                Text(module.modname)
                    .font(.system(size: 11))
                    .foregroundColor(.black.opacity(0.3))
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.system(size: 12))
                .foregroundColor(.black.opacity(0.3))
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, 10)
    }
}

private struct MoodleModuleAssignmentView: View {
    let courseId: Int
    let module: MoodleModule

    @State private var assignment: MoodleAssignment?
    @State private var isLoading = true
    @State private var errorMessage: String?

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
                        .foregroundColor(.black.opacity(0.55))
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
            let assignments = try await MoodleService.shared.fetchAssignments(courseId: courseId)
            if let instance = module.instance,
               let byInstance = assignments.first(where: { $0.id == instance }) {
                assignment = byInstance
            } else if let byCMID = assignments.first(where: { $0.cmid == module.id }) {
                assignment = byCMID
            } else {
                assignment = assignments.first(where: { $0.name == module.name })
            }
        } catch {
            errorMessage = "作業資料載入失敗：\(error.localizedDescription)"
        }
        isLoading = false
    }
}

private struct MoodleModuleForumView: View {
    let module: MoodleModule

    @State private var discussions: [MoodleDiscussion] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

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
                        .foregroundColor(.black.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Spacer()
                }
            } else if discussions.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Text("目前沒有公告內容")
                        .font(.system(size: 14))
                        .foregroundColor(.black.opacity(0.45))
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(discussions) { discussion in
                            NavigationLink(destination: MoodleForumView(discussion: discussion)) {
                                DiscussionRow(discussion: discussion)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
                .background(Color.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.white)
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
            let resp = try await MoodleService.shared.fetchForumDiscussions(forumId: forumId)
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
    let fallbackURL: String

    @State private var extractedText: String?
    @State private var imageURLs: [URL] = []
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            if hasDisplayContent {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let text = extractedText, !text.isEmpty {
                            Text(text)
                                .font(.system(size: 16))
                                .foregroundColor(.black.opacity(0.85))
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
                                        .fill(Color.black.opacity(0.04))
                                        .frame(height: 180)
                                        .overlay(
                                            Text("圖片載入失敗")
                                                .font(.system(size: 13))
                                                .foregroundColor(.black.opacity(0.45))
                                        )
                                default:
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.black.opacity(0.04))
                                        .frame(height: 180)
                                        .overlay(ProgressView())
                                }
                            }
                        }
                    }
                    .padding(Theme.Spacing.medium)
                }
                .background(Color.white)
            } else if let error = errorMessage {
                VStack(spacing: 10) {
                    Spacer()
                    Text(error)
                        .font(.system(size: 14))
                        .foregroundColor(.black.opacity(0.55))
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
                        .foregroundColor(.black.opacity(0.45))
                        .padding(.top, 8)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.ignoresSafeArea())
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
            let pages = try await MoodleService.shared.fetchPages(courseId: courseId)
            let matched =
                pages.first(where: { $0.id == module.instance }) ??
                pages.first(where: { $0.coursemodule == module.id }) ??
                pages.first(where: { $0.name == module.name })

            let html = (matched?.content ?? matched?.intro ?? "")
            let parsed = parseHTMLContent(html)
            extractedText = parsed.text
            imageURLs = parsed.images

            if !hasDisplayContent {
                errorMessage = "目前無法擷取可顯示內容"
            }
        } catch {
            errorMessage = "內容載入失敗，請稍後再試。"
            print("[Moodle] Page content fallback to web url: \(fallbackURL), error: \(error)")
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

        if let token = MoodleService.shared.currentToken, !token.isEmpty {
            var items = components?.queryItems ?? []
            if !items.contains(where: { $0.name == "token" }) {
                items.append(URLQueryItem(name: "token", value: token))
            }
            components?.queryItems = items
        }

        return components?.url
    }
}

private struct MoodleAttendanceModuleDetailView: View {
    let module: MoodleModule
    let presetAttendanceId: Int?
    let courseModuleId: Int?

    @State private var records: [MoodleCourseDetailViewModel.AttendanceRecord] = []
    @State private var total: Int = 0
    @State private var presentCount: Int = 0
    @State private var absentCount: Int = 0
    @State private var isLoading = true
    @State private var errorMessage: String?

    init(module: MoodleModule, presetAttendanceId: Int? = nil, courseModuleId: Int? = nil) {
        self.module = module
        self.presetAttendanceId = presetAttendanceId
        self.courseModuleId = courseModuleId
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
                        .foregroundColor(.black.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Spacer()
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            metric("總堂數", "\(total)")
                            metric("出席", "\(presentCount)")
                            metric("未到", "\(absentCount)")
                        }

                        ForEach(records) { record in
                            HStack {
                                Text(record.date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.system(size: 13))
                                    .foregroundColor(.black.opacity(0.6))
                                Spacer()
                                Text(record.statusLabel)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(record.isPresent ? .green : .red)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background((record.isPresent ? Color.green : Color.red).opacity(0.12))
                                    .cornerRadius(8)
                            }
                            Divider()
                        }
                    }
                    .padding(Theme.Spacing.medium)
                }
                .background(Color.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.white)
        .navigationTitle(module.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadAttendance() }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(.black.opacity(0.45))
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.black)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadAttendance() async {
        let attendanceId: Int?
        if let presetAttendanceId {
            attendanceId = presetAttendanceId
        } else if let instanceId = module.instance {
            attendanceId = instanceId
        } else {
            attendanceId = try? await resolveAttendanceIdFromCourseModule()
        }
        guard let attendanceId else {
            errorMessage = "無法識別出缺席資料"
            isLoading = false
            return
        }
        do {
            let resp = try await MoodleService.shared.fetchAttendanceUserSessions(attendanceId: attendanceId)
            let statusMap = Dictionary(uniqueKeysWithValues: resp.statuses.map { ($0.id, $0) })
            let mapped = resp.sessions
                .sorted(by: { $0.sessdate > $1.sessdate })
                .map { session -> MoodleCourseDetailViewModel.AttendanceRecord in
                    let status = session.statusid.flatMap { statusMap[$0] }
                    let label = (status?.acronym?.isEmpty == false ? status?.acronym : status?.description) ?? "未簽到"
                    let present = (status?.grade ?? 0) > 0
                    return MoodleCourseDetailViewModel.AttendanceRecord(
                        id: session.id,
                        date: Date(timeIntervalSince1970: TimeInterval(session.sessdate)),
                        statusLabel: label,
                        isPresent: present
                    )
                }
            records = mapped
            total = mapped.count
            presentCount = mapped.filter(\.isPresent).count
            absentCount = max(total - presentCount, 0)
        } catch {
            errorMessage = "出缺席資料載入失敗：\(error.localizedDescription)"
        }
        isLoading = false
    }

    private func resolveAttendanceIdFromCourseModule() async throws -> Int? {
        guard let cmid = courseModuleId else { return nil }
        return try await MoodleService.shared.resolveAttendanceInstanceId(courseModuleId: cmid)
    }
}
