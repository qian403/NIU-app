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

    /// The first stretch from now on when the user and everyone in `others` are free.
    static func nextWindow(mine: ScheduleSharePayload?, others: [ScheduleSharePayload], now: Date) -> ScheduleFreeWindow? {
        guard let mine else { return nil }
        return ScheduleFreeTime.upcoming(ScheduleFreeTime.windows(base: mine, others: others), at: now).first
    }

    static func isNow(_ window: ScheduleFreeWindow, at now: Date) -> Bool {
        let (day, minute) = ScheduleSharePayload.clockPosition(of: now)
        return window.day == day && window.start <= minute
    }

    /// "現在到 12:00" or "明天 12:10".
    static func whenText(_ window: ScheduleFreeWindow, at now: Date) -> String {
        isNow(window, at: now) ? "現在到 \(ScheduleSharePayload.clockText(window.end))"
            : "\(dayLabel(window.day, now: now)) \(ScheduleSharePayload.clockText(window.start))"
    }

    /// "我的第 2 節", "下課時間"… for the header of the friends page.
    static func myMoment(_ mine: ScheduleSharePayload?, at now: Date) -> String {
        guard let mine else { return "課表還沒載入" }
        switch mine.status(at: now) {
        case .inClass(let course, _, let until): return "你在上\(course)，到 \(ScheduleSharePayload.clockText(until))"
        case .free(let until): return "你 \(ScheduleSharePayload.clockText(until)) 才有課"
        case .doneForToday: return "你今天的課上完了"
        default: return "你今天沒課"
        }
    }
}

/// Initial-letter avatar with a stable per-friend colour; the ring shows their status like a game friend list.
struct FriendAvatar: View {
    let name: String
    /// nil is the user themself, drawn in the accent colour.
    let seed: String?
    var size: CGFloat = 44
    var ring: Color? = nil

    private static let palette: [Color] = [.blue, .teal, .orange, .pink, .green, .indigo, .purple, .brown]

    static func colour(for seed: String?) -> Color {
        guard let seed else { return Theme.Colors.accent }
        return palette[ClassScheduleWeekLayout.stableColourIndex(for: seed, paletteCount: palette.count)]
    }

    var body: some View {
        Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)))
            .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Self.colour(for: seed).gradient, in: Circle())
            .padding(ring == nil ? 0 : 3)
            .overlay {
                if let ring { Circle().strokeBorder(ring, lineWidth: 2.5) }
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

    var title: String {
        switch self {
        case .free, .doneForToday, .noClassToday: "有空"
        case .inClass: "上課中"
        case .notCovered: "不確定"
        case .expired: "課表已過期"
        case .upcomingTerm: "下學期的課表"
        }
    }

    var line: String {
        switch self {
        case .free(let until): "\(ScheduleSharePayload.clockText(until)) 才有課"
        case .doneForToday: "今天的課上完了"
        case .noClassToday: "今天沒課"
        case .inClass(let course, let room, let until):
            [course, "到 \(ScheduleSharePayload.clockText(until))", room].compactMap { $0 }.joined(separator: " · ")
        case .notCovered: "對方的課表沒有今天"
        case .expired: "請對方重新分享"
        case .upcomingTerm: "開學後才會顯示狀態"
        }
    }
}

/// Status word in its colour, then the detail in grey, wrapping instead of truncating.
private struct StatusText: View {
    let status: ScheduleFriendStatus

    var body: some View {
        Text("\(Text(status.title).fontWeight(.semibold).foregroundStyle(status.tint))\(Text(" · \(status.line)").foregroundStyle(Theme.Colors.secondaryLabel))")
            .font(.subheadline)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DurationChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color(.systemGreen))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(.systemGreen).opacity(0.14), in: Capsule())
    }
}

/// Wraps chips onto as many lines as needed.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Friends

/// Classmates added by QR code. Opens with who is free now; every screen is pushed, never presented.
struct ScheduleFriendsView: View {
    @ObservedObject var exchange: ScheduleExchangeViewModel
    @ObservedObject var store: ScheduleExchangeStore
    /// The user's displayed timetable, custom courses included, for local comparison only.
    let mySchedule: ClassSchedule?

    enum Route: Hashable {
        case add(AddFriendView.Tab)
        case friend(UUID)
        case group(Set<UUID>)
    }

    @State private var route: Route?
    @State private var pendingDelete: ExchangedSchedule?
    @State private var isConfirmingReset = false
    @State private var appliedFixture = false

    private var term: ScheduleShareTerm { exchange.currentTerm }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = ScheduleFriendsClock.now(context.date)
            List {
                switch store.status {
                case .ready:
                    content(now: now)
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
                    route = .add(.scan)
                } label: {
                    Image(systemName: "person.badge.plus")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("加好友")
                .disabled(store.status != .ready)
            }
        }
        .navigationDestination(item: $route) { route in
            switch route {
            case .add(let tab):
                // Saving replaces this page with the new friend's page, so Back returns to the list.
                AddFriendView(vm: exchange, store: store, initialTab: tab) { id, name in
                    UIAccessibility.post(notification: .announcement, argument: "已加入好友「\(name)」")
                    self.route = .friend(id)
                }
            case .friend(let id):
                FriendDetailView(id: id, store: store, mySchedule: mySchedule, term: term)
            case .group(let selected):
                GroupFreeTimeView(store: store, mySchedule: mySchedule, term: term, initial: selected)
            }
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
        .onAppear {
            store.reload()
            applyFixtureScenario()
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let mine = ScheduleFriendsComparison.myPayload(mySchedule, term: term)
        let rows = store.schedules
            .map { (entry: $0, status: $0.payload.status(at: now)) }
            .sorted { ($0.status.sortRank, $0.entry.displayName) < ($1.status.sortRank, $1.entry.displayName) }
        let current = rows.filter { $0.status.isCurrentTerm }
        let others = rows.filter { !$0.status.isCurrentTerm }

        if store.schedules.isEmpty {
            emptySection
        } else {
            nowSection(current.filter { $0.status.isAvailable }.map(\.entry), mine: mine, now: now)
            if !current.isEmpty {
                Section {
                    ForEach(current, id: \.entry.id) { row in
                        friendRow(row.entry, status: row.status,
                                  next: ScheduleFriendsComparison.nextWindow(mine: mine, others: [row.entry.payload], now: now),
                                  showsNext: mine != nil, now: now)
                    }
                } header: {
                    HStack {
                        Text("好友 \(current.count)")
                        Spacer()
                        if mine != nil { Text("你們下次都有空") }
                    }
                }
            }
            if !others.isEmpty {
                Section {
                    ForEach(others, id: \.entry.id) { row in
                        friendRow(row.entry, status: row.status, next: nil, showsNext: false, now: now)
                    }
                } header: {
                    Text("其他學期")
                } footer: {
                    Text("過期的課表會在學期結束 30 天後自動刪除。")
                }
            }
        }
        Section {
            Button {
                route = .add(.myCode)
            } label: {
                Label("出示我的 QR Code", systemImage: "qrcode")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .disabled(exchange.schedule == nil)
        } footer: {
            if exchange.schedule == nil {
                Text("你的課表載入後，才能產生 QR Code 和找共同空堂。")
            } else {
                Text("好友的課表只加密存在這台裝置，不會上傳。")
            }
        }
        #if DEBUG
        sampleSection
        #endif
    }

    private func nowSection(_ free: [ExchangedSchedule], mine: ScheduleSharePayload?, now: Date) -> some View {
        let day = ScheduleSharePayload.clockPosition(of: now).day
        return Section {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(ScheduleFreeTime.weekdayNames[day]) \(now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute())) · \(ScheduleFriendsComparison.myMoment(mine, at: now))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(free.isEmpty ? "好友現在都沒空" : "\(free.count) 位好友現在有空")
                        .font(.title2.weight(.bold))
                }
                .accessibilityElement(children: .combine)
                if !free.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: Theme.Spacing.small) {
                            ForEach(free) { entry in
                                Button {
                                    route = .friend(entry.id)
                                } label: {
                                    VStack(spacing: 4) {
                                        FriendAvatar(name: entry.displayName, seed: entry.payload.shareID.uuidString,
                                                     size: 48, ring: Color(.systemGreen))
                                        Text(entry.displayName)
                                            .font(.caption)
                                            .foregroundStyle(Theme.Colors.label)
                                            .lineLimit(1)
                                    }
                                    .frame(width: 64)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(entry.displayName)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    Button {
                        route = .group(Set(free.map(\.id)))
                    } label: {
                        Label("找他們的共同空堂", systemImage: "person.3.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(mine == nil)
                }
            }
            .padding(.vertical, Theme.Spacing.xsmall)
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
                Text("請同學也打開「課表好友」。一人點「出示我的 QR Code」，另一人點右上角加好友掃描。加入後就能看到對方現在有沒有空。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    route = .add(.scan)
                } label: {
                    Label("掃描同學的 QR Code", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, Theme.Spacing.xsmall)
        }
    }

    private func friendRow(_ entry: ExchangedSchedule, status: ScheduleFriendStatus, next: ScheduleFreeWindow?,
                           showsNext: Bool, now: Date) -> some View {
        Button {
            route = .friend(entry.id)
        } label: {
            HStack(spacing: Theme.Spacing.small) {
                FriendAvatar(name: entry.displayName, seed: entry.payload.shareID.uuidString, size: 44, ring: status.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.Colors.label)
                        .lineLimit(1)
                    if status.isCurrentTerm {
                        StatusText(status: status)
                    } else {
                        Text("\(entry.payload.term.title) · \(status.title)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: Theme.Spacing.xsmall)
                if showsNext {
                    if let next {
                        let isNow = ScheduleFriendsComparison.isNow(next, at: now)
                        Text(isNow ? "現在" : ScheduleFriendsComparison.whenText(next, at: now))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(isNow ? Color(.systemGreen) : Theme.Colors.label)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(isNow ? Color(.systemGreen).opacity(0.14) : Theme.Colors.tertiaryFill,
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .fixedSize()
                    } else {
                        Text("這週沒有")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                    }
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.displayName)，\(status.title)，\(status.line)"
                            + (next.map { "，你們\(ScheduleFriendsComparison.whenText($0, at: now))有空" } ?? ""))
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
        case "exchange-share": route = .add(.myCode)
        case "exchange-scan": route = .add(.scan)
        case "exchange-friend": route = friends.first.map { .friend($0.id) }
        case "exchange-group": route = .group(Set(friends.prefix(3).map(\.id)))
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let entry = store.schedules.first(where: { $0.id == id }) {
            TimelineView(.everyMinute) { context in
                content(entry, now: ScheduleFriendsClock.now(context.date))
            }
            .navigationTitle(entry.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("刪除好友", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("更多")
                }
            }
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
        let mine = status.isCurrentTerm ? ScheduleFriendsComparison.myPayload(mySchedule, term: term) : nil
        let windows = mine.map { ScheduleFreeTime.windows(base: $0, others: [payload]) } ?? []
        let next = mine.flatMap { _ in ScheduleFreeTime.upcoming(windows, at: now).first }
        return List {
            Section {
                HStack(spacing: Theme.Spacing.medium) {
                    FriendAvatar(name: entry.displayName, seed: payload.shareID.uuidString, size: 64, ring: status.tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.displayName)
                            .font(.title2.weight(.bold))
                            .lineLimit(2)
                        Text(status.isCurrentTerm ? status.title : payload.term.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(status.tint)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(status.tint.opacity(0.14), in: Capsule())
                        Text(status.line)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                .accessibilityElement(children: .combine)
            }

            if !status.isCurrentTerm {
                Section {
                    Text(status == .expired ? "這份課表的學期已經結束。想繼續看對方的課表，請對方重新分享。"
                                            : "這是下學期的課表，開學後才會顯示對方的狀態和共同空堂。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if let mine {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("你們下次都有空")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let next {
                            let isNow = ScheduleFriendsComparison.isNow(next, at: now)
                            Text("\(isNow ? "現在" : ScheduleFriendsComparison.dayLabel(next.day, now: now)) \(ScheduleFriendsComparison.timeRange(next.start, next.end))")
                                .font(.title2.weight(.bold).monospacedDigit())
                            Text(isNow ? "現在就可以約" : "共 \(next.durationText)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color(.systemGreen))
                        } else {
                            Text("這週沒有").font(.title2.weight(.bold))
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
                todaySection(entry, mine: mine, windows: windows, status: status, now: now)
                weekSection(mine: mine, windows: windows, now: now)
            } else {
                Section {
                    Text("你的課表載入後，才能找你們的共同空堂。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if status.isCurrentTerm, mine != nil {
                    NavigationLink {
                        GroupFreeTimeView(store: store, mySchedule: mySchedule, term: term, initial: [entry.id])
                    } label: {
                        Label("加人揪團", systemImage: "person.3.fill")
                            .frame(minHeight: 44)
                    }
                }
                NavigationLink {
                    FriendTimetableView(entry: entry, mySchedule: mySchedule, term: term)
                } label: {
                    Label("完整課表", systemImage: "calendar")
                        .frame(minHeight: 44)
                }
            } footer: {
                Text("對方分享了：\(sharedFields(payload))。加入於 \(entry.importedAt.formatted(.dateTime.month().day()))。")
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func todaySection(_ entry: ExchangedSchedule, mine: ScheduleSharePayload, windows: [ScheduleFreeWindow],
                              status: ScheduleFriendStatus, now: Date) -> some View {
        let (day, minute) = ScheduleSharePayload.clockPosition(of: now)
        Section {
            if !mine.days.contains(day) {
                Text("你的課表沒有\(ScheduleFreeTime.weekdayNames[day])。").font(.subheadline).foregroundStyle(.secondary)
            } else if status == .notCovered {
                Text("對方的課表沒有\(ScheduleFreeTime.weekdayNames[day])，不確定有沒有課。")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                DayLanes(lanes: [("我", Theme.Colors.accent, mine.classBlocks(on: day)),
                                 (entry.displayName, FriendAvatar.colour(for: entry.payload.shareID.uuidString),
                                  entry.payload.classBlocks(on: day))],
                         shared: windows.filter { $0.day == day },
                         periods: mine.periods, minute: minute)
                    .padding(.vertical, 6)
            }
        } header: {
            HStack {
                Text("今天對照")
                Spacer()
                Text("綠色是你們都有空")
            }
        }
    }

    private func weekSection(mine: ScheduleSharePayload, windows: [ScheduleFreeWindow], now: Date) -> some View {
        let today = ScheduleSharePayload.clockPosition(of: now).day
        return Section("這週的共同空堂") {
            ForEach(mine.days.sorted(), id: \.self) { day in
                let slots = windows.filter { $0.day == day }
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                    Text(String(ScheduleFreeTime.weekdayNames[day].suffix(1)))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(day == today ? Theme.Colors.accent : Theme.Colors.label)
                        .frame(width: 24, alignment: .leading)
                    if slots.isEmpty {
                        Text("沒有").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        FlowLayout {
                            ForEach(slots) { slot in
                                Text(ScheduleFriendsComparison.timeRange(slot.start, slot.end))
                                    .font(.subheadline.monospacedDigit())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color(.systemGreen).opacity(0.16),
                                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(ScheduleFreeTime.weekdayNames[day] + "，"
                                    + (slots.isEmpty ? "沒有共同空堂"
                                       : slots.map { ScheduleFriendsComparison.timeRange($0.start, $0.end) }.joined(separator: "、")))
            }
        }
    }

    private func sharedFields(_ payload: ScheduleSharePayload) -> String {
        var fields = ["時間", "課名"]
        if payload.hasRooms { fields.append("教室") }
        if payload.hasTeachers { fields.append("教師") }
        return fields.joined(separator: "、")
    }
}

/// Two people's classes for one day on a shared time axis, with the times both are free in green.
private struct DayLanes: View {
    let lanes: [(name: String, colour: Color, blocks: [ScheduleSharePayload.ClassBlock])]
    let shared: [ScheduleFreeWindow]
    let periods: [ScheduleSharePayload.Period]
    let minute: Int
    @Environment(\.colorScheme) private var colorScheme

    private var lower: Int { (periods.map(\.start).min() ?? 480) / 60 * 60 }
    private var upper: Int { max(lower + 60, ((periods.map(\.end).max() ?? 1020) + 59) / 60 * 60) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(lanes.indices, id: \.self) { index in
                let lane = lanes[index]
                HStack(spacing: 8) {
                    Text(lane.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 48, alignment: .leading)
                    GeometryReader { geometry in
                        let width = geometry.size.width
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 7).fill(Theme.Colors.tertiaryFill)
                            ForEach(shared) { window in
                                Rectangle()
                                    .fill(Color(.systemGreen).opacity(colorScheme == .dark ? 0.3 : 0.2))
                                    .frame(width: x(window.end, width) - x(window.start, width))
                                    .offset(x: x(window.start, width))
                            }
                            ForEach(lane.blocks, id: \.start) { block in
                                Text(block.name)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .padding(.horizontal, 4)
                                    .frame(width: max(2, x(block.end, width) - x(block.start, width)), height: 26, alignment: .leading)
                                    .background(lane.colour, in: RoundedRectangle(cornerRadius: 6))
                                    .offset(x: x(block.start, width))
                            }
                            if (lower...upper).contains(minute) {
                                Rectangle().fill(Theme.Colors.error)
                                    .frame(width: 2, height: 30)
                                    .offset(x: x(minute, width) - 1)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .frame(height: 26)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(lane.name)今天的課：" + (lane.blocks.isEmpty ? "沒有"
                    : lane.blocks.map { "\($0.name) \(ScheduleFriendsComparison.timeRange($0.start, $0.end))" }.joined(separator: "、")))
            }
            HStack(spacing: 8) {
                Color.clear.frame(width: 48, height: 1)
                HStack {
                    ForEach(Array(stride(from: lower, through: upper, by: max(60, (upper - lower) / 3 / 60 * 60))), id: \.self) { mark in
                        Text(String(format: "%02d", mark / 60))
                        if mark < upper { Spacer(minLength: 0) }
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            }
            .accessibilityHidden(true)
        }
    }

    private func x(_ minute: Int, _ width: CGFloat) -> CGFloat {
        CGFloat(min(max(minute, lower), upper) - lower) / CGFloat(upper - lower) * width
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

/// Pick friends like inviting a party; see when everyone is free, a week heat map, and slots one person short.
struct GroupFreeTimeView: View {
    @ObservedObject var store: ScheduleExchangeStore
    let mySchedule: ClassSchedule?
    let term: ScheduleShareTerm
    @State private var selected: Set<UUID>
    @State private var inspected: Int?

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
            List {
                Section {
                    partyBar
                        .listRowInsets(EdgeInsets())
                }
                if let mine {
                    if chosen.isEmpty {
                        Section {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("點上面的頭像選人").font(.headline)
                                Text("選好就會算出大家都有空的時段。").font(.subheadline).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    } else {
                        results(mine: mine, others: chosen.map(\.payload), now: now)
                    }
                } else {
                    Section {
                        Text("你的課表載入後，才能找共同空堂。").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("揪團找空堂")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(selected.count == friends.count ? "全不選" : "全選") {
                    withAnimation(Theme.Animation.fast) {
                        selected = selected.count == friends.count ? [] : Set(friends.map(\.id))
                        inspected = nil
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
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("我，一定會包含")
                ForEach(friends) { friend in
                    let isOn = selected.contains(friend.id)
                    Button {
                        withAnimation(Theme.Animation.fast) {
                            if isOn { selected.remove(friend.id) } else { selected.insert(friend.id) }
                            inspected = nil
                        }
                    } label: {
                        member(name: friend.displayName, seed: friend.payload.shareID.uuidString, isSelected: isOn)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(friend.displayName)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)
        }
    }

    private func member(name: String, seed: String?, isSelected: Bool) -> some View {
        VStack(spacing: 6) {
            FriendAvatar(name: name, seed: seed, size: 50)
                .opacity(isSelected ? 1 : 0.35)
                .overlay(alignment: .topTrailing) {
                    if isSelected, seed != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Theme.Colors.accent)
                            .offset(x: 3, y: -3)
                    }
                }
            Text(name)
                .font(.caption)
                .foregroundStyle(isSelected ? Theme.Colors.label : Theme.Colors.secondaryLabel)
                .lineLimit(1)
        }
        .frame(width: 64)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func results(mine: ScheduleSharePayload, others: [ScheduleSharePayload], now: Date) -> some View {
        let total = others.count + 1
        let windows = ScheduleFreeTime.upcoming(ScheduleFreeTime.windows(base: mine, others: others), at: now)
        let days = mine.days.sorted()
        let cells = ScheduleFreeTime.grid(base: mine, others: others, days: days)
        let rows = mine.periods.indices.sorted { mine.periods[$0].start < mine.periods[$1].start }

        Section {
            if windows.isEmpty {
                Text("這週沒有 \(total) 人都有空的時段，看看下面「差一個人」。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(windows.prefix(5)) { window in
                    HStack(spacing: Theme.Spacing.small) {
                        Text(ScheduleFriendsComparison.dayLabel(window.day, now: now))
                            .font(.body.weight(.semibold))
                            .frame(width: 56, alignment: .leading)
                        Text(ScheduleFriendsComparison.timeRange(window.start, window.end))
                            .font(.body.monospacedDigit())
                        Spacer(minLength: Theme.Spacing.xsmall)
                        DurationChip(text: window.durationText)
                    }
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .combine)
                }
            }
        } header: {
            HStack {
                Text("\(total) 人都有空")
                Spacer()
                Text("從現在起")
            }
        }

        Section {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                    GridRow {
                        Color.clear.frame(width: 36, height: 1)
                        ForEach(days, id: \.self) { day in
                            Text(String(ScheduleFreeTime.weekdayNames[day].suffix(1)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    ForEach(rows, id: \.self) { row in
                        GridRow {
                            VStack(alignment: .trailing, spacing: 0) {
                                Text(mine.periods[row].id).font(.caption2.weight(.semibold))
                                Text(ScheduleSharePayload.clockText(mine.periods[row].start)).font(.system(size: 9).monospacedDigit())
                            }
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                            ForEach(days.indices, id: \.self) { column in
                                heatCell(cells[row][column], total: total, key: days[column] * 100 + row,
                                         label: "\(ScheduleFreeTime.weekdayNames[days[column]]) 第\(mine.periods[row].id)節")
                            }
                        }
                    }
                }
                HStack(spacing: 6) {
                    legend(Theme.Colors.tertiaryFill, "沒人有空")
                    legend(Color(.systemGreen).opacity(0.35), "部分有空")
                    legend(Color(.systemGreen), "全部有空")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                Text(inspectedText(mine: mine, cells: cells, days: days, total: total))
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Theme.Colors.groupedBackground, in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(.vertical, 6)
        } header: {
            HStack {
                Text("這週一覽")
                Spacer()
                Text("顏色越深越多人有空")
            }
        } footer: {
            Text("依你的課表（含自訂課程）計算，只比對\(term.title)；誰的課表沒有涵蓋的時段，不算有空。")
        }

        let short = nearMisses(mine: mine, cells: cells, days: days, rows: rows)
        if !short.isEmpty {
            Section("差一個人") {
                ForEach(short.prefix(3), id: \.key) { item in
                    HStack(spacing: Theme.Spacing.small) {
                        Text(String(ScheduleFreeTime.weekdayNames[item.day].suffix(1)))
                            .font(.body.weight(.semibold))
                            .frame(width: 24, alignment: .leading)
                        Text(ScheduleFriendsComparison.timeRange(item.period.start, item.period.end))
                            .font(.body.monospacedDigit())
                        Spacer(minLength: Theme.Spacing.xsmall)
                        Text("\(item.who) 有課")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color(.systemOrange))
                    }
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func freeCount(_ cell: ScheduleFreeSlot, total: Int) -> Int {
        switch cell {
        case .free: total
        case .busy(let names), .unknown(let names): max(0, total - names.count)
        }
    }

    private func heatCell(_ cell: ScheduleFreeSlot, total: Int, key: Int, label: String) -> some View {
        let count = freeCount(cell, total: total)
        let all = count == total
        return Button {
            inspected = inspected == key ? nil : key
        } label: {
            RoundedRectangle(cornerRadius: 5)
                .fill(all ? Color(.systemGreen) : Color(.systemGreen).opacity(0.55 * Double(count) / Double(max(1, total))))
                .background(Theme.Colors.tertiaryFill, in: RoundedRectangle(cornerRadius: 5))
                .overlay {
                    if all {
                        Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                    }
                }
                .overlay {
                    if inspected == key {
                        RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.Colors.label, lineWidth: 2)
                    }
                }
                .frame(height: 28)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label)，\(count)/\(total) 人有空")
        .accessibilityAddTraits(inspected == key ? .isSelected : [])
    }

    private func legend(_ colour: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3).fill(colour).frame(width: 14, height: 10)
            Text(text)
        }
    }

    private func inspectedText(mine: ScheduleSharePayload, cells: [[ScheduleFreeSlot]], days: [Int], total: Int) -> String {
        guard let key = inspected, let column = days.firstIndex(of: key / 100), mine.periods.indices.contains(key % 100) else {
            return "點格子看是誰有課。"
        }
        let period = mine.periods[key % 100]
        let heading = "\(ScheduleFreeTime.weekdayNames[key / 100]) 第\(period.id)節 \(ScheduleFriendsComparison.timeRange(period.start, period.end))："
        switch cells[key % 100][column] {
        case .free: return heading + "\(total) 人都有空"
        case .busy(let names): return heading + names.map { $0 == "我" ? "你" : $0 }.joined(separator: "、") + " 有課"
        case .unknown(let names): return heading + names.joined(separator: "、") + " 的課表沒有這天"
        }
    }

    private struct NearMiss {
        let day: Int
        let period: ScheduleSharePayload.Period
        let who: String
        var key: Int { day * 10_000 + period.start }
    }

    /// Periods only one friend is busy for; the user being busy is not something to negotiate.
    private func nearMisses(mine: ScheduleSharePayload, cells: [[ScheduleFreeSlot]], days: [Int], rows: [Int]) -> [NearMiss] {
        guard !cells.isEmpty, cells[0].count > 0 else { return [] }
        var result: [NearMiss] = []
        for (column, day) in days.enumerated() {
            for row in rows {
                if case .busy(let names) = cells[row][column], names.count == 1, names[0] != "我" {
                    result.append(NearMiss(day: day, period: mine.periods[row], who: names[0]))
                }
            }
        }
        return result
    }
}

// MARK: - Home entry

/// The home-screen card opens this as an ordinary pushed page. It loads the user's own timetable
/// itself (cache first, hidden school page only if there is none) so comparisons work without
/// going through 我的課表 first.
struct ScheduleFriendsEntryView: View {
    @StateObject private var schedule = ClassScheduleViewModel()
    @ObservedObject private var store: ScheduleExchangeStore
    @StateObject private var exchange: ScheduleExchangeViewModel

    init() {
        let store = ScheduleExchangeStore.shared
        self.store = store
        _exchange = StateObject(wrappedValue: ScheduleExchangeViewModel(schedule: nil, store: store))
    }

    var body: some View {
        ZStack {
            ScheduleFriendsView(exchange: exchange, store: store, mySchedule: schedule.displaySchedule)
            if schedule.showWebView {
                let generation = schedule.loadGeneration
                ClassScheduleWebView { result in
                    schedule.handleWebResult(result, generation: generation)
                }
                .frame(width: 1, height: 1)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .onAppear {
            if schedule.loadState == .idle { schedule.loadSchedule() }
        }
        .task(id: schedule.schedule?.fetchedAt) { exchange.schedule = schedule.schedule }
    }
}
