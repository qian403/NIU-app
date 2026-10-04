import SwiftUI

struct MoodleUpcomingSection: View {
    @ObservedObject var model: MoodleUpcomingViewModel
    let submissionRepository: (any MoodleSubmissionRepositoryProtocol)?
    @State private var retry = 0
    let navigationOwner: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("即將截止").font(.title3.weight(.semibold))
            MoodleUpcomingContent(model: model, retry: { retry += 1 }) {
                ForEach(model.preview(limit: 5)) { item in
                    MoodleUpcomingRow(item: item, now: model.now, opening: model.openingID == item.id) { model.open(item, owner: navigationOwner) }
                    if item.id != model.preview(limit: 5).last?.id { Divider() }
                }
                if model.items.count > 5 {
                    NavigationLink {
                        MoodleUpcomingListView(model: model, submissionRepository: submissionRepository)
                    } label: {
                        HStack {
                            Text("查看全部（\(model.items.count)）")
                            Spacer()
                            Image(systemName: "chevron.right").accessibilityHidden(true)
                        }
                        .font(.subheadline.weight(.medium))
                        .frame(minHeight: 44)
                    }
                }
            }
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.CornerRadius.large))
        .task(id: retry) { if retry > 0 { await model.reload() } }
    }
}

struct MoodleUpcomingListView: View {
    @ObservedObject var model: MoodleUpcomingViewModel
    let submissionRepository: (any MoodleSubmissionRepositoryProtocol)?
    @State private var retry = 0
    @State private var navigationOwner = UUID()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                Text("逾期 7 天內與未來 14 天的待繳作業")
                    .font(.footnote).foregroundStyle(.secondary)
                MoodleUpcomingContent(model: model, retry: { retry += 1 }) {
                    ForEach(model.grouped, id: \.group) { section in
                        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                            Text(section.group.rawValue).font(.headline).accessibilityAddTraits(.isHeader)
                            ForEach(section.items) { item in
                                MoodleUpcomingRow(item: item, now: model.now, opening: model.openingID == item.id) { model.open(item, owner: navigationOwner) }
                                if item.id != section.items.last?.id { Divider() }
                            }
                        }
                        .padding(Theme.Spacing.medium)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.CornerRadius.large))
                    }
                }
            }
            .padding(Theme.Spacing.medium)
        }
        .background(Theme.Colors.groupedBackground.ignoresSafeArea())
        .navigationTitle("即將截止")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.reload() }
        .task(id: retry) { if retry > 0 { await model.reload() } }
        .modifier(MoodleUpcomingNavigation(model: model, repository: submissionRepository, owner: navigationOwner))
    }
}

private struct MoodleUpcomingContent<Content: View>: View {
    @ObservedObject var model: MoodleUpcomingViewModel
    let retry: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        switch model.state {
        case .loading:
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    Text("作業名稱與繳交期限").font(.headline)
                    Text("明天 18:00 · 課程名稱").font(.subheadline)
                }
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                .redacted(reason: .placeholder)
                .accessibilityHidden(true)
            }
            Text("載入待繳作業中…").font(.footnote).foregroundStyle(.secondary)
        case .empty:
            Label("近兩週沒有待繳作業", systemImage: "checkmark.circle")
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(.vertical, Theme.Spacing.small)
        case .failed(let message):
            ViewThatFits(in: .horizontal) {
                HStack {
                    Label(message, systemImage: "exclamationmark.triangle").fixedSize()
                    Button("重試", action: retry).frame(minWidth: 44, minHeight: 44)
                }
                VStack(alignment: .leading) {
                    Label(message, systemImage: "exclamationmark.triangle")
                    Button("重試", action: retry).frame(minWidth: 44, minHeight: 44)
                }
            }
            .font(.subheadline)
        case .loaded:
            content()
        }
    }
}

struct MoodleUpcomingRow: View {
    let item: MoodleUpcomingItem
    let now: Date
    let opening: Bool
    let action: () -> Void
    var showsCourseName = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var group: MoodleUpcomingGroup { MoodleUpcomingRules.group(due: item.dueDate, now: now) }
    private var urgent: Bool { group == .overdue || group == .today }
    private var metadataLayout: AnyLayout {
        // 同一字級採用同一版面，不因個別作業或課程名稱長度改變截止提示位置。
        dynamicTypeSize > .large
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 4))
    }
    private var deadline: some View {
        Label {
            Text(MoodlePresentation.upcomingDeadline(item.dueDate, now: now))
        } icon: {
            Image(systemName: group == .overdue ? "exclamationmark.circle" : "clock")
        }
        .font(.subheadline)
        .foregroundStyle(urgent ? (group == .overdue ? Color.red : Color.orange) : Color.secondary)
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
    }
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.name).font(.headline).lineLimit(2)
                metadataLayout {
                    deadline
                    if showsCourseName {
                        if dynamicTypeSize <= .large {
                            Text("·").foregroundStyle(.secondary)
                        }
                        Text(item.courseName)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .font(.subheadline)
                if opening { Text("正在開啟…").font(.caption).foregroundStyle(.secondary) }
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.vertical, Theme.Spacing.xsmall)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name)，\(showsCourseName ? item.courseName + "，" : "")截止：\(MoodlePresentation.upcomingDeadline(item.dueDate, now: now, accessibility: true))")
        .accessibilityHint(opening ? "正在開啟作業" : "開啟作業詳情")
    }
}

struct MoodleUpcomingNavigation: ViewModifier {
    @ObservedObject var model: MoodleUpcomingViewModel
    let repository: (any MoodleSubmissionRepositoryProtocol)?
    let owner: UUID
    func body(content: Content) -> some View {
        content
            .navigationDestination(isPresented: Binding(get: { model.navigationOwner == owner && model.assignment != nil }, set: { if !$0 { model.assignment = nil } })) {
                if let assignment = model.assignment { MoodleAssignmentView(assignment: assignment, repository: repository) }
            }
            .alert("無法開啟作業", isPresented: Binding(get: { model.navigationOwner == owner && model.navigationError != nil }, set: { if !$0 { model.navigationError = nil } })) {
                Button("好", role: .cancel) { model.navigationError = nil }
            } message: { Text(model.navigationError ?? "") }
            .onDisappear { model.cancelOpening() }
    }
}
