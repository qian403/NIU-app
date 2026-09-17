import SwiftUI

/// Attendance tab embedded in a Moodle course.
struct MoodleCourseAttendanceView: View {
    let courseId: Int
    @ObservedObject var viewModel: MoodleAttendanceViewModel

    var body: some View {
        MoodleAttendanceContent(
            state: viewModel.state,
            sections: viewModel.sections,
            refreshError: viewModel.lastErrorMessage,
            retry: { await viewModel.loadCourse(courseId, force: true) }
        )
        .task { await viewModel.loadCourse(courseId) }
        .refreshable { await viewModel.loadCourse(courseId, force: true) }
    }
}

/// Attendance detail opened from a Moodle course resource module.
struct MoodleAttendanceModuleDetailView: View {
    let module: MoodleModule
    let presetAttendanceId: Int?
    let courseModuleId: Int?

    @StateObject private var viewModel: MoodleAttendanceViewModel

    init(
        module: MoodleModule,
        presetAttendanceId: Int? = nil,
        courseModuleId: Int? = nil,
        repository: (any MoodleAttendanceRepositoryProtocol)? = nil
    ) {
        self.module = module
        self.presetAttendanceId = presetAttendanceId
        self.courseModuleId = courseModuleId
        _viewModel = StateObject(wrappedValue: MoodleAttendanceViewModel(repository: repository))
    }

    var body: some View {
        MoodleAttendanceContent(
            state: viewModel.state,
            sections: viewModel.sections,
            refreshError: viewModel.lastErrorMessage,
            retry: { await load(force: true) }
        )
        .navigationTitle(module.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load(force: true) }
    }

    private func load(force: Bool = false) async {
        await viewModel.loadModule(
            module,
            attendanceId: presetAttendanceId,
            courseModuleId: courseModuleId,
            force: force
        )
    }
}
