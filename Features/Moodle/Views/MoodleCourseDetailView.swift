import SwiftUI

struct MoodleCourseDetailView: View {
    let course: MoodleCourse
    @StateObject private var viewModel: MoodleCourseDetailViewModel
    @StateObject private var announcementsViewModel: MoodleAnnouncementsViewModel
    @StateObject private var assignmentsViewModel: MoodleAssignmentsListViewModel
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

            tabContent
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(course.cleanName)
        .navigationBarTitleDisplayMode(.inline)
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
        HStack(spacing: 6) {
            ForEach(MoodleCourseDetailViewModel.Tab.allCases, id: \.self) { tab in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.selectedTab = tab
                    }
                }) {
                    VStack(spacing: 4) {
                        Image(systemName: tab.iconName)
                            .font(.system(size: 15, weight: .semibold))
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .foregroundStyle(viewModel.selectedTab == tab ? Color.accentColor : Color(.secondaryLabel))
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .frame(maxWidth: .infinity)
                .glassEffect(
                    viewModel.selectedTab == tab
                        ? .regular.tint(Color.accentColor.opacity(0.12)).interactive()
                        : .regular.interactive(),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .buttonStyle(.plain)
                .accessibilityAddTraits(viewModel.selectedTab == tab ? .isSelected : [])
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, 12)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch viewModel.selectedTab {
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
        case .attendance:
            MoodleCourseAttendanceView(courseId: course.id, viewModel: attendanceViewModel)
        case .grades:
            MoodleCourseGradesView(courseId: course.id, viewModel: gradesViewModel)
        }
    }
}
