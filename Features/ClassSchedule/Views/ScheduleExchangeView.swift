import SwiftUI
import PhotosUI
import VisionKit
import Vision
@preconcurrency import AVFoundation

// MARK: - My QR code

struct MyScheduleCodeSheet: View {
    @ObservedObject var vm: ScheduleExchangeViewModel
    @ObservedObject var store: ScheduleExchangeStore
    @Environment(\.dismiss) private var dismiss
    @State private var nicknameDraft = ""
    @State private var isEditingName = false
    @State private var isConfirmingReset = false
    @FocusState private var nameFocused: Bool

    private var preferences: ScheduleSharePreferences { store.preferences }
    private var needsName: Bool { ScheduleSharePayload.cleanNickname(vm.nickname).isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.large) {
                    if needsName || isEditingName {
                        nameEditor
                    } else {
                        code
                        options
                    }
                }
                .padding(Theme.Spacing.medium)
            }
            .background(Theme.Colors.groupedBackground)
            .navigationTitle("我的課表 QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .confirmationDialog("重設分享識別碼？", isPresented: $isConfirmingReset, titleVisibility: .visible) {
                Button("重設", role: .destructive) { store.resetShareID() }
            } message: {
                Text("同學之後掃描你的新 QR Code 時，會變成新的一筆，而不是更新舊的。")
            }
        }
        .onAppear {
            nicknameDraft = preferences.customNickname
            vm.regenerateCode()
        }
        .onChange(of: preferences) { _, _ in vm.regenerateCode() }
        .onChange(of: vm.shareTerm) { _, _ in vm.regenerateCode() }
        .onChange(of: nicknameDraft) { _, value in
            let capped = String(value.prefix(ScheduleSharePayload.maxNicknameLength))
            if capped != value { nicknameDraft = capped }
        }
    }

    private var nameEditor: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("同學會看到什麼名字？")
                .font(.title3.weight(.bold))
            TextField("輸入暱稱，例如：小安", text: $nicknameDraft)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .submitLabel(.done)
                .onSubmit(saveName)
            Button {
                saveName()
            } label: {
                Text("使用這個暱稱").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(ScheduleSharePayload.cleanNickname(nicknameDraft).isEmpty)
            if let realName = vm.realName {
                Button {
                    store.updatePreferences { $0.nicknameMode = .realName }
                    isEditingName = false
                } label: {
                    Text("改用真實姓名「\(realName)」").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
        }
        .onAppear { nameFocused = needsName }
    }

    private func saveName() {
        let value = ScheduleSharePayload.cleanNickname(nicknameDraft)
        guard !value.isEmpty else { return }
        store.updatePreferences {
            $0.customNickname = value
            $0.nicknameMode = .custom
        }
        isEditingName = false
    }

    private var code: some View {
        VStack(spacing: Theme.Spacing.medium) {
            VStack(spacing: Theme.Spacing.small) {
                Text(String(vm.nickname.prefix(1)))
                    .font(.title.weight(.bold))
                    .foregroundStyle(.purple)
                    .frame(width: 64, height: 64)
                    .background(.white, in: Circle())
                Text(vm.nickname)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text(vm.shareTerm.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                Group {
                    if let image = vm.qrImage {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .accessibilityLabel("我的課表 QR Code")
                    } else if let message = vm.shareMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 200)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                    }
                }
                .padding(Theme.Spacing.medium)
                .background(.white, in: RoundedRectangle(cornerRadius: Theme.CornerRadius.large, style: .continuous))
                .padding(.top, Theme.Spacing.xsmall)
                Text("在 NIU App 的「課表交換」掃描")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(Theme.Spacing.large)
            .frame(maxWidth: 360)
            .background(
                LinearGradient(colors: [Color(.systemPurple), Color(.systemIndigo), Color(.systemBlue)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 32, style: .continuous)
            )

            Button {
                nicknameDraft = preferences.customNickname
                isEditingName = true
            } label: {
                Label("修改顯示名稱", systemImage: "pencil")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)

            Text("QR Code 24 小時內有效。旁人也看得到內容，請只給想分享的同學掃。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("分享內容")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, Theme.Spacing.xsmall)
            VStack(spacing: 0) {
                LabeledContent("上課時間與課名", value: "一律包含")
                    .frame(minHeight: 44)
                Divider()
                Toggle("教室", isOn: Binding(
                    get: { preferences.includeRooms },
                    set: { value in store.updatePreferences { $0.includeRooms = value } }
                ))
                .frame(minHeight: 44)
                Divider()
                Toggle("授課教師", isOn: Binding(
                    get: { preferences.includeTeachers },
                    set: { value in store.updatePreferences { $0.includeTeachers = value } }
                ))
                .frame(minHeight: 44)
                Divider()
                LabeledContent("學期") {
                    Picker("學期", selection: $vm.shareTerm) {
                        ForEach(vm.shareTermOptions, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
                .frame(minHeight: 44)
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .background(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.medium, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            Text("自訂課程不會分享。學期結束後，同學那邊的這份課表會自動過期。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, Theme.Spacing.xsmall)
            Button("重設分享識別碼", role: .destructive) { isConfirmingReset = true }
                .font(.footnote)
                .frame(minHeight: 44)
        }
    }
}

// MARK: - Scan

/// Camera first; a decoded code becomes a confirmation card over the camera instead of another screen.
struct ScheduleScanView: View {
    @ObservedObject var vm: ScheduleExchangeViewModel
    let onSaved: (_ id: UUID, _ name: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var isVisible = false
    @State private var authorization = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var scannerError: String?
    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            camera
            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomPanel
                    .padding(Theme.Spacing.medium)
            }
        }
        .onAppear {
            isVisible = true
            vm.beginScanning()
        }
        .onDisappear {
            isVisible = false
            vm.cancelAll()
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            vm.importPhoto(item)
        }
        .task {
            guard authorization == .notDetermined else { return }
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            authorization = granted ? .authorized : .denied
        }
    }

    @ViewBuilder
    private var camera: some View {
        if !DataScannerViewController.isSupported {
            cameraMessage("這台裝置不支援相機掃描，請改用「從照片選取」。")
        } else if authorization == .denied || authorization == .restricted {
            cameraMessage("請到「設定」允許 NIU App 使用相機，或改用「從照片選取」。", showsSettings: true)
        } else if authorization == .notDetermined {
            ProgressView().tint(.white)
        } else if let scannerError {
            cameraMessage(scannerError)
        } else {
            QRDataScanner(isScanning: isVisible && scenePhase == .active && vm.isAcceptingScans && vm.candidate == nil,
                          onCode: vm.handleScannedText,
                          onError: { scannerError = $0 })
                .ignoresSafeArea()
        }
    }

    private func cameraMessage(_ message: String, showsSettings: Bool = false) -> some View {
        VStack(spacing: Theme.Spacing.small) {
            Image(systemName: "camera.badge.ellipsis").font(.largeTitle)
            Text(message).multilineTextAlignment(.center)
            if showsSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                Button("開啟設定") { openURL(url) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .foregroundStyle(.white)
        .padding(Theme.Spacing.xlarge)
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("關閉")
            Spacer()
            Text("掃描同學的課表")
                .font(.headline)
                .foregroundStyle(.white)
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.top, Theme.Spacing.xsmall)
    }

    @ViewBuilder
    private var bottomPanel: some View {
        if let candidate = vm.candidate {
            ImportConfirmCard(candidate: candidate, cancel: vm.scanAgain) { replace in
                if let id = vm.confirm(candidate, replaceExisting: replace) {
                    let name = candidate.payload.nickname.isEmpty ? "未命名同學" : candidate.payload.nickname
                    vm.scanAgain()
                    onSaved(id, name)
                }
            }
        } else if let message = vm.importMessage {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                Button {
                    vm.scanAgain()
                } label: {
                    Text("重新掃描").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(Theme.Spacing.medium)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.CornerRadius.large))
        } else {
            VStack(spacing: Theme.Spacing.small) {
                Text("對準同學的課表 QR Code")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                // The picker's label closure is not main-actor isolated; read the state here.
                let isReadingPhoto = vm.isReadingPhoto
                PhotosPicker(selection: $photoItem, matching: .images) {
                    HStack {
                        if isReadingPhoto { ProgressView() } else { Image(systemName: "photo.on.rectangle") }
                        Text("從照片選取")
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, Theme.Spacing.medium)
                    .frame(minHeight: 44)
                    .background(.regularMaterial, in: Capsule())
                }
                .disabled(vm.isReadingPhoto || !vm.isAcceptingScans)
                .accessibilityHint("選擇同學傳來的 QR Code 截圖")
            }
        }
    }
}

private struct ImportConfirmCard: View {
    let candidate: ScheduleImportCandidate
    let cancel: () -> Void
    let save: (_ replaceExisting: Bool) -> Void

    private var payload: ScheduleSharePayload { candidate.payload }
    private var name: String { payload.nickname.isEmpty ? "未命名同學" : payload.nickname }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(name).font(.title3.weight(.bold))
            Text("\(payload.term.title)・\(payload.courseCount) 門課・\(includedFields)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let existing = candidate.existing {
                Text("你已經有「\(existing.displayName)」這學期的課表。")
                    .font(.subheadline)
            }
            Text("QR Code 無法證明對方身分，請確認是你認識的同學。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let existing = candidate.existing {
                Button { save(true) } label: {
                    Text("更新「\(existing.displayName)」").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                Button { save(false) } label: {
                    Text("另存為新的一筆").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            } else {
                Button { save(false) } label: {
                    Text("加入").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
            Button(action: cancel) {
                Text("取消").frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .padding(Theme.Spacing.medium)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.CornerRadius.large))
    }

    private var includedFields: String {
        var fields = ["時間", "課名"]
        if payload.hasRooms { fields.append("教室") }
        if payload.hasTeachers { fields.append("教師") }
        return fields.joined(separator: "、")
    }
}

/// VisionKit scanner limited to QR codes. Scanning stops whenever `isScanning` is false,
/// so a code shown during a confirmation is detected afresh only after scanning resumes.
private struct QRDataScanner: UIViewControllerRepresentable {
    let isScanning: Bool
    let onCode: (String) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
        context.coordinator.onError = onError
        if isScanning, !controller.isScanning {
            do {
                try controller.startScanning()
            } catch {
                onError("相機目前無法啟動，請稍後再試或改用「從照片選取」。")
            }
        } else if !isScanning, controller.isScanning {
            controller.stopScanning()
        }
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
        controller.delegate = nil
        coordinator.onCode = nil
        coordinator.onError = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: ((String) -> Void)?
        var onError: ((String) -> Void)?

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let barcode) = item, let value = barcode.payloadStringValue {
                    onCode?(value)
                    return
                }
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            onError?("相機已停止，請關閉後重新開啟掃描。")
        }
    }
}

// MARK: - Classmate picker

/// Whose timetable to show, and the two ways to add a classmate. Opened from the timetable title.
struct ClassmatePickerSheet: View {
    @ObservedObject var store: ScheduleExchangeStore
    let current: UUID?
    let canShare: Bool
    let select: (UUID?) -> Void
    let compare: () -> Void
    let scan: () -> Void
    let showMyCode: () -> Void
    /// The user's period times, so debug sample classmates line up with them.
    var periods: [ScheduleSharePayload.Period] = []
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDelete: ExchangedSchedule?
    @State private var isConfirmingReset = false

    private var classmates: [ExchangedSchedule] {
        let now = Date()
        return store.schedules.sorted {
            ($0.isExpired(at: now) ? 1 : 0, $0.displayName) < ($1.isExpired(at: now) ? 1 : 0, $1.displayName)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                switch store.status {
                case .ready:
                    if classmates.isEmpty {
                        Section {
                            VStack(spacing: Theme.Spacing.xsmall) {
                                Image(systemName: "person.2.fill")
                                    .font(.largeTitle)
                                    .foregroundStyle(Color(.systemPurple))
                                Text("還沒有同學的課表")
                                    .font(.headline)
                                Text("兩個人都打開這個畫面，一個人按「掃描」，另一個人按「我的 QR Code」。")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.Spacing.small)
                        }
                    } else {
                        Section {
                            Button(action: compare) {
                                HStack(spacing: Theme.Spacing.small) {
                                    Image(systemName: "person.3.fill")
                                        .font(.headline)
                                        .foregroundStyle(.white)
                                        .frame(width: 38, height: 38)
                                        .background(Color(.systemGreen), in: Circle())
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text("多人比對").foregroundStyle(Theme.Colors.label)
                                        Text("選幾位同學，找大家都沒課的時間")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!canShare)
                        } footer: {
                            if !canShare { Text("你的課表載入後才能比對。") }
                        }
                        Section {
                            row(name: "我", detail: "我的課表", id: nil, color: Theme.Colors.accent)
                            ForEach(classmates) { entry in
                                row(name: entry.displayName,
                                    detail: entry.isExpired(at: Date()) ? "\(entry.payload.term.title)・已過期"
                                                                        : "\(entry.payload.courseCount) 門課",
                                    id: entry.id, color: Color(.systemPurple))
                                    .swipeActions {
                                        Button("刪除", role: .destructive) { pendingDelete = entry }
                                    }
                            }
                        } header: {
                            Text("要看誰的課表？")
                        } footer: {
                            Text("左滑可以刪除。同學的課表只加密存在這台裝置，不會上傳。")
                        }
                    }
                    addSection
                    #if DEBUG
                    Section("測試資料") {
                        Button("加入假同學資料", systemImage: "person.3.fill") {
                            for payload in ScheduleExchangeSamples.classmates(term: ScheduleShareTerm(containing: Date()),
                                                                               periods: periods) {
                                store.save(payload, replacing: store.existing(matching: payload)?.id)
                            }
                        }
                        Button("移除假同學資料", systemImage: "trash", role: .destructive) {
                            for id in store.schedules.filter({ ScheduleExchangeSamples.isSample($0.payload) }).map(\.id) {
                                store.delete(id: id)
                            }
                        }
                    }
                    #endif
                case .locked:
                    Label("裝置已鎖定，解鎖後才能讀取同學的課表。", systemImage: "lock")
                    Button("重試") { store.reload() }
                case .unreadable:
                    Label("同學的課表無法開啟，可能是裝置還原或鑰匙圈資料遺失。", systemImage: "exclamationmark.lock")
                    Button("清除這個帳號的同學課表", role: .destructive) { isConfirmingReset = true }
                case .signedOut:
                    Label("請先登入學校帳號。", systemImage: "person.crop.circle.badge.exclamationmark")
                }
            }
            .navigationTitle("同學的課表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .confirmationDialog(
                "刪除「\(pendingDelete?.displayName ?? "")」的課表？",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("刪除", role: .destructive) {
                    if let pendingDelete, store.delete(id: pendingDelete.id), pendingDelete.id == current { select(nil) }
                    pendingDelete = nil
                }
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
        }
        .presentationDetents([.medium, .large])
    }

    private var addSection: some View {
        Section {
            Button(action: scan) {
                Label("掃描同學的 QR Code", systemImage: "qrcode.viewfinder")
                    .frame(minHeight: 44)
            }
            Button(action: showMyCode) {
                Label("我的 QR Code（給同學掃）", systemImage: "qrcode")
                    .frame(minHeight: 44)
            }
            .disabled(!canShare)
        } header: {
            Text("新增同學")
        } footer: {
            if !canShare { Text("你的課表載入後才能產生 QR Code。") }
        }
    }

    private func row(name: String, detail: String, id: UUID?, color: Color) -> some View {
        Button {
            select(id)
        } label: {
            HStack(spacing: Theme.Spacing.small) {
                Text(String(name.prefix(1)))
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(color, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).foregroundStyle(Theme.Colors.label)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if id == current {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.Colors.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(id == current ? .isSelected : [])
    }
}

// MARK: - Group comparison

/// Pick the classmates to compare with the user's own timetable.
struct CompareSetupSheet: View {
    @ObservedObject var store: ScheduleExchangeStore
    let term: ScheduleShareTerm
    let start: (Set<UUID>) -> Void
    @State private var selected: Set<UUID>
    @Environment(\.dismiss) private var dismiss

    init(store: ScheduleExchangeStore, term: ScheduleShareTerm, initial: Set<UUID>, start: @escaping (Set<UUID>) -> Void) {
        self.store = store
        self.term = term
        self.start = start
        _selected = State(initialValue: initial)
    }

    private var classmates: [ExchangedSchedule] {
        store.schedules.filter { $0.payload.term == term }.sorted { $0.displayName < $1.displayName }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(classmates) { entry in
                        let isOn = selected.contains(entry.id)
                        Button {
                            if isOn { selected.remove(entry.id) } else { selected.insert(entry.id) }
                        } label: {
                            HStack(spacing: Theme.Spacing.small) {
                                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                                    .font(.title2)
                                    .foregroundStyle(isOn ? Theme.Colors.accent : Color(.tertiaryLabel))
                                Text(String(entry.displayName.prefix(1)))
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                    .frame(width: 36, height: 36)
                                    .background(Color(.systemPurple), in: Circle())
                                Text(entry.displayName).foregroundStyle(Theme.Colors.label)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(entry.displayName)
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                    }
                } header: {
                    Text("和我一起比對的同學")
                } footer: {
                    Text("只能比對\(term.title)的課表。你的課表一定會包含在內。")
                }
            }
            .navigationTitle("多人比對")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selected.count == classmates.count ? "全不選" : "全選") {
                        selected = selected.count == classmates.count ? [] : Set(classmates.map(\.id))
                    }
                    .disabled(classmates.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    start(selected)
                } label: {
                    Text(selected.isEmpty ? "請至少選一位同學" : "開始比對（\(selected.count + 1) 人）")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(selected.isEmpty)
                .padding(Theme.Spacing.medium)
                .background(.bar)
            }
        }
    }
}
