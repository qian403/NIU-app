import SwiftUI
import UniformTypeIdentifiers

struct MoodleAssignmentView: View {
    let assignment: MoodleAssignment
    private let repository: any MoodleSubmissionRepositoryProtocol
    private let sessionRevision: Int
    private let onSubmissionChange: ((Bool) -> Void)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(assignment: MoodleAssignment, repository: (any MoodleSubmissionRepositoryProtocol)? = nil,
         onSubmissionChange: ((Bool) -> Void)? = nil) {
        self.onSubmissionChange = onSubmissionChange
        self.assignment = assignment
        let repository = repository ?? MoodleSubmissionRepository()
        self.repository = repository
        self.sessionRevision = repository.sessionRevision
    }
    
    @State private var submissionRequestID = UUID()
    @State private var submissionStatus: MoodleSubmissionStatus?
    @State private var gradeItem: MoodleGradeItem?
    @State private var isLoading = true
    @State private var isDeleting = false
    @State private var actionMessage: String?
    @State private var isSubmittingForGrading = false
    @State private var isPickingFile = false
    @State private var isUploading = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Title
                Text(assignment.name)
                    .font(.title3.weight(.bold))
                    .foregroundColor(.primary)
                
                // Status badges
                HStack(spacing: 8) {
                    if assignment.isOverdue {
                        badge("已截止", color: .red)
                    } else if assignment.dueDateValue != nil {
                        badge("進行中", color: .green)
                    }
                    
                    if let status = submissionStatus?.lastattempt?.submission?.status {
                        switch status {
                        case "submitted":
                            badge("已繳交", color: .blue)
                        case "draft":
                            badge("草稿", color: .orange)
                        default:
                            badge("未繳交", color: .gray)
                        }
                    }
                }
                
                Divider()
                
                // Due date
                if let due = assignment.dueDateValue {
                    infoRow(icon: "clock", title: "截止時間", value: MoodlePresentation.dateTime(due))
                }
                
                // Description
                if !assignment.plainIntro.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("作業說明")
                            .font(.headline.weight(.semibold))
                            .foregroundColor(.primary)
                        
                        Text(assignment.plainIntro)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }
                
                Divider()
                
                // Submission info
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Text("載入繳交狀態...")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 20)
                } else if let attempt = submissionStatus?.lastattempt {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("繳交狀態")
                            .font(.headline.weight(.semibold))
                            .foregroundColor(.primary)
                        
                        if let submission = attempt.submission {
                            infoRow(
                                icon: "doc.text",
                                title: "狀態",
                                value: submissionStatusText(submission.status)
                            )
                            
                            if let ts = submission.timemodified, ts > 0 {
                                let date = Date(timeIntervalSince1970: TimeInterval(ts))
                                infoRow(
                                    icon: "calendar",
                                    title: "最後修改",
                                    value: MoodlePresentation.dateTime(date)
                                )
                            }
                        }
                        
                        if let gradeValue = formattedGrade {
                            infoRow(icon: "graduationcap", title: "作業評分", value: gradeValue)
                        } else if let status = MoodlePresentation.gradingStatus(
                            graded: attempt.graded, grade: formattedGrade
                        ) {
                            infoRow(icon: "checkmark.circle", title: "評分狀態", value: status)
                        }

                        if let feedback = gradeItem?.cleanFeedback, !feedback.isEmpty {
                            infoRow(
                                icon: "text.bubble",
                                title: "教師回饋",
                                value: feedback
                            )
                        }
                    }

                    if !submissionFiles.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("已繳交檔案")
                                .font(.headline.weight(.semibold))
                                .foregroundColor(.primary)

                            ForEach(submissionFiles) { file in
                                if let url = tokenizedFileURL(file.fileurl) {
                                    NavigationLink(destination: MoodleFileViewer(fileName: file.filename, fileURL: url)) {
                                        HStack {
                                            Image(systemName: "doc")
                                                .foregroundColor(.secondary)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(file.filename)
                                                    .font(.footnote.weight(.medium))
                                                    .foregroundColor(.primary)
                                                if let size = file.filesize {
                                                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                }
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                        }
                    }
                }

                Divider()

                VStack(spacing: 10) {
                    Button {
                        isPickingFile = true
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text(isUploading ? "上傳中..." : "上傳檔案")
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .disabled(isUploading)
                    .contentShape(Rectangle())

                    if let editSubmissionURL = repository.webSubmissionURL(for: assignment) {
                        NavigationLink(destination: MoodleWebPageView(
                            title: "網頁上傳作業",
                            targetURL: editSubmissionURL
                        )) {
                            HStack {
                                Image(systemName: "globe")
                                Text("網頁模式（備用）")
                            }
                            .font(.caption.weight(.regular))
                            .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }

                    if !submissionFiles.isEmpty {
                        Button(role: .destructive) {
                            Task { await clearSubmissionFiles() }
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text(isDeleting ? "刪除中..." : "刪除已繳交檔案")
                            }
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.red.opacity(0.8))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(Color.red.opacity(0.25), lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                        }
                        .disabled(isDeleting)
                        .contentShape(Rectangle())
                    }

                    if !isFinalSubmitted {
                        Button {
                            Task { await submitForGrading() }
                        } label: {
                            HStack {
                                Image(systemName: "paperplane")
                                Text(isSubmittingForGrading ? "送出中..." : "送出作業（最終）")
                            }
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.blue)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(Color.blue.opacity(0.3), lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                        }
                        .disabled(isSubmittingForGrading || submissionFiles.isEmpty)
                        .contentShape(Rectangle())
                    }
                }

                if let actionMessage {
                    Text(actionMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Text("上傳完成後會自動儲存為作業草稿，最後再按「送出作業（最終）」完成繳交。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(Theme.Spacing.medium)
        }
        .background(Color(.systemBackground))
        .navigationTitle("作業詳情")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadSubmission()
        }
        .fileImporter(
            isPresented: $isPickingFile,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
    }
    
    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.1))
            .cornerRadius(6)
    }
    
    private func infoRow(icon: String, title: String, value: String) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
        return layout {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func submissionStatusText(_ status: String?) -> String {
        switch status {
        case "submitted": return "已繳交"
        case "draft": return "草稿"
        case "new": return "未繳交"
        default: return status ?? "未知"
        }
    }

    private var formattedGrade: String? {
        MoodlePresentation.assignmentGrade(gradeItem)
    }

    private var submissionFiles: [MoodleSubmissionFile] {
        submissionStatus?.lastattempt?.submission?.submittedFiles ?? []
    }

    private var isFinalSubmitted: Bool {
        submissionStatus?.lastattempt?.submission?.status == "submitted"
    }

    private func tokenizedFileURL(_ rawURL: String?) -> URL? {
        guard let rawURL else { return nil }
        return repository.fileURL(for: rawURL)
    }
    
    private func loadSubmission() async {
        guard repository.sessionRevision == sessionRevision else { return }
        let request = UUID()
        submissionRequestID = request
        defer { if submissionRequestID == request { isLoading = false } }
        do {
            async let submissionTask = repository.fetchStatus(assignment: assignment)
            async let gradeTask = repository.fetchGrades(courseId: assignment.course)
            let status = try await submissionTask
            try Task.checkCancellation()
            guard submissionRequestID == request, repository.sessionRevision == sessionRevision else { return }
            // Submission remains useful even when the optional grade endpoint fails.
            submissionStatus = status
            if let submitted = try? MoodleUpcomingRules.isSubmitted(status) {
                onSubmissionChange?(submitted)
                NotificationCenter.default.post(name: .moodleSubmissionDidChange, object: MoodleSubmissionChange(
                    assignmentID: assignment.id, courseID: assignment.course,
                    submitted: submitted, sessionRevision: sessionRevision))
            }
            do {
                let gradeItems = try await gradeTask
                try Task.checkCancellation()
                guard submissionRequestID == request else { return }
                gradeItem = findAssignmentGrade(in: gradeItems)
            } catch {
                guard submissionRequestID == request, !Task.isCancelled,
                      !(error is CancellationError) else { return }
                actionMessage = "評分暫時無法載入，繳交狀態已更新。"
            }
        } catch {
            guard submissionRequestID == request, !Task.isCancelled,
                  !(error is CancellationError) else { return }
            actionMessage = "繳交狀態載入失敗，請重新開啟作業。"
        }
    }

    private func clearSubmissionFiles() async {
        isDeleting = true
        actionMessage = nil
        defer { isDeleting = false }
        do {
            try await repository.clear(assignment: assignment)
            actionMessage = "已刪除繳交檔案"
            await loadSubmission()
        } catch {
            actionMessage = "刪除失敗：\(error.localizedDescription)"
        }
    }

    private func submitForGrading() async {
        isSubmittingForGrading = true
        actionMessage = nil
        defer { isSubmittingForGrading = false }
        do {
            try await repository.submit(assignment: assignment)
            actionMessage = "作業已送出"
            await loadSubmission()
        } catch {
            actionMessage = "送出失敗：\(error.localizedDescription)"
        }
    }

    private func findAssignmentGrade(in items: [MoodleGradeItem]) -> MoodleGradeItem? {
        let target = normalizeName(assignment.name)
        let assignItems = items.filter { $0.itemmodule == "assign" }
        if let exact = assignItems.first(where: { normalizeName($0.itemname ?? "") == target }) {
            return exact
        }
        return assignItems.first(where: {
            let name = normalizeName($0.itemname ?? "")
            return !name.isEmpty && (name.contains(target) || target.contains(name))
        })
    }

    private func normalizeName(_ name: String) -> String {
        name.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let sourceURL = urls.first else {
                actionMessage = "未選擇檔案"
                return
            }
            Task {
                await uploadFile(sourceURL)
            }
        case .failure(let error):
            actionMessage = "選擇檔案失敗：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func uploadFile(_ sourceURL: URL) async {
        isUploading = true
        actionMessage = nil
        defer { isUploading = false }

        do {
            let copiedURL = try prepareReadableCopy(from: sourceURL)
            defer { try? FileManager.default.removeItem(at: copiedURL) }

            try await repository.upload(assignment: assignment, localFileURL: copiedURL)

            actionMessage = "檔案已上傳並儲存為草稿"
            await loadSubmission()
        } catch {
            actionMessage = "上傳失敗：\(error.localizedDescription)"
        }
    }

    private func prepareReadableCopy(from sourceURL: URL) throws -> URL {
        let hasSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileManager = FileManager.default
        let uploadDir = fileManager.temporaryDirectory.appendingPathComponent("moodle-upload", isDirectory: true)
        try fileManager.createDirectory(at: uploadDir, withIntermediateDirectories: true)

        let filename = sourceURL.lastPathComponent.isEmpty
            ? "upload-\(UUID().uuidString)"
            : sourceURL.lastPathComponent
        let destination = uploadDir.appendingPathComponent("\(UUID().uuidString)-\(filename)")
        try fileManager.copyItem(at: sourceURL, to: destination)
        return destination
    }
}
