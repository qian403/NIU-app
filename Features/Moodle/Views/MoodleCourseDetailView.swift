import SwiftUI

struct MoodleCourseDetailView: View {
    let course: MoodleCourse
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var viewModel: MoodleCourseDetailViewModel
    @State private var selectedAssignment: MoodleAssignment?

    init(course: MoodleCourse, repositories: MoodleDetailRepositories? = nil, initialQuery: String = "") {
        self.course = course
        _viewModel = StateObject(wrappedValue: MoodleCourseDetailViewModel(
            course: course, repositories: repositories ?? .live, initialQuery: initialQuery))
    }

    init(model: MoodleCourseDetailViewModel) {
        course = model.course
        _viewModel = StateObject(wrappedValue: model)
    }

    private var isSearching: Bool { !MoodleSearch.trimmed(viewModel.searchText).isEmpty }

    var body: some View {
        List {
            if isSearching {
                searchResults
            } else {
                overview
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(course.shortname.htmlDecoded)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $viewModel.searchText,
                    placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜尋整門課")
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await viewModel.refresh() }
        .onAppear { viewModel.updateSearch() }
        .task { await viewModel.loadOverview() }
        // Editing the query filters locally; only entering/leaving search changes its task.
        .task(id: isSearching) { if isSearching { await viewModel.loadSearchExtras() } }
        .navigationDestination(isPresented: Binding(
            get: { selectedAssignment != nil }, set: { if !$0 { selectedAssignment = nil } }
        )) {
            if let assignment = selectedAssignment {
                MoodleAssignmentView(assignment: assignment, repository: viewModel.repositories.submission) { submitted in
                    viewModel.assignments.updateSubmission(assignmentID: assignment.id, submitted: submitted)
                }
            }
        }
    }

    @ViewBuilder private var overview: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(course.cleanName).font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
                if let teacher = course.teacherName {
                    Text(teacher).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            TimelineView(.periodic(from: .now, by: 60)) { context in
                summary(now: context.date)
            }
        }
        Section("待繳作業") {
            MoodleCourseSectionStatus(model: viewModel, destination: .assignments)
            if viewModel.assignments.hasLoaded {
                if viewModel.pendingAssignments.isEmpty {
                    Text("沒有待繳作業").foregroundStyle(.secondary).frame(minHeight: 44)
                } else {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        // A VStack keeps the shared upcoming row's layout stable in List.
                        VStack(spacing: 8) {
                            ForEach(viewModel.pendingPreview) { assignment in
                                pendingRow(assignment, now: context.date)
                                if assignment.id != viewModel.pendingPreview.last?.id { Divider() }
                            }
                        }
                    }
                    if viewModel.pendingAssignments.count > 3 {
                        pageLink(.assignments, title: "查看全部作業（\(viewModel.pendingAssignments.count)）")
                    }
                }
            }
        }
        Section("最新公告") {
            MoodleCourseSectionStatus(model: viewModel, destination: .announcements)
            if viewModel.announcements.hasLoaded {
                if viewModel.latestAnnouncements.isEmpty {
                    Text("目前沒有公告").foregroundStyle(.secondary).frame(minHeight: 44)
                }
                ForEach(viewModel.latestAnnouncements) { discussion in
                    NavigationLink {
                        MoodleForumView(discussion: discussion, repository: viewModel.repositories.posts)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(discussion.subject).font(.headline).fixedSize(horizontal: false, vertical: true)
                            Text("\(discussion.userfullname)・\(MoodlePresentation.relativeTime(discussion.timeModifiedDate))")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44)
                        .accessibilityElement(children: .combine)
                    }
                }
                pageLink(.announcements, title: "查看全部公告")
            }
        }
        Section("課程內容") {
            ForEach(MoodleCourseDetailViewModel.Destination.allCases) { destination in
                NavigationLink {
                    MoodleCoursePage(model: viewModel, destination: destination)
                } label: {
                    let detail = viewModel.detail(destination)
                    let layout = dynamicTypeSize > .large
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                        : AnyLayout(HStackLayout(spacing: 12))
                    layout {
                        Label(destination.rawValue, systemImage: destination.iconName)
                        if dynamicTypeSize <= .large { Spacer(minLength: 4) }
                        if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
                    }
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel([destination.rawValue, detail].compactMap { $0 }.joined(separator: "，"))
                }
                if destination == .attendance || destination == .grades {
                    MoodleCourseSectionStatus(model: viewModel, destination: destination)
                }
            }
        }
    }

    private func summary(now: Date) -> some View {
        let layout = dynamicTypeSize > .large
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        return layout {
            summaryValue("下一份待繳", value: viewModel.error(.assignments) != nil
                         ? "暫時無法更新" : viewModel.nextDeadline(now: now))
            if let percent = viewModel.attendancePercent {
                summaryValue("出席率", value: "\(percent)%")
            }
            if let grade = viewModel.currentGrade {
                summaryValue("目前成績", value: grade)
            }
        }
        .padding(.vertical, 4)
    }

    private func summaryValue(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func pendingRow(_ assignment: MoodleAssignment, now: Date) -> some View {
        if let due = assignment.dueDateValue {
            MoodleUpcomingRow(item: MoodleUpcomingItem(assignmentID: assignment.id, courseID: course.id,
                name: assignment.name, courseName: course.cleanName, dueDate: due), now: now,
                opening: false, action: { selectedAssignment = assignment }, showsCourseName: false)
        } else {
            Button { selectedAssignment = assignment } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(assignment.name).font(.headline)
                    Label("未設定截止日", systemImage: "clock").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("開啟作業詳情")
        }
    }

    private func pageLink(_ destination: MoodleCourseDetailViewModel.Destination, title: String, query: String = "") -> some View {
        NavigationLink {
            MoodleCoursePage(model: viewModel, destination: destination, initialQuery: query)
        } label: {
            Text(title).frame(minHeight: 44)
        }
    }

    @ViewBuilder private var searchResults: some View {
        let groups = viewModel.searchGroups
        if viewModel.searchComplete && groups.allSatisfy({ $0.count == 0 }) {
            ContentUnavailableView.search(text: viewModel.searchText)
                .listRowBackground(Color.clear)
        } else {
            ForEach(groups) { group in
                if group.count > 0 || !viewModel.hasSearchLoaded(group.destination)
                    || viewModel.error(group.destination) != nil || viewModel.isLoading(group.destination) {
                    Section {
                        MoodleCourseSectionStatus(model: viewModel, destination: group.destination)
                        ForEach(group.preview) { result in
                            NavigationLink {
                                MoodleCoursePage(model: viewModel, destination: group.destination,
                                                 initialQuery: viewModel.searchText)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(result.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                                    Text(result.subtitle).font(.subheadline).foregroundStyle(.secondary)
                                }
                                .frame(minHeight: 44)
                                .accessibilityElement(children: .combine)
                            }
                        }
                        if group.count > 0 {
                            pageLink(group.destination, title: viewModel.hasSearchLoaded(group.destination)
                                     ? "查看全部\(group.destination.rawValue)（\(group.count)）" : "查看全部\(group.destination.rawValue)",
                                     query: viewModel.searchText)
                        }
                    } header: {
                        Text(viewModel.hasSearchLoaded(group.destination)
                             ? "\(group.destination.rawValue)（\(group.count)）" : group.destination.rawValue)
                    }
                }
            }
        }
    }
}

/// View-owned retry task is cancelled on disappearance; one failure never hides
/// other sections or discards previously loaded data.
private struct MoodleCourseSectionStatus: View {
    @ObservedObject var model: MoodleCourseDetailViewModel
    let destination: MoodleCourseDetailViewModel.Destination
    @State private var retryID = 0
    var body: some View {
        Group {
            if model.isLoading(destination) || (!model.hasLoaded(destination) && model.error(destination) == nil) {
                ProgressView("正在載入\(destination.rawValue)…").font(.subheadline).frame(minHeight: 44)
            } else if model.error(destination) != nil {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        failureLabel
                        Spacer()
                        retryButton
                    }
                    VStack(alignment: .leading) { failureLabel; retryButton }
                }
                .font(.subheadline)
            }
        }
        .task(id: retryID) { if retryID > 0 { await model.retry(destination) } }
    }
    private var failureLabel: some View {
        Label("\(destination.rawValue)更新失敗\(model.hasLoaded(destination) ? "，保留上次資料" : "")",
              systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
    }
    private var retryButton: some View {
        Button("重試") { retryID += 1 }.frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("重試載入\(destination.rawValue)")
    }
}

/// Constructed only after a push (also used as a fixture root).
struct MoodleCoursePage: View {
    @ObservedObject var model: MoodleCourseDetailViewModel
    let destination: MoodleCourseDetailViewModel.Destination
    var initialQuery = ""
    @State private var didSetQuery = false

    var body: some View {
        content.onAppear {
            guard !didSetQuery else { return }
            didSetQuery = true
            switch destination {
            case .assignments: model.assignments.searchText = initialQuery
            case .announcements: model.announcements.searchText = initialQuery
            case .resources: model.resourcesModel().searchText = initialQuery
            case .questions: model.questionsModel().searchText = initialQuery
            case .attendance: model.attendance.searchText = initialQuery
            case .grades: model.grades.searchText = initialQuery
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch destination {
        case .assignments:
            MoodleCourseAssignmentsView(courseId: model.course.id, viewModel: model.assignments,
                                        submissionRepository: model.repositories.submission)
        case .announcements:
            MoodleCourseAnnouncementsView(courseId: model.course.id, viewModel: model.announcements,
                                          postsRepository: model.repositories.posts)
        case .resources:
            MoodleCourseResourcesView(courseId: model.course.id, viewModel: model.resourcesModel(),
                                      repository: model.repositories.resources)
        case .questions:
            MoodleCourseQuestionsView(courseId: model.course.id, viewModel: model.questionsModel())
        case .attendance:
            MoodleCourseAttendanceView(courseId: model.course.id, viewModel: model.attendance)
        case .grades:
            MoodleCourseGradesView(courseId: model.course.id, viewModel: model.grades)
        }
    }
}
