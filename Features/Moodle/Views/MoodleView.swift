import SwiftUI

struct MoodleView: View {
    @StateObject private var viewModel = MoodleViewModel()
    @EnvironmentObject private var appState: AppState
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
        .background(Color(.systemBackground))
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
        VStack(spacing: 0) {
            semesterSection
            
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.currentSemesterCourses) { course in
                        NavigationLink(destination: MoodleCourseDetailView(course: course)) {
                            CourseCard(course: course)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.vertical, Theme.Spacing.small)
            }
        }
    }
    
    private var semesterSection: some View {
        Group {
            if displaySemesters.count > 1 {
                HStack {
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
                        .foregroundColor(.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                        )
                    }
                }
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.vertical, Theme.Spacing.small)
            } else if let semester = displaySemesters.first {
                HStack {
                    Text(semester)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color(.systemBackground))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.primary))
                    Spacer()
                }
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.vertical, Theme.Spacing.small)
            } else {
                HStack {
                    Text("學期載入中")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.vertical, Theme.Spacing.small)
            }
        }
        .frame(minHeight: 48, alignment: .center)
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
            .foregroundColor(Color(.systemBackground))
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(Color.primary)
            .cornerRadius(20)
            Spacer()
        }
    }
    
    // MARK: - Helpers
    
    private func loadWithCredentials() async {
        guard let creds = LoginRepository.shared.getSavedCredentials() else { return }
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
        VStack(alignment: .leading, spacing: 10) {
            // Course name
            Text(course.cleanName)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(2)
            
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
            
            // Course ID
            Text(course.idnumber)
                .font(.system(size: 11, weight: .light))
                .foregroundColor(.secondary)
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                .fill(Color.primary.opacity(0.001))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
    }
}

#Preview {
    NavigationStack {
        MoodleView()
            .environmentObject(AppState())
    }
}
