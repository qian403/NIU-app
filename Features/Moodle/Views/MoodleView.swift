import SwiftUI

struct MoodleView: View {
    @StateObject private var viewModel: MoodleViewModel
    @State private var reloadRequest = 0
    @State private var semesterRequest = 0
    @State private var upcomingNavigationOwner = UUID()
    @State private var upcomingExpanded: Bool
    @StateObject private var upcoming: MoodleUpcomingViewModel
    private let detailRepositories: MoodleDetailRepositories?

    init(repository: (any MoodleCourseRepositoryProtocol)? = nil,
         detailRepositories: MoodleDetailRepositories? = nil, initialSemester: String? = nil,
         upcomingRepository: (any MoodleUpcomingRepositoryProtocol)? = nil,
         clock: @escaping () -> Date = Date.init, initiallyExpandUpcoming: Bool = true) {
        _upcomingExpanded = State(initialValue: initiallyExpandUpcoming)
        _upcoming = StateObject(wrappedValue: MoodleUpcomingViewModel(repository: upcomingRepository, clock: clock))
        _viewModel = StateObject(wrappedValue: MoodleViewModel(repository: repository, initialSemester: initialSemester))
        self.detailRepositories = detailRepositories
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Spacing.medium) {
                if !viewModel.allSemesters.isEmpty {
                    semesterSection
                    MoodleUpcomingSection(model: upcoming, submissionRepository: detailRepositories?.submission,
                                          isExpanded: $upcomingExpanded, navigationOwner: upcomingNavigationOwner)
                }
                if viewModel.isRefreshing && !viewModel.coursesBySemester.isEmpty {
                    Label("正在更新，顯示上次載入的資料", systemImage: "arrow.triangle.2.circlepath")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if case .error(let message) = viewModel.loadState,
                   !viewModel.coursesBySemester.isEmpty {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                    retryButton("重試")
                }
                switch viewModel.contentState {
                case .loading:
                    ProgressView("載入課程中…")
                        .padding(.vertical, Theme.Spacing.xxlarge)
                        .frame(maxWidth: .infinity)
                case .error(let message):
                    ContentUnavailableView {
                        Label("課程載入失敗", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        retryButton("重試")
                    }
                case .empty:
                    ContentUnavailableView {
                        Label("這個學期沒有課程", systemImage: "books.vertical")
                    } description: {
                        Text("目前沒有可顯示的課程，可重新整理取得最新資料。")
                    } actions: {
                        retryButton("重新整理")
                    }
                case .courses:
                    ForEach(viewModel.currentSemesterCourses) { course in
                        NavigationLink {
                            MoodleCourseDetailView(course: course, repositories: detailRepositories)
                        } label: {
                            CourseCard(course: course)
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityHint("開啟課程內容")
                    }
                }
            }
            .padding(Theme.Spacing.medium)
        }
        .background(Theme.Colors.groupedBackground.ignoresSafeArea())
        .navigationTitle("M 園區")
        .navigationBarTitleDisplayMode(.large)
        .task(id: "\(reloadRequest)-\(semesterRequest)") { await loadWithCredentials() }
        .refreshable { await loadWithCredentials(force: true) }
        .modifier(MoodleUpcomingNavigation(model: upcoming, repository: detailRepositories?.submission, owner: upcomingNavigationOwner))
    }

    private var semesterSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxsmall) {
            Menu {
                Picker("學期", selection: Binding(get: { viewModel.selectedSemester }, set: {
                    upcoming.invalidate()
                    viewModel.selectedSemester = $0
                    semesterRequest += 1
                })) {
                    ForEach(viewModel.allSemesters, id: \.self) { semester in
                        Text(semester).tag(Optional(semester))
                    }
                }
            } label: {
                HStack(spacing: Theme.Spacing.xsmall) {
                    Text(viewModel.selectedSemester ?? "選擇學期")
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .font(.headline)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("學期")
            .accessibilityValue(viewModel.selectedSemester ?? "尚未選擇")
            Text("\(viewModel.currentSemesterCourses.count) 門課程")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func retryButton(_ title: String) -> some View {
        Button(title) { reloadRequest += 1 }
            .frame(minWidth: 44, minHeight: 44)
            .disabled(viewModel.isRefreshing)
    }

    private func loadWithCredentials(force: Bool = false) async {
        await viewModel.loadHome(upcoming: upcoming, request: reloadRequest, force: force) {
            guard let saved = LoginRepository.shared.getSavedCredentials() else { return nil }
            return (saved.username, saved.password)
        }
    }
}

// MARK: - Schedule → Moodle course

/// Opened from the class schedule: finds the Moodle course with the same name
/// and shows its detail page directly.
struct MoodleScheduleCourseView: View {
    @StateObject private var viewModel: MoodleScheduleCourseLookupViewModel

    init(courseName: String) {
        _viewModel = StateObject(wrappedValue: MoodleScheduleCourseLookupViewModel(courseName: courseName))
    }

    var body: some View {
        content
            .task { await viewModel.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            VStack(spacing: 16) {
                ProgressView()
                Text("正在 M 園區尋找「\(viewModel.courseName)」…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(viewModel.courseName)
            .navigationBarTitleDisplayMode(.inline)

        case .matched(let course):
            MoodleCourseDetailView(course: course)

        case .multiple(let courses):
            ScrollView {
                LazyVStack(spacing: Theme.Spacing.medium) {
                    Text("找到多門名稱相符的課程，請選擇：")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(courses) { course in
                        NavigationLink(destination: MoodleCourseDetailView(course: course)) {
                            CourseCard(course: course)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.vertical, Theme.Spacing.small)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(viewModel.courseName)
            .navigationBarTitleDisplayMode(.inline)

        case .notFound:
            messageView(
                icon: "magnifyingglass",
                message: "M 園區找不到「\(viewModel.courseName)」，可能尚未開設課程頁面。"
            )

        case .error(let message):
            messageView(icon: "exclamationmark.triangle", message: message, showsRetry: true)
        }
    }

    private func messageView(icon: String, message: String, showsRetry: Bool = false) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: icon)
                .font(.largeTitle.weight(.light))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            if showsRetry {
                NIUButton("重試") {
                    Task { await viewModel.load() }
                }
            }
            NavigationLink(destination: MoodleView()) {
                Text("查看所有 M 園區課程")
                    .font(.subheadline.weight(.medium))
                    .frame(minHeight: 44)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(viewModel.courseName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Course Card

private struct CourseCard: View {
    let course: MoodleCourse
    
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
            HStack(alignment: .top) {
                Text(course.cleanName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            Text(course.teacherName ?? course.idnumber)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let credits = course.credits {
                Text("\(credits) 學分")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let progress = course.progress, progress > 0 {
                ProgressView(value: progress, total: 100) {
                    Text("完成進度 \(Int(progress))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if course.hidden {
                Label("已隱藏", systemImage: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: Theme.CornerRadius.large))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack { MoodleView() }
}
