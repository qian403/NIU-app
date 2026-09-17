import SwiftUI

struct MoodleView: View {
    @StateObject private var viewModel = MoodleViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var semesterRenderToken = UUID()
    
    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.coursesBySemester.isEmpty {
                // Always show courses if we have data, even during refresh
                courseListContent
            } else {
                switch viewModel.loadState {
                case .idle, .loading:
                    loadingView
                case .loaded:
                    // Loaded but empty
                    loadingView
                case .error(let message):
                    errorView(message)
                }
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("M 園區")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if case .idle = viewModel.loadState {
                await loadWithCredentials()
            }
        }
        .onChange(of: viewModel.coursesBySemester.count) { _, _ in
            semesterRenderToken = UUID()
        }
        .onChange(of: viewModel.selectedSemester) { _, _ in
            semesterRenderToken = UUID()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                semesterRenderToken = UUID()
            }
        }
        .refreshable {
            await loadWithCredentials()
        }
    }
    
    // MARK: - Content
    
    private var courseListContent: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Spacing.medium) {
                overviewHeader
                semesterSection

                LazyVStack(spacing: Theme.Spacing.medium) {
                    ForEach(viewModel.currentSemesterCourses) { course in
                        NavigationLink(destination: MoodleCourseDetailView(course: course)) {
                            CourseCard(course: course)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)
        }
    }

    private var overviewHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: "graduationcap.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 48, height: 48)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 3) {
                Text("我的課程")
                    .font(.system(size: 18, weight: .bold))
                Text("\(viewModel.currentSemesterCourses.count) 門課程 · 下拉即可同步")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(Theme.Spacing.medium)
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: Theme.CornerRadius.large, style: .continuous)
        )
    }
    
    private var semesterSection: some View {
        Group {
            if displaySemesters.count > 1 {
                HStack {
                    Text("學期")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        ForEach(displaySemesters, id: \.self) { semester in
                            Button {
                                viewModel.selectedSemester = semester
                            } label: {
                                HStack {
                                    Text(semester)
                                    if viewModel.selectedSemesterDisplay == semester {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(viewModel.selectedSemesterDisplay ?? displaySemesters.first ?? "學期")
                                .font(.system(size: 14, weight: .medium))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffect(.regular.interactive(), in: Capsule())
                    }
                }
            } else if let semester = displaySemesters.first {
                HStack {
                    Text("學期")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(semester)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: Capsule())
                }
            } else {
                HStack {
                    Text("學期載入中")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .frame(minHeight: 44, alignment: .center)
        .id(semesterRenderToken)
    }
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
            Text("載入課程中...")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
    
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.secondary)
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("重試") {
                Task { await loadWithCredentials() }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(Color.accentColor)
            .cornerRadius(20)
            Spacer()
        }
    }
    
    // MARK: - Helpers
    
    private func loadWithCredentials() async {
        if viewModel.isAuthenticated {
            await viewModel.loadCourses(username: "", password: "")
            return
        }
        guard let creds = LoginRepository.shared.getSavedCredentials() else {
            viewModel.loadState = .error("找不到登入資料，請登出後重新登入")
            return
        }
        await viewModel.loadCourses(username: creds.username, password: creds.password)
    }

    private var displaySemesters: [String] {
        if !viewModel.allSemesters.isEmpty {
            return viewModel.allSemesters
        }
        if let selected = viewModel.selectedSemesterDisplay {
            return [selected]
        }
        if let course = viewModel.currentSemesterCourses.first {
            let label = course.semesterLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty { return [label] }
            return [inferredSemester(from: course.startDate)]
        }
        return []
    }

    private func inferredSemester(from date: Date) -> String {
        let cal = Calendar.current
        let year = cal.component(.year, from: date) - 1911
        let month = cal.component(.month, from: date)
        let term = (month >= 8 || month == 1) ? 1 : 2
        let academicYear = month == 1 ? (year - 1) : year
        return "\(academicYear)-\(term)"
    }
}


// MARK: - Course Card

private struct CourseCard: View {
    let course: MoodleCourse
    
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))

                Text(course.cleanName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 5)
            }
            
            // Teacher & credits
            HStack(spacing: 12) {
                if let teacher = course.teacherName {
                    HStack(spacing: 4) {
                        Image(systemName: "person")
                            .font(.system(size: 11))
                        Text(teacher)
                            .font(.system(size: 12))
                    }
                    .foregroundColor(.secondary)
                }
                
                if let credits = course.credits {
                    HStack(spacing: 4) {
                        Image(systemName: "book")
                            .font(.system(size: 11))
                        Text("\(credits) 學分")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(.secondary)
                }
            }
            
            // Progress bar
            if let progress = course.progress, progress > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("完成進度")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(Int(progress))%")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.primary)
                    }
                    
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.primary.opacity(0.08))
                                .frame(height: 4)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.primary.opacity(0.6))
                                .frame(width: geo.size.width * CGFloat(progress / 100.0), height: 4)
                        }
                    }
                    .frame(height: 4)
                }
            }
            
            HStack {
                Text(course.idnumber)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                if course.hidden {
                    Label("已隱藏", systemImage: "eye.slash")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(
            .regular.interactive(),
            in: RoundedRectangle(cornerRadius: Theme.CornerRadius.large, style: .continuous)
        )
        .contentShape(Rectangle())
    }
}

#Preview {
    NavigationStack {
        MoodleView()
    }
}
