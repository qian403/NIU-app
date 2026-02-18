import SwiftUI
import UniformTypeIdentifiers

struct MoodleAssignmentView: View {
    let assignment: MoodleAssignment
    
    @State private var submissionStatus: MoodleSubmissionStatus?
    @State private var gradeItem: MoodleGradeItem?
    @State private var isLoading = true
    @State private var isUploading = false
    @State private var isDeleting = false
    @State private var showFileImporter = false
    @State private var actionMessage: String?
    @State private var isSubmittingForGrading = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Title
                Text(assignment.name)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.black)
                
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
                    infoRow(icon: "clock", title: "截止時間", value: due.formatted(date: .long, time: .shortened))
                }
                
                // Description
                if !assignment.plainIntro.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("作業說明")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.black)
                        
                        Text(assignment.plainIntro)
                            .font(.system(size: 14))
                            .foregroundColor(.black.opacity(0.7))
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
                            .font(.system(size: 13))
                            .foregroundColor(.black.opacity(0.4))
                        Spacer()
                    }
                    .padding(.vertical, 20)
                } else if let attempt = submissionStatus?.lastattempt {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("繳交狀態")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.black)
                        
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
                                    value: date.formatted(date: .abbreviated, time: .shortened)
                                )
                            }
                        }
                        
                        if let graded = attempt.graded {
                            infoRow(
                                icon: "checkmark.circle",
                                title: "已評分",
                                value: graded ? "是" : "否"
                            )
                        }

                        if let gradeValue = formattedGrade {
                            infoRow(
                                icon: "graduationcap",
                                title: "作業評分",
                                value: gradeValue
                            )
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
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.black)

                            ForEach(submissionFiles) { file in
                                if let url = tokenizedFileURL(file.fileurl) {
                                    NavigationLink(destination: MoodleFileViewer(fileName: file.filename, fileURL: url)) {
                                        HStack {
                                            Image(systemName: "doc")
                                                .foregroundColor(.black.opacity(0.5))
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(file.filename)
                                                    .font(.system(size: 13, weight: .medium))
                                                    .foregroundColor(.black)
                                                if let size = file.filesize {
                                                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                                        .font(.system(size: 11))
                                                        .foregroundColor(.black.opacity(0.45))
                                                }
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 11))
                                                .foregroundColor(.black.opacity(0.3))
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
                        showFileImporter = true
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text(isUploading ? "上傳中..." : "上傳作業檔案")
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.black.opacity(0.2), lineWidth: 1)
                        )
                    }
                    .disabled(isUploading)

                    if !submissionFiles.isEmpty {
                        Button(role: .destructive) {
                            Task { await clearSubmissionFiles() }
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text(isDeleting ? "刪除中..." : "刪除已繳交檔案")
                            }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.red.opacity(0.8))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(Color.red.opacity(0.25), lineWidth: 1)
                            )
                        }
                        .disabled(isDeleting)
                    }

                    if !isFinalSubmitted {
                        Button {
                            Task { await submitForGrading() }
                        } label: {
                            HStack {
                                Image(systemName: "paperplane")
                                Text(isSubmittingForGrading ? "送出中..." : "送出作業（最終）")
                            }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.blue)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(Color.blue.opacity(0.3), lineWidth: 1)
                            )
                        }
                        .disabled(isSubmittingForGrading || submissionFiles.isEmpty)
                    }
                }

                if let actionMessage {
                    Text(actionMessage)
                        .font(.system(size: 12))
                        .foregroundColor(.black.opacity(0.55))
                }
            }
            .padding(Theme.Spacing.medium)
        }
        .background(Color.white)
        .navigationTitle("作業詳情")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadSubmission()
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let localURL = urls.first else { return }
                Task { await uploadSubmissionFile(localURL) }
            case .failure(let error):
                actionMessage = "選擇檔案失敗：\(error.localizedDescription)"
            }
        }
    }
    
    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.1))
            .cornerRadius(6)
    }
    
    private func infoRow(icon: String, title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.black.opacity(0.4))
                .frame(width: 20)
            
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(.black.opacity(0.5))
                .frame(width: 70, alignment: .leading)
            
            Text(value)
                .font(.system(size: 13))
                .foregroundColor(.black)
        }
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
        if let grade = gradeItem?.gradeformatted, !grade.isEmpty {
            return grade
        }
        if let raw = gradeItem?.graderaw, let max = gradeItem?.grademax, max > 0 {
            return String(format: "%.2f / %.2f", raw, max)
        }
        return nil
    }

    private var submissionFiles: [MoodleSubmissionFile] {
        submissionStatus?.lastattempt?.submission?.submittedFiles ?? []
    }

    private var isFinalSubmitted: Bool {
        submissionStatus?.lastattempt?.submission?.status == "submitted"
    }

    private func tokenizedFileURL(_ rawURL: String?) -> URL? {
        guard let rawURL else { return nil }
        return MoodleService.shared.fileURL(for: rawURL)
    }
    
    private func loadSubmission() async {
        do {
            async let submissionTask = MoodleService.shared.fetchSubmissionStatus(assignId: assignment.id)
            async let gradeTask = MoodleService.shared.fetchGradeItems(courseId: assignment.course)
            submissionStatus = try await submissionTask
            let gradeItems = try await gradeTask
            gradeItem = findAssignmentGrade(in: gradeItems)
        } catch {
            print("[Moodle] Load submission error: \(error)")
        }
        isLoading = false
    }

    private func uploadSubmissionFile(_ localURL: URL) async {
        isUploading = true
        actionMessage = nil
        defer { isUploading = false }
        let hasAccess = localURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { localURL.stopAccessingSecurityScopedResource() }
        }
        do {
            let draftItemId = try await MoodleService.shared.fetchUnusedDraftItemId()
            _ = try await MoodleService.shared.uploadAssignmentFile(localFileURL: localURL, draftItemId: draftItemId)
            try await MoodleService.shared.saveAssignmentSubmission(assignId: assignment.id, draftItemId: draftItemId)
            actionMessage = "上傳成功"
            await loadSubmission()
        } catch {
            actionMessage = "上傳失敗：\(error.localizedDescription)"
        }
    }

    private func clearSubmissionFiles() async {
        isDeleting = true
        actionMessage = nil
        defer { isDeleting = false }
        do {
            try await MoodleService.shared.clearAssignmentSubmission(assignId: assignment.id)
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
            try await MoodleService.shared.submitAssignmentForGrading(
                assignId: assignment.id,
                acceptSubmissionStatement: true
            )
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
}
