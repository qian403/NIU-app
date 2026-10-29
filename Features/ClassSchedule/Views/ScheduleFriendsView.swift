import SwiftUI

// MARK: - Shared pieces

/// "Now" for live statuses; fixed in UI fixtures so screenshots are reproducible.
enum ScheduleFriendsClock {
    static func now(_ date: Date = Date()) -> Date {
        #if DEBUG
        if ClassScheduleUIFixture.requested { return ClassScheduleUIFixture.now }
        #endif
        return date
    }
}

/// The user's displayed timetable as a comparison participant. Local only; nothing built here is shared.
enum ScheduleFriendsComparison {
    static func myPayload(_ schedule: ClassSchedule?, term: ScheduleShareTerm) -> ScheduleSharePayload? {
        guard let schedule else { return nil }
        let payload = ScheduleSharePayload(schedule: schedule, shareID: UUID(), term: term, nickname: "我",
                                           includeRooms: false, includeTeachers: false, createdAt: Date())
        return payload.periods.isEmpty ? nil : payload
    }

    static func dayLabel(_ day: Int, now: Date) -> String {
        let today = ScheduleSharePayload.clockPosition(of: now).day
        if day == today { return "今天" }
        if day == (today + 1) % 7 { return "明天" }
        return ScheduleFreeTime.weekdayNames[day]
    }

    static func timeRange(_ start: Int, _ end: Int) -> String {
        "\(ScheduleSharePayload.clockText(start))–\(ScheduleSharePayload.clockText(end))"
    }
}

/// Initial-letter avatar with a stable per-friend colour and an optional presence dot, like a game friend list.
struct FriendAvatar: View {
    let name: String
    /// nil is the user themself, drawn in the accent colour.
    let seed: String?
    var size: CGFloat = 44
    var status: ScheduleFriendStatus? = nil

    private static let palette: [Color] = [.blue, .teal, .orange, .pink, .green, .indigo, .purple, .brown]

    private var colour: Color {
        guard let seed else { return Theme.Colors.accent }
        return Self.palette[ClassScheduleWeekLayout.stableColourIndex(for: seed, paletteCount: Self.palette.count)]
    }

    var body: some View {
        Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)))
            .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(colour.gradient, in: Circle())
            .overlay(alignment: .bottomTrailing) {
                if let status {
                    Circle()
                        .fill(status.tint)
                        .frame(width: size * 0.3, height: size * 0.3)
                        .overlay { Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: max(2, size * 0.05)) }
                }
            }
            .accessibilityHidden(true)
    }
}

extension ScheduleFriendStatus {
    var tint: Color {
        switch self {
        case .free, .doneForToday, .noClassToday: Color(.systemGreen)
        case .inClass: Color(.systemOrange)
        case .notCovered, .expired, .upcomingTerm: Color(.systemGray)
        }
    }

    var symbol: String {
        switch self {
        case .free, .doneForToday, .noClassToday: "circle.fill"
        case .inClass: "book.closed.fill"
        case .notCovered: "questionmark.circle.fill"
        case .expired, .upcomingTerm: "clock.fill"
        }
    }

    var headline: String {
        switch self {
        case .free, .doneForToday, .noClassToday: "有空"
        case .inClass(let course, _, _): "上課中・\(course)"
        case .notCovered: "不確定"
        case .expired: "課表已過期"
        case .upcomingTerm: "下學期的課表"
        }
    }

    var detail: String? {
        switch self {
        case .free(let until): "\(ScheduleSharePayload.clockText(until)) 有課"
        case .doneForToday: "今天的課上完了"
        case .noClassToday: "今天沒課"
        case .inClass(_, let room, let until):
            ["到 \(ScheduleSharePayload.clockText(until))", room].compactMap { $0 }.joined(separator: "・")
        case .notCovered: "對方的課表沒有今天"
        case .expired: "請對方重新分享"
        case .upcomingTerm: "開學後會顯示狀態"
        }
    }
}

private struct StatusLine: View {
    let status: ScheduleFriendStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: status.symbol)
                .font(.system(size: status.isAvailable ? 7 : 11))
                .foregroundStyle(status.tint)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text("\(Text(status.headline).fontWeight(.medium).foregroundStyle(status.isAvailable ? Color(.systemGreen) : Theme.Colors.label))\(Text(status.detail.map { "・\($0)" } ?? "").foregroundStyle(Theme.Colors.secondaryLabel))")
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
    }
}

private struct FreeWindowRow: View {
    let window: ScheduleFreeWindow
    let now: Date

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ScheduleFriendsComparison.dayLabel(window.day, now: now))
                    .font(.subheadline.weight(.semibold))
                Text(ScheduleFriendsComparison.timeRange(window.start, window.end))
                    .font(.body.monospacedDigit())
            }
            Spacer(minLength: Theme.Spacing.xsmall)
            Text(window.durationText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(.systemGreen))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(.systemGreen).opacity(0.14), in: Capsule())
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Friends

/// Classmates added by QR code, each with a live status worked out on this device.
struct ScheduleFriendsView: View {
    @ObservedObject var exchange: ScheduleExchangeViewModel
    @ObservedObject var store: ScheduleExchangeStore
    /// The user's displayed timetable, custom courses included, for local comparison only.
    let mySchedule: ClassSchedule?

    @State private var addFriend: AddFriendRequest?
    @State private var openedFriend: UUID?
    @State private var pendingOpen: UUID?
    @State private var groupRequest: GroupRequest?
    @State private var pendingDelete: ExchangedSchedule?
    @State private var isConfirmingReset = false
    @State private var toast: String?
    @State private var appliedFixture = false

    private struct AddFriendRequest: Identifiable {
        let id = UUID()
        let tab: AddFriendSheet.Tab
    }

    struct GroupRequest: Hashable, Identifiable {
        let id = UUID()
        let selected: Set<UUID>
    }

    private var term: ScheduleShareTerm { exchange.currentTerm }
    private var canCompare: Bool { ScheduleFriendsComparison.myPayload(mySchedule, term: term) != nil }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = ScheduleFriendsClock.now(context.date)
            List {
                switch store.status {
                case .ready:
                    profileSection(now: now)
                    if store.schedules.isEmpty {
                        emptySection
                    } else {
                        friendSections(now: now)
                    }
                    #if DEBUG
                    sampleSection
                    #endif
                case .locked:
                    Section {
                        Label("裝置已鎖定，解鎖後才能讀取好友的課表。", systemImage: "lock")
                        Button("重試") { store.reload() }
                    }
                case .unreadable:
                    Section {
                        Label("好友的課表無法開啟，可能是裝置還原或鑰匙圈資料遺失。", systemImage: "exclamationmark.lock")
                        Button("清除這個帳號的好友課表", role: .destructive) { isConfirmingReset = true }
                    }
                case .signedOut:
                    Section {
                        Label("請先登入學校帳號。", systemImage: "person.crop.circle.badge.exclamationmark")
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("課表好友")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    addFriend = AddFriendRequest(tab: .scan)
                } label: {
                    Image(systemName: "person.badge.plus")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("加好友")
                .disabled(store.status != .ready)
            }
        }
        .sheet(item: $addFriend, onDismiss: {
            if let pendingOpen { openedFriend = pendingOpen }
            pendingOpen = nil
        }) { request in
            AddFriendSheet(vm: exchange, store: store, initialTab: request.tab) { id, name in
                pendingOpen = id
                toast = "已加入好友「\(name)」"
                addFriend = nil
            }
        }
        .navigationDestination(item: $openedFriend) { id in
            FriendDetailView(id: id, store: store, mySchedule: mySchedule, term: term)
        }
        .navigationDestination(item: $groupRequest) { request in
            GroupFreeTimeView(store: store, mySchedule: mySchedule, term: term, initial: request.selected)
        }
        .confirmationDialog(
            "刪除好友「\(pendingDelete?.displayName ?? "")」？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("刪除", role: .destructive) {
                if let pendingDelete { store.delete(id: pendingDelete.id) }
                pendingDelete = nil
            }
        } message: {
            Text("只會刪除這台裝置上的課表，對方不會收到通知。")
        }
        .confirmationDialog("清除後無法復原，確定要清除嗎？", isPresented: $isConfirmingReset, titleVisibility: .visible) {
            Button("清除", role: .destructive) { store.resetUnreadableData() }
        }
        .alert("無法完成", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, Theme.Spacing.medium)
                    .padding(.vertical, Theme.Spacing.small)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, Theme.Spacing.large)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear { UIAccessibility.post(notification: .announcement, argument: toast) }
            }
        }
        .animation(Theme.Animation.standard, value: toast)
        .task(id: toast) {
            guard toast != nil else { return }
            try? await Task.sleep(for: .seconds(2.5))
            toast = nil
        }
        .onAppear {
            store.reload()
            applyFixtureScenario()
        }
    }

    // MARK: Sections

    private func profileSection(now: Date) -> some View {
        let name = ScheduleSharePayload.cleanNickname(exchange.nickname)
        let current = store.schedules.filter { $0.payload.term == term }.count
        return Section {
            VStack(spacing: Theme.Spacing.medium) {
                HStack(spacing: Theme.Spacing.small) {
                    FriendAvatar(name: name.isEmpty ? "我" : name, seed: nil, size: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name.isEmpty ? "我" : name)
                            .font(.title3.weight(.bold))
                            .lineLimit(1)
                        Text(term.title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("\(current) 位好友")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button {
                        addFriend = AddFriendRequest(tab: .myCode)
                    } label: {
                        Image(systemName: "qrcode")
                            .font(.title2)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderless)
                    .disabled(exchange.schedule == nil)
                    .accessibilityLabel("我的 QR Code")
                }
                HStack(spacing: Theme.Spacing.small) {
                    Button {
                        addFriend = AddFriendRequest(tab: .scan)
                    } label: {
                        Label("加好友", systemImage: "person.badge.plus")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        groupRequest = GroupRequest(selected: [])
                    } label: {
                        Label("揪團找空堂", systemImage: "person.3.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canCompare || current == 0)
                }
            }
            .padding(.vertical, Theme.Spacing.xsmall)
        } footer: {
            if exchange.schedule == nil {
                Text("你的課表載入後，才能產生 QR Code 和找共同空堂。")
            }
        }
    }

    private var emptySection: some View {
        Section {
            VStack(spacing: Theme.Spacing.small) {
                Image(systemName: "person.2.wave.2.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.Colors.accent)
                    .padding(.top, Theme.Spacing.small)
                Text("還沒有好友")
                    .font(.headline)
                VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
                    Label("請同學也打開「課表好友」，按「加好友」", systemImage: "1.circle.fill")
                    Label("一人切到「我的 QR Code」，另一人掃描", systemImage: "2.circle.fill")
                    Label("加入後就能看到對方現在有沒有空", systemImage: "3.circle.fill")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, Theme.Spacing.xsmall)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, Theme.Spacing.xsmall)
        } footer: {
            Text("好友的課表只加密存在這台裝置，不會上傳。")
        }
    }

    @ViewBuilder
    private func friendSections(now: Date) -> some View {
        let entries = store.schedules
            .map { (entry: $0, status: $0.payload.status(at: now)) }
            .sorted { ($0.status.sortRank, $0.entry.displayName) < ($1.status.sortRank, $1.entry.displayName) }
        let groups: [(title: String, rows: [(entry: ExchangedSchedule, status: ScheduleFriendStatus)])] = [
            ("有空", entries.filter { $0.status.isAvailable }),
            ("上課中", entries.filter { if case .inClass = $0.status { true } else { false } }),
            ("不確定", entries.filter { $0.status == .notCovered }),
            ("其他學期", entries.filter { !$0.status.isCurrentTerm }),
        ]
        ForEach(groups.filter { !$0.rows.isEmpty }, id: \.title) { group in
            Section {
                ForEach(group.rows, id: \.entry.id) { row in
                    friendRow(row.entry, status: row.status)
                }
            } header: {
                Text("\(group.title)・\(group.rows.count)")
            } footer: {
                if group.title == "其他學期" { Text("過期的課表會在學期結束 30 天後自動刪除。") }
            }
        }
    }

    private func friendRow(_ entry: ExchangedSchedule, status: ScheduleFriendStatus) -> some View {
        Button {
            openedFriend = entry.id
        } label: {
            HStack(spacing: Theme.Spacing.small) {
                FriendAvatar(name: entry.displayName, seed: entry.payload.shareID.uuidString, size: 46, status: status)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.Colors.label)
                        .lineLimit(1)
                    if status.isCurrentTerm {
                        StatusLine(status: status)
                    } else {
                        Text("\(entry.payload.term.title)・\(status.headline)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.displayName)，\(status.headline)\(status.detail.map { "，\($0)" } ?? "")")
        .accessibilityHint("查看好友")
        .swipeActions {
            Button("刪除", role: .destructive) { pendingDelete = entry }
        }
        .contextMenu {
            Button("刪除好友", systemImage: "trash", role: .destructive) { pendingDelete = entry }
        }
    }

    #if DEBUG
    private var sampleSection: some View {
        Section("測試資料") {
            Button("加入假好友", systemImage: "person.3.fill") {
                let periods = ScheduleFriendsComparison.myPayload(mySchedule, term: term)?.periods ?? []
                for payload in ScheduleExchangeSamples.classmates(term: term, periods: periods) {
                    store.save(payload, replacing: store.existing(matching: payload)?.id)
                }
            }
            Button("移除假好友", systemImage: "trash", role: .destructive) {
                for id in store.schedules.filter({ ScheduleExchangeSamples.isSample($0.payload) }).map(\.id) {
                    store.delete(id: id)
                }
            }
        }
    }
    #endif

    private func applyFixtureScenario() {
        #if DEBUG
        guard ClassScheduleUIFixture.requested, !appliedFixture else { return }
        appliedFixture = true
        let friends = store.schedules.filter { $0.payload.term == term }.sorted { $0.displayName < $1.displayName }
        switch ClassScheduleUIFixture.scenario {
        case "exchange-share": addFriend = AddFriendRequest(tab: .myCode)
        case "exchange-scan": addFriend = AddFriendRequest(tab: .scan)
        case "exchange-friend": openedFriend = friends.first?.id
        case "exchange-group": groupRequest = GroupRequest(selected: Set(friends.prefix(3).map(\.id)))
        default: break
        }
        #endif
    }
}

// MARK: - Friend

struct FriendDetailView: View {
    let id: UUID
    @ObservedObject var store: ScheduleExchangeStore
    let mySchedule: ClassSchedule?
    let term: ScheduleShareTerm
    @State private var isConfirmingDelete = false
    @State private var showsAllWindows = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let entry = store.schedules.first(where: { $0.id == id }) {
            TimelineView(.everyMinute) { context in
                content(entry, now: ScheduleFriendsClock.now(context.date))
            }
            .navigationTitle(entry.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("刪除好友「\(entry.displayName)」？", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button("刪除", role: .destructive) {
                    if store.delete(id: entry.id) { dismiss() }
                }
            } message: {
                Text("只會刪除這台裝置上的課表，對方不會收到通知。")
            }
        } else {
            ContentUnavailableView("這位好友已刪除", systemImage: "person.crop.circle.badge.xmark")
        }
    }

    private func content(_ entry: ExchangedSchedule, now: Date) -> some View {
        let payload = entry.payload
        let status = payload.status(at: now)
        let mine = ScheduleFriendsComparison.myPayload(mySchedule, term: term)
        return List {
            Section {
                VStack(spacing: Theme.Spacing.xsmall) {
                    FriendAvatar(name: entry.displayName, seed: payload.shareID.uuidString, size: 76, status: status)
                    Text(entry.displayName)
                        .font(.title2.weight(.bold))
                    Text(payload.term.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if status.isCurrentTerm {
                        StatusLine(status: status)
                            .padding(.horizontal, Theme.Spacing.small)
                            .padding(.vertical, 6)
                            .background(status.tint.opacity(0.12), in: Capsule())
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .accessibilityElement(children: .combine)
            }

            if status.isCurrentTerm {
                todaySection(payload, status: status, now: now)
                freeSection(payload, mine: mine, now: now)
            } else {
                Section {
                    Text(status == .expired ? "這份課表的學期已經結束。想繼續看對方的課表，請對方重新分享。"
                                            : "這是下學期的課表，開學後才會顯示對方的狀態和共同空堂。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                NavigationLink {
                    FriendTimetableView(entry: entry, mySchedule: mySchedule, term: term)
                } label: {
                    Label("查看完整課表", systemImage: "calendar")
                        .frame(minHeight: 44)
                }
                if status.isCurrentTerm, mine != nil {
                    NavigationLink {
                        GroupFreeTimeView(store: store, mySchedule: mySchedule, term: term, initial: [entry.id])
                    } label: {
                        Label("找更多人一起揪團", systemImage: "person.3.fill")
                            .frame(minHeight: 44)
                    }
                }
            } footer: {
                Text("對方分享了：\(sharedFields(payload))。加入於 \(entry.importedAt.formatted(.dateTime.month().day()))。")
            }

            Section {
                Button("刪除好友", role: .destructive) { isConfirmingDelete = true }
                    .frame(minHeight: 44)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func todaySection(_ payload: ScheduleSharePayload, status: ScheduleFriendStatus, now: Date) -> some View {
        let (day, minute) = ScheduleSharePayload.clockPosition(of: now)
        let blocks = payload.classBlocks(on: day)
        return Section("今天的課") {
            if status == .notCovered {
                Text("對方的課表沒有\(ScheduleFreeTime.weekdayNames[day])，不確定有沒有課。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if blocks.isEmpty {
                Text("今天沒課")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(blocks, id: \.start) { block in
                    let isNow = block.start <= minute && minute < block.end
                    let isPast = block.end <= minute
                    HStack(spacing: Theme.Spacing.small) {
                        Text(ScheduleFriendsComparison.timeRange(block.start, block.end))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(isNow ? Color(.systemOrange) : Theme.Colors.secondaryLabel)
                            .frame(width: 104, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(block.name)
                                .font(.body.weight(isNow ? .semibold : .regular))
                            if let room = block.room {
                                Text(room).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        if isNow {
                            Text("上課中")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color(.systemOrange))
                        }
                    }
                    .opacity(isPast ? 0.45 : 1)
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(isNow ? "上課中" : (isPast ? "已結束" : ""))
                }
            }
        }
    }

    @ViewBuilder
    private func freeSection(_ payload: ScheduleSharePayload, mine: ScheduleSharePayload?, now: Date) -> some View {
        Section {
            if let mine {
                let windows = ScheduleFreeTime.upcoming(ScheduleFreeTime.windows(base: mine, others: [payload]), at: now)
                if windows.isEmpty {
                    Text("這週找不到你們都有空的時段。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(showsAllWindows ? windows : Array(windows.prefix(4))) { window in
                        FreeWindowRow(window: window, now: now)
                    }
                    if windows.count > 4 {
                        Button(showsAllWindows ? "收合" : "顯示全部 \(windows.count) 段") {
                            withAnimation(Theme.Animation.standard) { showsAllWindows.toggle() }
                        }
                        .frame(minHeight: 44)
                    }
                }
            } else {
                Text("你的課表載入後，才能找你們的共同空堂。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("你們的共同空堂")
        } footer: {
            if mine != nil { Text("依你的課表（含自訂課程）和對方分享的課表計算；對方課表沒有的時段不算有空。") }
        }
    }

    private func sharedFields(_ payload: ScheduleSharePayload) -> String {
        var fields = ["時間", "課名"]
        if payload.hasRooms { fields.append("教室") }
        if payload.hasTeachers { fields.append("教師") }
        return fields.joined(separator: "、")
    }
}

/// A friend's full week, optionally marking times you are both free.
private struct FriendTimetableView: View {
    let entry: ExchangedSchedule
    let mySchedule: ClassSchedule?
    let term: ScheduleShareTerm
    @State private var marksFreeTime = true

    var body: some View {
        let payload = entry.payload
        let mine = payload.term == term ? ScheduleFriendsComparison.myPayload(mySchedule, term: term) : nil
        let headers = CustomCourse.weekdayHeaders.enumerated()
            .filter { $0.offset < 5 || payload.days.contains($0.offset) }.map(\.element)
        VStack(spacing: 0) {
            if mine != nil {
                Toggle(isOn: $marksFreeTime) {
                    HStack(spacing: Theme.Spacing.xsmall) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(.systemGreen).opacity(0.3))
                            .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(Color(.systemGreen), lineWidth: 1) }
                            .frame(width: 16, height: 16)
                            .accessibilityHidden(true)
                        Text("標出你們都有空的時段")
                            .font(.subheadline)
                    }
                }
                .tint(Color(.systemGreen))
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.vertical, Theme.Spacing.xsmall)
            }
            ClassScheduleWeekView(
                schedule: payload.classSchedule,
                displayDayHeaders: headers,
                isRefreshing: false,
                cacheAgeText: nil,
                refresh: {},
                editCustomCourse: { _ in },
                isReadOnly: true,
                freeSlots: marksFreeTime ? mine.map { payload.freeSlots(with: [$0]) } : nil
            )
        }
        .background(Theme.Colors.groupedBackground)
        .navigationTitle("\(entry.displayName) 的課表")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Group

/// Pick friends like inviting a party, then see when everyone is free.
struct GroupFreeTimeView: View {
    @ObservedObject var store: ScheduleExchangeStore
    let mySchedule: ClassSchedule?
    let term: ScheduleShareTerm
    @State private var selected: Set<UUID>
    @State private var showsGrid = false

    init(store: ScheduleExchangeStore, mySchedule: ClassSchedule?, term: ScheduleShareTerm, initial: Set<UUID>) {
        self.store = store
        self.mySchedule = mySchedule
        self.term = term
        _selected = State(initialValue: initial)
    }

    private var friends: [ExchangedSchedule] {
        store.schedules.filter { $0.payload.term == term }.sorted { $0.displayName < $1.displayName }
    }

    var body: some View {
        let mine = ScheduleFriendsComparison.myPayload(mySchedule, term: term)
        let chosen = friends.filter { selected.contains($0.id) }
        TimelineView(.everyMinute) { context in
            let now = ScheduleFriendsClock.now(context.date)
            VStack(spacing: 0) {
                partyBar
                if mine != nil, !chosen.isEmpty {
                    Picker("顯示方式", selection: $showsGrid) {
                        Text("空堂時段").tag(false)
                        Text("課表格子").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, Theme.Spacing.medium)
                    .padding(.vertical, Theme.Spacing.xsmall)
                }
                if let mine, let mySchedule {
                    if chosen.isEmpty {
                        ContentUnavailableView("選幾位好友", systemImage: "person.3",
                                               description: Text("點上面的頭像，選要一起約的人。"))
                    } else if showsGrid {
                        grid(schedule: mySchedule, mine: mine, others: chosen.map(\.payload))
                    } else {
                        windowList(mine: mine, others: chosen.map(\.payload), count: chosen.count + 1, now: now)
                    }
                } else {
                    ContentUnavailableView("課表還沒載入", systemImage: "calendar.badge.exclamationmark",
                                           description: Text("你的課表載入後，才能找共同空堂。"))
                }
            }
        }
        .background(Theme.Colors.groupedBackground)
        .navigationTitle("揪團找空堂")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(selected.count == friends.count ? "全不選" : "全選") {
                    withAnimation(Theme.Animation.fast) {
                        selected = selected.count == friends.count ? [] : Set(friends.map(\.id))
                    }
                }
                .disabled(friends.isEmpty)
            }
        }
    }

    private var partyBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: Theme.Spacing.small) {
                member(name: "我", seed: nil, isSelected: true)
                    .accessibilityLabel("我，一定會包含")
                ForEach(friends) { friend in
                    let isOn = selected.contains(friend.id)
                    Button {
                        withAnimation(Theme.Animation.fast) {
                            if isOn { selected.remove(friend.id) } else { selected.insert(friend.id) }
                        }
                    } label: {
                        member(name: friend.displayName, seed: friend.payload.shareID.uuidString, isSelected: isOn)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(friend.displayName)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)
        }
        .background(Color(.secondarySystemGroupedBackground))
    }

    private func member(name: String, seed: String?, isSelected: Bool) -> some View {
        VStack(spacing: 6) {
            FriendAvatar(name: name, seed: seed, size: 52)
                .padding(3)
                .overlay {
                    Circle().strokeBorder(isSelected ? Theme.Colors.accent : Color.clear, lineWidth: 2.5)
                }
                .overlay(alignment: .topTrailing) {
                    if isSelected, seed != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Theme.Colors.accent)
                    }
                }
                .opacity(isSelected ? 1 : 0.55)
            Text(name)
                .font(.caption)
                .foregroundStyle(isSelected ? Theme.Colors.label : Theme.Colors.secondaryLabel)
                .lineLimit(1)
        }
        .frame(width: 66)
        .contentShape(Rectangle())
    }

    private func windowList(mine: ScheduleSharePayload, others: [ScheduleSharePayload], count: Int, now: Date) -> some View {
        let windows = ScheduleFreeTime.upcoming(ScheduleFreeTime.windows(base: mine, others: others), at: now)
        let days = windows.reduce(into: [Int]()) { if $0.last != $1.day { $0.append($1.day) } }
        return List {
            if windows.isEmpty {
                Section {
                    Text("這週找不到 \(count) 人都有空的時段，試著少選幾個人。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(days, id: \.self) { day in
                    Section(ScheduleFriendsComparison.dayLabel(day, now: now)) {
                        ForEach(windows.filter { $0.day == day }) { window in
                            HStack {
                                Text(ScheduleFriendsComparison.timeRange(window.start, window.end))
                                    .font(.body.monospacedDigit())
                                Spacer()
                                Text(window.durationText)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color(.systemGreen))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color(.systemGreen).opacity(0.14), in: Capsule())
                            }
                            .frame(minHeight: 44)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            Section {
            } footer: {
                Text("\(count) 人都有空的時段，依你的課表（含自訂課程）計算。只比對\(term.title)；誰的課表沒有涵蓋的時段，不算有空。")
            }
        }
        .listStyle(.insetGrouped)
    }

    private func grid(schedule: ClassSchedule, mine: ScheduleSharePayload, others: [ScheduleSharePayload]) -> some View {
        // `mine` skips periods whose times did not parse, so map its rows back by period ID.
        let rows = mine.periods.map { period in schedule.periods.firstIndex { $0.id == period.id } }
        let slots = Set(mine.freeSlots(with: others).compactMap { key in rows[key % 100].map { key / 100 * 100 + $0 } })
        let headers = CustomCourse.weekdayHeaders.enumerated()
            .filter { $0.offset < 5 || schedule.dayHeaders.contains($0.element) }.map(\.element)
        return ClassScheduleWeekView(
            schedule: schedule,
            displayDayHeaders: headers,
            isRefreshing: false,
            cacheAgeText: nil,
            refresh: {},
            editCustomCourse: { _ in },
            isReadOnly: true,
            freeSlots: slots
        )
    }
}
