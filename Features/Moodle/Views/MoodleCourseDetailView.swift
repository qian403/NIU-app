import SwiftUI

struct MoodleCourseDetailView: View {
    let course: MoodleCourse
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var tabIconHeight: CGFloat = 24
    @ScaledMetric(relativeTo: .caption) private var tabLabelLineHeight: CGFloat = 18
    @StateObject private var viewModel: MoodleCourseDetailViewModel
    @StateObject private var announcementsViewModel: MoodleAnnouncementsViewModel
    @StateObject private var assignmentsViewModel: MoodleAssignmentsListViewModel
    @StateObject private var questionsViewModel: MoodleQuestionsViewModel
    @StateObject private var resourcesViewModel: MoodleResourcesViewModel
    @StateObject private var attendanceViewModel: MoodleAttendanceViewModel
    @StateObject private var gradesViewModel: MoodleGradesViewModel
    private let resourcesRepository: any MoodleResourcesRepositoryProtocol

    init(course: MoodleCourse) {
        let resourcesRepository = MoodleResourcesRepository()
        self.course = course
        self.resourcesRepository = resourcesRepository
        _viewModel = StateObject(wrappedValue: MoodleCourseDetailViewModel())
        _announcementsViewModel = StateObject(wrappedValue: MoodleAnnouncementsViewModel())
        _assignmentsViewModel = StateObject(wrappedValue: MoodleAssignmentsListViewModel())
        _questionsViewModel = StateObject(wrappedValue: MoodleQuestionsViewModel(
            repository: MoodleQuestionsRepository(client: MoodleService.shared)
        ))
        _resourcesViewModel = StateObject(
            wrappedValue: MoodleResourcesViewModel(repository: resourcesRepository)
        )
        _attendanceViewModel = StateObject(wrappedValue: MoodleAttendanceViewModel())
        _gradesViewModel = StateObject(wrappedValue: MoodleGradesViewModel())
    }

    var body: some View {
        VStack(spacing: 0) {
            courseSummary
            tabBar

            TabView(selection: $viewModel.selectedTab) {
                ForEach(MoodleCourseDetailViewModel.Tab.allCases, id: \.self) { tab in
                    tabContent(for: tab)
                        .tag(tab)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(course.cleanName)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $viewModel.searchText,
                    placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: viewModel.searchPrompt)
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: viewModel.searchText, initial: true) { _, query in
            updateSearch(query)
        }
        .task(id: searchAnnouncement) {
            let announcement = searchAnnouncement
            guard let count = announcement.count, !announcement.query.isEmpty else { return }
            do {
                try await Task.sleep(for: .milliseconds(500))
                try Task.checkCancellation()
                AccessibilityNotification.Announcement("找到 \(count) 項\(announcement.tab.rawValue)").post()
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private struct SearchAnnouncement: Equatable {
        let query: String
        let tab: MoodleCourseDetailViewModel.Tab
        let count: Int?
    }

    private var searchAnnouncement: SearchAnnouncement {
        let count: Int?
        switch viewModel.selectedTab {
        case .announcements:
            count = announcementsViewModel.isLoading || announcementsViewModel.errorMessage != nil
                ? nil : announcementsViewModel.filteredDiscussions.count
        case .assignments:
            count = assignmentsViewModel.isLoading || assignmentsViewModel.errorMessage != nil
                ? nil : assignmentsViewModel.filteredAssignments.count
        case .questions:
            count = questionsViewModel.isLoading || questionsViewModel.errorMessage != nil
                ? nil : questionsViewModel.filteredSections.reduce(0) { $0 + $1.modules.count }
        case .resources:
            count = resourcesViewModel.isLoading || resourcesViewModel.errorMessage != nil
                ? nil : resourcesViewModel.filteredSections.reduce(0) { $0 + $1.modules.count }
        case .attendance:
            if case .loaded = attendanceViewModel.state, attendanceViewModel.lastErrorMessage == nil {
                count = attendanceViewModel.filteredSections.reduce(0) { $0 + $1.records.count }
            } else {
                count = nil
            }
        case .grades:
            count = gradesViewModel.isLoading || gradesViewModel.errorMessage != nil
                ? nil : gradesViewModel.filteredItems.count
        }
        return SearchAnnouncement(query: MoodleSearch.trimmed(viewModel.searchText),
                                  tab: viewModel.selectedTab, count: count)
    }

    private func updateSearch(_ query: String) {
        announcementsViewModel.searchText = query
        assignmentsViewModel.searchText = query
        questionsViewModel.searchText = query
        resourcesViewModel.searchText = query
        attendanceViewModel.searchText = query
        gradesViewModel.searchText = query
    }

    // MARK: - Tab Bar

    private var courseSummary: some View {
        HStack(spacing: 12) {
            Image(systemName: "book.closed.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 42, height: 42)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 3) {
                Text(course.cleanName)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 10) {
                    if let teacher = course.teacherName {
                        Label(teacher, systemImage: "person")
                    }
                    if let credits = course.credits {
                        Label("\(credits) 學分", systemImage: "book")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.top, Theme.Spacing.small)
    }

    private var tabBar: some View {
        // Keep all six destinations visible; larger text gets two rows.
        let columnCount = dynamicTypeSize >= .xxLarge ? 3 : 6
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 4, alignment: .top), count: columnCount),
            spacing: 6
        ) {
            ForEach(MoodleCourseDetailViewModel.Tab.allCases, id: \.self) { tab in
                Button {
                    selectTab(tab)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.iconName)
                            .font(.body.weight(.semibold))
                            .frame(height: tabIconHeight)
                        Text(tab.rawValue)
                            .font(.caption.weight(.semibold))
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(
                                minHeight: tabLabelLineHeight * (dynamicTypeSize.isAccessibilitySize ? 2 : 1),
                                alignment: .top
                            )
                    }
                    .foregroundStyle(viewModel.selectedTab == tab ? Color.accentColor : Color(.secondaryLabel))
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .glassEffect(
                    viewModel.selectedTab == tab
                        ? .regular.tint(Color.accentColor.opacity(0.12)).interactive()
                        : .regular.interactive(),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .overlay(alignment: .bottom) {
                    if viewModel.selectedTab == tab {
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: 16, height: 3)
                            .padding(.bottom, 3)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.rawValue)
                .accessibilityAddTraits(viewModel.selectedTab == tab ? .isSelected : [])
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    let translation = value.translation
                    guard value.startLocation.x > 24,
                          abs(translation.width) > 50,
                          abs(translation.width) > abs(translation.height) * 1.5 else { return }
                    selectAdjacentTab(offset: translation.width < 0 ? 1 : -1)
                }
        )
    }

    private func selectTab(_ tab: MoodleCourseDetailViewModel.Tab) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            viewModel.selectedTab = tab
        }
    }

    private func selectAdjacentTab(offset: Int) {
        let tabs = MoodleCourseDetailViewModel.Tab.allCases
        guard let currentIndex = tabs.firstIndex(of: viewModel.selectedTab) else { return }
        let nextIndex = currentIndex + offset
        guard tabs.indices.contains(nextIndex) else { return }
        selectTab(tabs[nextIndex])
    }

    // MARK: - Tab Content

    @ViewBuilder
    private func tabContent(for tab: MoodleCourseDetailViewModel.Tab) -> some View {
        switch tab {
        case .announcements:
            MoodleCourseAnnouncementsView(
                courseId: course.id,
                viewModel: announcementsViewModel
            )
        case .assignments:
            MoodleCourseAssignmentsView(
                courseId: course.id,
                viewModel: assignmentsViewModel
            )
        case .resources:
            MoodleCourseResourcesView(
                courseId: course.id,
                viewModel: resourcesViewModel,
                repository: resourcesRepository
            )
        case .questions:
            MoodleCourseQuestionsView(courseId: course.id, viewModel: questionsViewModel)
        case .attendance:
            MoodleCourseAttendanceView(courseId: course.id, viewModel: attendanceViewModel)
        case .grades:
            MoodleCourseGradesView(courseId: course.id, viewModel: gradesViewModel)
        }
    }
}
