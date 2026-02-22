import SwiftUI

struct MoodleAssignmentView: View {
    let assignment: MoodleAssignment
    
    @State private var submissionStatus: MoodleSubmissionStatus?
    @State private var gradeItem: MoodleGradeItem?
    @State private var isLoading = true
    @State private var isDeleting = false
    @State private var actionMessage: String?
    @State private var isSubmittingForGrading = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Title
                Text(assignment.name)
                    .font(.system(size: 20, weight: .bold))
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
                    infoRow(icon: "clock", title: "截止時間", value: due.formatted(date: .long, time: .shortened))
                }
                
                // Description
                if !assignment.plainIntro.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("作業說明")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.primary)
                        
                        Text(assignment.plainIntro)
                            .font(.system(size: 14))
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
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 20)
                } else if let attempt = submissionStatus?.lastattempt {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("繳交狀態")
                            .font(.system(size: 14, weight: .semibold))
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
                                .foregroundColor(.primary)

                            ForEach(submissionFiles) { file in
                                if let url = tokenizedFileURL(file.fileurl) {
                                    NavigationLink(destination: MoodleFileViewer(fileName: file.filename, fileURL: url)) {
                                        HStack {
                                            Image(systemName: "doc")
                                                .foregroundColor(.secondary)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(file.filename)
                                                    .font(.system(size: 13, weight: .medium))
                                                    .foregroundColor(.primary)
                                                if let size = file.filesize {
                                                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                                        .font(.system(size: 11))
                                                        .foregroundColor(.secondary)
                                                }
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 11))
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
                    NavigationLink(destination: MoodleWebPageView(
                        title: "網頁上傳作業",
                        targetURL: editSubmissionURL
                    )) {
                        HStack {
                            Image(systemName: "globe")
                            Text("上傳檔案")
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())

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
                            .font(.system(size: 14, weight: .medium))
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
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                Text("作業檔案上傳暫時改為網頁模式，完成後返回此頁可重新整理狀態。")
                    .font(.system(size: 12))
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
                .foregroundColor(.secondary)
                .frame(width: 20)
            
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .leading)
            
            Text(value)
                .font(.system(size: 13))
                .foregroundColor(.primary)
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

    private var editSubmissionURL: String {
        "https://euni.niu.edu.tw/mod/assign/view.php?id=\(assignment.cmid)&action=editsubmission"
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
