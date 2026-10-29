import SwiftUI
import PhotosUI
import VisionKit
import Vision
@preconcurrency import AVFoundation

// MARK: - Add friend

/// One pushed page to add a friend, like a messaging app: scan theirs, or show your own code.
struct AddFriendView: View {
    enum Tab: Hashable { case myCode, scan }

    @ObservedObject var vm: ScheduleExchangeViewModel
    @ObservedObject var store: ScheduleExchangeStore
    let onSaved: (_ id: UUID, _ name: String) -> Void
    @State private var tab: Tab

    init(vm: ScheduleExchangeViewModel, store: ScheduleExchangeStore, initialTab: Tab,
         onSaved: @escaping (_ id: UUID, _ name: String) -> Void) {
        self.vm = vm
        self.store = store
        self.onSaved = onSaved
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("加好友方式", selection: $tab) {
                Text("掃描 QR Code").tag(Tab.scan)
                Text("我的 QR Code").tag(Tab.myCode)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)

            switch tab {
            case .scan:
                FriendScanPanel(vm: vm, onSaved: onSaved)
            case .myCode:
                MyFriendCodePanel(vm: vm, store: store)
            }
        }
        .background(Theme.Colors.groupedBackground)
        .navigationTitle("加好友")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - My code

private struct MyFriendCodePanel: View {
    @ObservedObject var vm: ScheduleExchangeViewModel
    @ObservedObject var store: ScheduleExchangeStore
    @State private var nicknameDraft = ""
    @State private var isEditingName = false
    @State private var shareImage: UIImage?
    @FocusState private var nameFocused: Bool

    private var preferences: ScheduleSharePreferences { store.preferences }
    private var needsName: Bool { ScheduleSharePayload.cleanNickname(vm.nickname).isEmpty }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.large) {
                if needsName || isEditingName {
                    nameEditor
                } else {
                    card
                    actions
                }
            }
            .padding(Theme.Spacing.medium)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            nicknameDraft = preferences.customNickname
            vm.regenerateCode()
        }
        .onChange(of: preferences) { _, _ in vm.regenerateCode() }
        .onChange(of: vm.shareTerm) { _, _ in vm.regenerateCode() }
        // A first load or background refresh finishing while this is open must not leave an old code.
        .onChange(of: vm.schedule?.fetchedAt) { _, _ in vm.regenerateCode() }
        .onChange(of: vm.qrText) { _, _ in shareImage = renderShareImage() }
        .onChange(of: nicknameDraft) { _, value in
            let capped = String(value.prefix(ScheduleSharePayload.maxNicknameLength))
            if capped != value { nicknameDraft = capped }
        }
    }

    private var nameEditor: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            FriendAvatar(name: nicknameDraft.isEmpty ? "?" : nicknameDraft, seed: nil, size: 64)
                .frame(maxWidth: .infinity)
                .padding(.bottom, Theme.Spacing.xsmall)
            Text("好友會看到什麼名字？")
                .font(.title3.weight(.bold))
            Text("名字會放進你的 QR Code，掃描的同學會用這個名字認出你。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("輸入暱稱，例如：小安", text: $nicknameDraft)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .submitLabel(.done)
                .onSubmit(saveName)
            Button(action: saveName) {
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
            if isEditingName, !needsName {
                Button("取消") { isEditingName = false }
                    .frame(maxWidth: .infinity, minHeight: 44)
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

    private var card: some View {
        VStack(spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.small) {
                FriendAvatar(name: vm.nickname, seed: nil, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.nickname)
                        .font(.headline)
                        .lineLimit(1)
                    Text(vm.shareTerm.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Group {
                if let image = vm.qrImage {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(Theme.Spacing.xsmall)
                        .background(.white, in: RoundedRectangle(cornerRadius: Theme.CornerRadius.medium, style: .continuous))
                        .accessibilityLabel("我的課表 QR Code")
                } else if let message = vm.shareMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 220)
                }
            }
            .frame(maxWidth: 280)
            Text("請同學打開「課表好友」，點右上角加好友掃描")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: 360)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: Theme.CornerRadius.xlarge, style: .continuous))
    }

    private var actions: some View {
        VStack(spacing: Theme.Spacing.xsmall) {
            HStack(spacing: Theme.Spacing.small) {
                if let shareImage {
                    let image = Image(uiImage: shareImage)
                    ShareLink(item: image, preview: SharePreview("\(vm.nickname) 的課表 QR Code", image: image)) {
                        Label("傳送 QR Code", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button {
                    nicknameDraft = preferences.customNickname
                    isEditingName = true
                } label: {
                    Label("改名字", systemImage: "pencil")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
            NavigationLink {
                ScheduleShareSettingsView(vm: vm, store: store)
            } label: {
                HStack {
                    Label("分享設定", systemImage: "slider.horizontal.3")
                    Spacer()
                    Text(sharedSummary).foregroundStyle(.secondary)
                    Image(systemName: "chevron.forward").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .frame(minHeight: 44)
                .padding(.horizontal, Theme.Spacing.medium)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: Theme.CornerRadius.medium, style: .continuous))
            }
            .buttonStyle(.plain)
            Text("QR Code 只能在 24 小時內加入，但圖片會留在對方手上，拿到的人都能讀出內容，只傳給想分享的同學。對方可以用「從照片選取」加入。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 360)
    }

    private var sharedSummary: String {
        var fields = ["課名"]
        if preferences.includeRooms { fields.append("教室") }
        if preferences.includeTeachers { fields.append("教師") }
        return fields.joined(separator: "、")
    }

    /// A white card with a quiet zone, so the code still scans from a photo or a chat thumbnail.
    private func renderShareImage() -> UIImage? {
        guard let qr = vm.qrImage else { return nil }
        let renderer = ImageRenderer(content:
            VStack(spacing: 12) {
                Text(vm.nickname).font(.system(size: 22, weight: .bold))
                Text(vm.shareTerm.title).font(.system(size: 15)).foregroundStyle(.secondary)
                Image(uiImage: qr).interpolation(.none).resizable().frame(width: 300, height: 300)
                Text("NIU App「課表好友」→「加好友」→「從照片選取」").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .padding(32)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        )
        renderer.scale = 3
        return renderer.uiImage
    }
}

// MARK: - Share settings

/// What goes into the user's code; pushed from「我的 QR Code」.
private struct ScheduleShareSettingsView: View {
    @ObservedObject var vm: ScheduleExchangeViewModel
    @ObservedObject var store: ScheduleExchangeStore
    @State private var isConfirmingReset = false

    private var preferences: ScheduleSharePreferences { store.preferences }

    var body: some View {
        Form {
            Section {
                LabeledContent("上課時間與課名", value: "一律包含")
                Toggle("教室", isOn: Binding(
                    get: { preferences.includeRooms },
                    set: { value in store.updatePreferences { $0.includeRooms = value } }
                ))
                Toggle("授課教師", isOn: Binding(
                    get: { preferences.includeTeachers },
                    set: { value in store.updatePreferences { $0.includeTeachers = value } }
                ))
                Picker("學期", selection: $vm.shareTerm) {
                    ForEach(vm.shareTermOptions, id: \.self) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("分享教室後，好友會看到你上課中在哪間教室。自訂課程不會分享；學期結束後，好友那邊的課表會自動過期。")
            }
            Section {
                Button("重設分享識別碼", role: .destructive) { isConfirmingReset = true }
            } footer: {
                Text("重設後，同學再掃你的 QR Code 會變成新的一位好友，而不是更新舊的。")
            }
        }
        .navigationTitle("分享設定")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("重設分享識別碼？", isPresented: $isConfirmingReset, titleVisibility: .visible) {
            Button("重設", role: .destructive) { store.resetShareID() }
        }
    }
}

// MARK: - Scan

/// Camera first; a decoded code becomes a confirmation card below the camera instead of another screen.
private struct FriendScanPanel: View {
    @ObservedObject var vm: ScheduleExchangeViewModel
    let onSaved: (_ id: UUID, _ name: String) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var isVisible = false
    @State private var authorization = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var scannerError: String?
    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.medium) {
                ZStack {
                    Color.black
                    camera
                    if DataScannerViewController.isSupported, vm.candidate == nil, vm.importMessage == nil,
                       authorization == .authorized, scannerError == nil {
                        ViewfinderCorners()
                            .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .padding(48)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 360)
                .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.xlarge, style: .continuous))

                bottomPanel
                    .frame(maxWidth: 360)
            }
            .padding(Theme.Spacing.medium)
            .frame(maxWidth: .infinity)
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
        }
    }

    private func cameraMessage(_ message: String, showsSettings: Bool = false) -> some View {
        VStack(spacing: Theme.Spacing.small) {
            Image(systemName: "camera.badge.ellipsis").font(.largeTitle)
            Text(message).font(.subheadline).multilineTextAlignment(.center)
            if showsSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                Button("開啟設定") { openURL(url) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .foregroundStyle(.white)
        .padding(Theme.Spacing.large)
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
                    .foregroundStyle(Theme.Colors.label)
                Button {
                    vm.scanAgain()
                } label: {
                    Text("重新掃描").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(Theme.Spacing.medium)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: Theme.CornerRadius.large, style: .continuous))
        } else {
            VStack(spacing: Theme.Spacing.small) {
                Text("對準同學的課表 QR Code")
                    .font(.subheadline.weight(.medium))
                Text("同學可以在「加好友」切到「我的 QR Code」出示，或把 QR Code 圖片傳給你。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                // The picker's label closure is not main-actor isolated; read the state here.
                let isReadingPhoto = vm.isReadingPhoto
                PhotosPicker(selection: $photoItem, matching: .images) {
                    HStack {
                        if isReadingPhoto { ProgressView() } else { Image(systemName: "photo.on.rectangle") }
                        Text("從照片選取")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(vm.isReadingPhoto || !vm.isAcceptingScans)
                .accessibilityHint("選擇同學傳來的 QR Code 圖片或截圖")
            }
        }
    }
}

private struct ViewfinderCorners: Shape {
    func path(in rect: CGRect) -> Path {
        let length = min(rect.width, rect.height) * 0.18
        var path = Path()
        for (corner, dx, dy) in [(CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0), (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
                                 (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0), (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0)] {
            path.move(to: CGPoint(x: corner.x, y: corner.y + dy * length))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x + dx * length, y: corner.y))
        }
        return path
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
            HStack(spacing: Theme.Spacing.small) {
                FriendAvatar(name: name, seed: payload.shareID.uuidString, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.title3.weight(.bold)).lineLimit(1)
                    Text("\(payload.term.title)・\(payload.courseCount) 門課")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Text("分享了：\(includedFields)")
                .font(.subheadline)
            if let existing = candidate.existing {
                Text("「\(existing.displayName)」已經是你的好友，要更新他的課表嗎？")
                    .font(.subheadline)
            }
            Text("QR Code 無法證明對方身分，請確認是你認識的同學。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let existing = candidate.existing {
                Button { save(true) } label: {
                    Text("更新「\(existing.displayName)」的課表").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                Button { save(false) } label: {
                    Text("加為另一位好友").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            } else {
                Button { save(false) } label: {
                    Label("加為好友", systemImage: "person.badge.plus").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
            Button(action: cancel) {
                Text("取消").frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .padding(Theme.Spacing.medium)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: Theme.CornerRadius.large, style: .continuous))
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
