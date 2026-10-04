import SwiftUI

struct MoodleUpcomingSection: View {
    @ObservedObject var model: MoodleUpcomingViewModel
    let submissionRepository: (any MoodleSubmissionRepositoryProtocol)?
    @State private var retry = 0
    @Binding var isExpanded: Bool
    let navigationOwner: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            DisclosureGroup(isExpanded: $isExpanded) {
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
            } label: {
                HStack(spacing: Theme.Spacing.small) {
                    Text("即將截止").font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if case .loaded = model.state {
                        Text("\(model.items.count)")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                            .fixedSize()
                    }
                }
            }
            .disclosureGroupStyle(MoodleUpcomingDisclosureStyle(status: accessibilityStatus))
            if !isExpanded, let collapsedStatus {
                Text(collapsedStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.CornerRadius.large))
        .task(id: retry) { if retry > 0 { await model.reload() } }
    }

    private var collapsedStatus: String? {
        switch model.state {
        case .loading: "正在載入待繳作業…"
        case .empty: "近兩週沒有待繳作業"
        case .failed: "載入失敗，展開後可重試"
        case .loaded: model.refreshError == nil ? nil : "更新失敗，保留上次資料；展開後可重試"
        }
    }

    private var accessibilityStatus: String {
        switch model.state {
        case .loading: "正在載入待繳作業"
        case .empty: "近兩週沒有待繳作業"
        case .failed: "載入失敗"
        case .loaded:
            model.refreshError == nil ? "\(model.items.count) 份待繳作業"
                : "更新失敗，保留上次的 \(model.items.count) 份待繳作業"
        }
    }
}

private struct MoodleUpcomingDisclosureStyle: DisclosureGroupStyle {
    let status: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Button {
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.36, dampingFraction: 0.88)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: Theme.Spacing.small) {
                    configuration.label
                    Spacer(minLength: Theme.Spacing.small)
                    Image(systemName: "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 0 : -90))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: configuration.isExpanded)
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("即將截止")
            .accessibilityValue("\(configuration.isExpanded ? "已展開" : "已收合")，\(status)")
            .accessibilityHint(configuration.isExpanded ? "收合待繳作業清單" : "展開待繳作業清單")

            if configuration.isExpanded {
                configuration.content
                    .transition(.opacity)
            }
        }
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
            if let message = model.refreshError {
                Label(message + " 保留上次資料。", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("重試", action: retry).frame(minWidth: 44, minHeight: 44)
            }
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
                if let assignment = model.assignment {
                    MoodleAssignmentView(assignment: assignment, repository: repository)
                }
            }
            .alert("無法開啟作業", isPresented: Binding(get: { model.navigationOwner == owner && model.navigationError != nil }, set: { if !$0 { model.navigationError = nil } })) {
                Button("好", role: .cancel) { model.navigationError = nil }
            } message: { Text(model.navigationError ?? "") }
            .onDisappear { model.cancelOpening() }
    }
}
