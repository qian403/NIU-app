@preconcurrency import AVFoundation
import Combine
import SwiftUI
import UIKit
import WebKit

struct MoodleAttendanceScannerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner = MoodleAttendanceScanner()
    @State private var attendanceURL: URL?
    @State private var isShowingAttendance = false
    @State private var validationMessage: String?
    @State private var validationTask: Task<Void, Never>?
    @State private var preparationTask: Task<Void, Never>?
    @State private var preparationGeneration = 0
    @State private var preparationState: AttendancePreparationState = .preparing
    @State private var isVisible = false
    @State private var debugPreviewOutcome: MoodleAttendanceWebOutcome?

    private enum AttendancePreparationState: Equatable {
        case preparing
        case ready
        case failed(String)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch scanner.state {
            case .ready:
                scannerContent
            case .idle, .requestingPermission:
                loadingView
            case .denied:
                permissionDeniedView
            case .unavailable:
                unavailableView
            case .failed(let message):
                failureView(message: message)
            }
        }
        .navigationTitle("快速點名")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(Color.black, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .onAppear {
            isVisible = true
            scanner.onCode = handleScannedCode
            scanner.start()
            scanner.pauseScanning()
            prepareAttendanceAccess()
        }
        .onDisappear {
            isVisible = false
            validationTask?.cancel()
            preparationGeneration &+= 1
            preparationTask?.cancel()
            scanner.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            guard isVisible else { return }
            if phase == .active {
                scanner.start()
                if preparationState == .ready {
                    scanner.resumeScanning()
                } else {
                    scanner.pauseScanning()
                }
            } else {
                scanner.stop()
            }
        }
        .navigationDestination(isPresented: $isShowingAttendance) {
            if let attendanceURL {
                MoodleAttendanceSubmissionView(
                    attendanceURL: attendanceURL,
                    previewOutcome: debugPreviewOutcome,
                    onReturnHome: {
                        isShowingAttendance = false
                        dismiss()
                    }
                )
            }
        }
        .toolbar {
            #if DEBUG
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button("模擬點名成功", systemImage: "checkmark.circle") {
                        showDebugResult(
                            kind: .recorded,
                            message: "您在此上課時段的出席已被記錄。"
                        )
                    }
                    Button("模擬已完成點名", systemImage: "checkmark.seal") {
                        showDebugResult(
                            kind: .alreadyRecorded,
                            message: "您的出缺席已經設置好了。"
                        )
                    }
                    Button("模擬 QR Code 過期", systemImage: "exclamationmark.triangle") {
                        showDebugResult(
                            kind: .failed,
                            message: "QR Code 已過期，請重新掃描。"
                        )
                    }
                } label: {
                    Image(systemName: "hammer")
                }
                .accessibilityLabel("測試點名結果")
            }
            #endif
        }
    }

    private var scannerContent: some View {
        ZStack {
            AttendanceCameraPreview(
                session: scanner.session,
                onFocus: scanner.focus,
                onPinch: scanner.updateZoom
            )
            .ignoresSafeArea(edges: .bottom)

            LinearGradient(
                colors: [.black.opacity(0.55), .clear, .black.opacity(0.78)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                instructionHeader
                Spacer()
                scanFrame
                Spacer()
                zoomControls
            }
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.bottom, Theme.Spacing.large)

            if let validationMessage {
                Text(validationMessage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.red.opacity(0.9), in: Capsule())
                    .padding(.horizontal, Theme.Spacing.large)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private var instructionHeader: some View {
        VStack(spacing: Theme.Spacing.small) {
            Text(preparationState == .ready ? "對準老師顯示的 QR Code" : "正在準備快速點名")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
            Text(preparationState == .ready
                 ? "可雙指縮放，或使用下方滑桿拉近畫面"
                 : "登入確認完成後即可掃描，不會浪費 QR Code 時效")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))

            preparationStatus
                .padding(.top, Theme.Spacing.xsmall)
        }
        .padding(.top, Theme.Spacing.large)
    }

    @ViewBuilder
    private var preparationStatus: some View {
        switch preparationState {
        case .preparing:
            HStack(spacing: Theme.Spacing.small) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                Text("正在確認 M 園區登入")
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())

        case .ready:
            Label("M 園區已就緒", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())

        case .failed(let message):
            VStack(spacing: Theme.Spacing.small) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .multilineTextAlignment(.center)
                Button("重新確認") {
                    prepareAttendanceAccess()
                }
                .font(.system(size: 13, weight: .bold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var scanFrame: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .stroke(Color.white.opacity(0.95), style: StrokeStyle(lineWidth: 3, dash: [20, 8]))
            .frame(maxWidth: 310, maxHeight: 310)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 44, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .shadow(color: .black.opacity(0.45), radius: 12)
            .allowsHitTesting(false)
    }

    private var zoomControls: some View {
        VStack(spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "minus.magnifyingglass")
                    .foregroundStyle(.white.opacity(0.8))

                Slider(
                    value: Binding(
                        get: { scanner.zoomFactor },
                        set: { scanner.setZoom($0) }
                    ),
                    in: 1...max(scanner.maxZoomFactor, 1)
                )
                .tint(.white)

                Text(String(format: "%.1f×", scanner.zoomFactor))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
            }

            HStack(spacing: Theme.Spacing.medium) {
                ForEach(scanner.zoomPresets, id: \.self) { factor in
                    Button {
                        scanner.setZoom(factor, animated: true)
                    } label: {
                        Text("\(Int(factor))×")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 34)
                            .background(
                                Circle().fill(
                                    abs(scanner.zoomFactor - factor) < 0.15
                                        ? Color.accentColor
                                        : Color.black.opacity(0.45)
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }

                if scanner.isTorchAvailable {
                    Button(action: scanner.toggleTorch) {
                        Image(systemName: scanner.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(scanner.isTorchOn ? .yellow : .white)
                            .frame(width: 42, height: 34)
                            .background(Circle().fill(Color.black.opacity(0.45)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(scanner.isTorchOn ? "關閉手電筒" : "開啟手電筒")
                }
            }
        }
        .padding(Theme.Spacing.medium)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var loadingView: some View {
        VStack(spacing: Theme.Spacing.medium) {
            ProgressView()
                .tint(.white)
            Text(scanner.state == .requestingPermission ? "正在取得相機權限…" : "正在啟動相機…")
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private var permissionDeniedView: some View {
        scannerMessageView(
            icon: "camera.fill",
            title: "需要相機權限",
            message: "開啟相機權限後，才能掃描 Moodle 點名 QR Code。",
            actionTitle: "前往設定"
        ) {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        }
    }

    private var unavailableView: some View {
        scannerMessageView(
            icon: "camera.metering.unknown",
            title: "找不到可用相機",
            message: "QR Code 掃描需要在有相機的 iPhone 或 iPad 上使用。"
        )
    }

    private func failureView(message: String) -> some View {
        scannerMessageView(
            icon: "exclamationmark.triangle",
            title: "相機啟動失敗",
            message: message,
            actionTitle: "重試",
            action: scanner.start
        )
    }

    private func scannerMessageView(
        icon: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: Theme.Spacing.medium) {
            Image(systemName: icon)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.white)
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(.white)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.xlarge)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func handleScannedCode(_ rawValue: String) {
        guard preparationState == .ready else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            withAnimation { validationMessage = "M 園區登入尚未準備完成" }
            return
        }

        guard let url = MoodleAttendanceQRCode.validatedURL(from: rawValue) else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            withAnimation { validationMessage = "這不是有效的 M 園區點名 QR Code" }
            validationTask?.cancel()
            validationTask = Task {
                try? await Task.sleep(for: .seconds(1.6))
                guard !Task.isCancelled else { return }
                withAnimation { validationMessage = nil }
                scanner.resumeScanning()
            }
            return
        }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        debugPreviewOutcome = nil
        attendanceURL = url
        isShowingAttendance = true
    }

    private func prepareAttendanceAccess() {
        preparationGeneration &+= 1
        let generation = preparationGeneration
        preparationTask?.cancel()
        preparationState = .preparing
        scanner.pauseScanning()

        preparationTask = Task {
            do {
                try await MoodleService.shared.prepareForAttendance()
                try Task.checkCancellation()
                guard generation == preparationGeneration, isVisible else { return }
                preparationState = .ready
                scanner.resumeScanning()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      generation == preparationGeneration,
                      isVisible else { return }
                scanner.pauseScanning()
                preparationState = .failed(preparationFailureMessage(for: error))
            }
        }
    }

    private func preparationFailureMessage(for error: Error) -> String {
        guard let moodleError = error as? MoodleError else {
            return "無法確認 M 園區登入，請檢查網路後重試"
        }
        switch moodleError {
        case .notAuthenticated:
            return "找不到登入資訊，請重新登入"
        case .autologinUnavailable:
            return "M 園區快速登入未啟用，請重新登入"
        default:
            return "無法確認 M 園區登入，請檢查網路後重試"
        }
    }

    #if DEBUG
    private func showDebugResult(kind: MoodleAttendanceWebOutcome.Kind, message: String) {
        attendanceURL = URL(
            string: "https://euni.niu.edu.tw/mod/attendance/attendance.php?qrpass=debug-preview&sessid=123456"
        )
        debugPreviewOutcome = MoodleAttendanceWebOutcome(
            kind: kind,
            message: message,
            courseModuleID: 1234
        )
        isShowingAttendance = true
    }
    #endif
}

private struct MoodleAttendanceSubmissionView: View {
    let attendanceURL: URL
    let previewOutcome: MoodleAttendanceWebOutcome?
    let onReturnHome: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var webManager = MoodleWebManager()
    @State private var showsWebResponse = false
    @State private var verificationState: VerificationState = .idle
    @State private var isVerificationRequest = false
    @State private var lastResolvedOutcome: MoodleAttendanceWebOutcome?

    init(
        attendanceURL: URL,
        previewOutcome: MoodleAttendanceWebOutcome? = nil,
        onReturnHome: @escaping () -> Void = {}
    ) {
        self.attendanceURL = attendanceURL
        self.previewOutcome = previewOutcome
        self.onReturnHome = onReturnHome
    }

    private enum VerificationState {
        case idle
        case checking
        case verified(status: String, detail: String)
        case warning(String)
    }

    private var outcome: MoodleAttendanceWebOutcome? {
        lastResolvedOutcome ?? webManager.attendanceOutcome ?? previewOutcome
    }

    private var shouldShowWebResponse: Bool {
        guard let outcome else { return false }
        return showsWebResponse || outcome.kind == .requiresAction || outcome.kind == .unknown
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            if previewOutcome == nil {
                AttendanceSubmissionWebView(manager: webManager)
                    .ignoresSafeArea(edges: .bottom)
                    .opacity(shouldShowWebResponse ? 1 : 0)
                    .allowsHitTesting(shouldShowWebResponse)
            }

            if !shouldShowWebResponse {
                resultContent
            }
        }
        .navigationTitle("點名結果")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: onReturnHome) {
                    Label("主頁", systemImage: "house")
                }
                .accessibilityLabel("回到主頁")
            }

            if showsWebResponse,
               outcome?.kind == .recorded || outcome?.kind == .alreadyRecorded || outcome?.kind == .failed {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("摘要") {
                        showsWebResponse = false
                    }
                }
            }
        }
        .onAppear {
            if previewOutcome == nil {
                webManager.loadWithSSO(targetURL: attendanceURL.absoluteString)
            }
        }
        .onChange(of: webManager.attendanceOutcome) { _, newValue in
            guard let newValue else { return }

            if isVerificationRequest {
                isVerificationRequest = false
                switch newValue.kind {
                case .recorded, .alreadyRecorded:
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    verificationState = .verified(
                        status: "已寫入",
                        detail: "已用相同 Session 向 M 園區重新查核"
                    )
                    showsWebResponse = false
                case .requiresAction:
                    verificationState = .warning("M 園區仍顯示可填寫表單，無法確認這次點名已寫入。")
                    showsWebResponse = true
                case .failed:
                    verificationState = .warning(newValue.message)
                    showsWebResponse = false
                case .unknown:
                    verificationState = .warning("M 園區沒有回傳可確認的驗證結果。")
                    showsWebResponse = true
                }
                return
            }

            if let lastResolvedOutcome,
               (lastResolvedOutcome.kind == .recorded || lastResolvedOutcome.kind == .alreadyRecorded),
               (newValue.kind == .unknown || newValue.kind == .requiresAction) {
                return
            }

            lastResolvedOutcome = newValue
            if newValue.kind == .requiresAction || newValue.kind == .unknown {
                showsWebResponse = true
            } else {
                showsWebResponse = false
                UINotificationFeedbackGenerator().notificationOccurred(
                    newValue.kind == .failed ? .error : .success
                )
            }
        }
    }

    @ViewBuilder
    private var resultContent: some View {
        if let message = webManager.errorMessage {
            stateView(
                icon: "exclamationmark.triangle.fill",
                color: .orange,
                title: "無法完成點名",
                message: message,
                showsVerification: false
            )
        } else if let outcome {
            switch outcome.kind {
            case .recorded:
                stateView(
                    icon: "checkmark.circle.fill",
                    color: .green,
                    title: "點名成功",
                    message: outcome.message,
                    showsVerification: true
                )
            case .alreadyRecorded:
                stateView(
                    icon: "checkmark.seal.fill",
                    color: .green,
                    title: "已完成點名",
                    message: outcome.message,
                    showsVerification: true
                )
            case .failed:
                stateView(
                    icon: "xmark.circle.fill",
                    color: .red,
                    title: "點名未完成",
                    message: outcome.message,
                    showsVerification: false
                )
            case .requiresAction, .unknown:
                EmptyView()
            }
        } else {
            loadingContent
        }
    }

    private var loadingContent: some View {
        VStack(spacing: Theme.Spacing.medium) {
            ProgressView()
                .controlSize(.large)
            Text("正在送出點名…")
                .font(.system(size: 18, weight: .semibold))
            Text("請不要離開此頁，正在等待 M 園區確認。")
                .font(.system(size: 14))
                .foregroundStyle(Color(.secondaryLabel))
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Spacing.xlarge)
    }

    private func stateView(
        icon: String,
        color: Color,
        title: String,
        message: String,
        showsVerification: Bool
    ) -> some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.large) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.12))
                        .frame(width: 104, height: 104)
                    Image(systemName: icon)
                        .font(.system(size: 58, weight: .medium))
                        .foregroundStyle(color)
                }
                .glassEffect(.regular, in: Circle())
                .padding(.top, Theme.Spacing.xlarge)

                VStack(spacing: Theme.Spacing.small) {
                    Text(title)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(.label))
                    Text(message)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color(.secondaryLabel))
                        .multilineTextAlignment(.center)
                }

                resultDetailCard(color: color, showsVerification: showsVerification)

                VStack(spacing: Theme.Spacing.small) {
                    if showsVerification {
                        Button {
                            verifyAttendanceRecord()
                        } label: {
                            HStack(spacing: Theme.Spacing.small) {
                                if case .checking = verificationState {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "checkmark.shield")
                                }
                                Text(verificationButtonTitle)
                            }
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(color)
                        .controlSize(.large)
                        .disabled(isVerifying)
                    }

                    Button {
                        showsWebResponse = true
                    } label: {
                        Label("查看 M 園區回應", systemImage: "safari")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button("返回掃描") {
                        dismiss()
                    }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(.secondaryLabel))
                    .padding(.top, Theme.Spacing.xsmall)
                }
            }
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.bottom, Theme.Spacing.xlarge)
        }
    }

    private func resultDetailCard(color: Color, showsVerification: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "server.rack")
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text("M 園區回應")
                        .font(.system(size: 15, weight: .semibold))
                    Text(showsVerification ? "伺服器已接受點名，可再核對出席紀錄" : "伺服器未確認這次點名")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(.secondaryLabel))
                }
                Spacer()
                Image(systemName: showsVerification ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(color)
            }

            Divider()

            HStack {
                Label("點名時段", systemImage: "clock")
                    .foregroundStyle(Color(.secondaryLabel))
                Spacer()
                Text(Date.now.formatted(date: .omitted, time: .shortened))
                    .fontWeight(.semibold)
            }
            .font(.system(size: 13))

            if let sessionID = MoodleAttendanceQRCode.sessionID(from: attendanceURL) {
                HStack {
                    Label("Session", systemImage: "number")
                        .foregroundStyle(Color(.secondaryLabel))
                    Spacer()
                    Text("\(sessionID)")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                .font(.system(size: 13))
            }

            verificationStatus
        }
        .padding(Theme.Spacing.medium)
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: Theme.CornerRadius.large, style: .continuous)
        )
    }

    @ViewBuilder
    private var verificationStatus: some View {
        switch verificationState {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: Theme.Spacing.small) {
                ProgressView()
                Text("正在讀取 M 園區出席紀錄…")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color(.secondaryLabel))
        case .verified(let status, let detail):
            HStack(alignment: .top, spacing: Theme.Spacing.small) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("已驗證：\(status)")
                        .font(.system(size: 14, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(.secondaryLabel))
                }
            }
        case .warning(let message):
            HStack(alignment: .top, spacing: Theme.Spacing.small) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(.secondaryLabel))
            }
        }
    }

    private var isVerifying: Bool {
        if case .checking = verificationState { return true }
        return false
    }

    private var verificationButtonTitle: String {
        switch verificationState {
        case .checking: return "驗證中…"
        case .verified: return "重新驗證出席紀錄"
        case .idle, .warning: return "驗證出席紀錄"
        }
    }

    private func verifyAttendanceRecord() {
        verificationState = .checking

        if previewOutcome != nil {
            Task {
                try? await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled else { return }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                verificationState = .verified(
                    status: "已寫入",
                    detail: "Debug 模式已完成相同 Session 的模擬核對"
                )
            }
            return
        }

        isVerificationRequest = true
        webManager.verifyAttendanceSubmission()
    }
}

private struct AttendanceSubmissionWebView: UIViewRepresentable {
    let manager: MoodleWebManager

    func makeUIView(context: Context) -> WKWebView {
        manager.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

enum MoodleAttendanceQRCode {
    static func validatedURL(from rawValue: String) -> URL? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "euni.niu.edu.tw",
              components.port == nil || components.port == 443,
              components.user == nil,
              components.password == nil,
              components.path.lowercased() == "/mod/attendance/attendance.php"
        else { return nil }

        let queryItems = components.queryItems ?? []
        guard queryItems.count == 2,
              let qrPass = queryItems.first(where: { $0.name.lowercased() == "qrpass" })?.value,
              !qrPass.isEmpty,
              qrPass.count <= 256,
              let sessionValue = queryItems.first(where: { $0.name.lowercased() == "sessid" })?.value,
              let sessionID = Int(sessionValue),
              sessionID > 0
        else { return nil }

        // Forward only the expected values, discarding fragments and URL decorations.
        components.queryItems = [
            URLQueryItem(name: "qrpass", value: qrPass),
            URLQueryItem(name: "sessid", value: sessionValue)
        ]
        components.port = nil
        components.fragment = nil
        return components.url
    }

    static func sessionID(from url: URL) -> Int? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name.lowercased() == "sessid" })?.value
        else { return nil }
        return Int(value)
    }
}

@MainActor
final class MoodleAttendanceScanner: NSObject, ObservableObject, AVCaptureMetadataOutputObjectsDelegate {
    enum State: Equatable {
        case idle
        case requestingPermission
        case ready
        case denied
        case unavailable
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var maxZoomFactor: CGFloat = 1
    @Published private(set) var isTorchAvailable = false
    @Published private(set) var isTorchOn = false

    let session = AVCaptureSession()
    var onCode: ((String) -> Void)?

    var zoomPresets: [CGFloat] {
        [1, 2, 4].filter { $0 <= maxZoomFactor }
    }

    private let metadataOutput = AVCaptureMetadataOutput()
    private let metadataQueue = DispatchQueue(label: "tw.edu.niu.attendance.metadata")
    private let sessionQueue = DispatchQueue(label: "tw.edu.niu.attendance.session", qos: .userInitiated)
    private var captureDevice: AVCaptureDevice?
    private var isConfigured = false
    private var isActive = false
    private var isAcceptingCodes = true
    private var pinchStartZoom: CGFloat = 1

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionInterruptionEnded),
            name: AVCaptureSession.interruptionEndedNotification,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionRuntimeError(_:)),
            name: AVCaptureSession.runtimeErrorNotification,
            object: session
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func start() {
        isActive = true
        isAcceptingCodes = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureIfNeeded()
        case .notDetermined:
            state = .requestingPermission
            Task { [weak self] in
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                guard let self, self.isActive else { return }
                if granted {
                    self.configureIfNeeded()
                } else {
                    self.state = .denied
                }
            }
        case .denied, .restricted:
            state = .denied
        @unknown default:
            state = .failed("無法確認相機權限狀態")
        }
    }

    func stop() {
        isActive = false
        isAcceptingCodes = false
        setTorch(false)
        let captureSession = session
        sessionQueue.async {
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
    }

    func resumeScanning() {
        guard isActive else { return }
        isAcceptingCodes = true
        startSessionIfNeeded()
    }

    func pauseScanning() {
        isAcceptingCodes = false
    }

    func setZoom(_ factor: CGFloat, animated: Bool = false) {
        guard let captureDevice else { return }
        let clamped = min(max(factor, 1), maxZoomFactor)
        do {
            try captureDevice.lockForConfiguration()
            if animated {
                captureDevice.ramp(toVideoZoomFactor: clamped, withRate: 8)
            } else {
                captureDevice.videoZoomFactor = clamped
            }
            captureDevice.unlockForConfiguration()
            zoomFactor = clamped
        } catch {
            state = .failed("無法調整相機焦距")
        }
    }

    func updateZoom(scale: CGFloat, state gestureState: UIGestureRecognizer.State) {
        switch gestureState {
        case .began:
            pinchStartZoom = zoomFactor
        case .changed:
            setZoom(pinchStartZoom * scale)
        default:
            break
        }
    }

    func focus(at point: CGPoint) {
        guard let captureDevice else { return }
        do {
            try captureDevice.lockForConfiguration()
            if captureDevice.isFocusPointOfInterestSupported {
                captureDevice.focusPointOfInterest = point
                if captureDevice.isFocusModeSupported(.continuousAutoFocus) {
                    captureDevice.focusMode = .continuousAutoFocus
                } else if captureDevice.isFocusModeSupported(.autoFocus) {
                    captureDevice.focusMode = .autoFocus
                }
            }
            if captureDevice.isExposurePointOfInterestSupported {
                captureDevice.exposurePointOfInterest = point
                captureDevice.exposureMode = .continuousAutoExposure
            }
            captureDevice.unlockForConfiguration()
        } catch {
            // Continuous autofocus remains active if tap-to-focus cannot be applied.
        }
    }

    func toggleTorch() {
        setTorch(!isTorchOn)
    }

    @objc private func sessionInterruptionEnded() {
        Task { @MainActor [weak self] in
            guard let self, self.isActive else { return }
            self.state = .ready
            self.startSessionIfNeeded()
        }
    }

    @objc private func sessionRuntimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
        Task { @MainActor [weak self] in
            guard let self, self.isActive else { return }
            if error?.code == .mediaServicesWereReset {
                self.startSessionIfNeeded()
            } else {
                self.state = .failed("相機暫時中斷，請重試")
            }
        }
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let value = metadataObjects
            .compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
            .first(where: { $0.type == .qr })?
            .stringValue
        else { return }

        Task { @MainActor [weak self] in
            guard let self, self.isAcceptingCodes else { return }
            self.isAcceptingCodes = false
            self.onCode?(value)
        }
    }

    private func configureIfNeeded() {
        if isConfigured {
            state = .ready
            startSessionIfNeeded()
            return
        }

        guard let device = bestBackCamera() else {
            state = .unavailable
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            session.sessionPreset = .high

            guard session.canAddInput(input), session.canAddOutput(metadataOutput) else {
                session.commitConfiguration()
                state = .failed("無法建立 QR Code 掃描器")
                return
            }

            session.addInput(input)
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: metadataQueue)
            metadataOutput.metadataObjectTypes = [.qr]
            session.commitConfiguration()

            captureDevice = device
            maxZoomFactor = min(max(device.activeFormat.videoMaxZoomFactor, 1), 12)
            isTorchAvailable = device.hasTorch
            isConfigured = true
            configureContinuousFocus(on: device)
            state = .ready
            startSessionIfNeeded()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func bestBackCamera() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    private func configureContinuousFocus(on device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = true
            }
            device.isSubjectAreaChangeMonitoringEnabled = true
            device.unlockForConfiguration()
        } catch {
            // The scanner remains usable with the camera's default focus behavior.
        }
    }

    private func startSessionIfNeeded() {
        guard isConfigured, isActive else { return }
        let captureSession = session
        sessionQueue.async {
            if !captureSession.isRunning {
                captureSession.startRunning()
            }
        }
    }

    private func setTorch(_ enabled: Bool) {
        guard let captureDevice, captureDevice.hasTorch else { return }
        do {
            try captureDevice.lockForConfiguration()
            captureDevice.torchMode = enabled ? .on : .off
            captureDevice.unlockForConfiguration()
            isTorchOn = enabled
        } catch {
            isTorchOn = false
        }
    }
}

private struct AttendanceCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let onFocus: (CGPoint) -> Void
    let onPinch: (CGFloat, UIGestureRecognizer.State) -> Void

    func makeUIView(context: Context) -> AttendancePreviewView {
        let view = AttendancePreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.onFocus = onFocus
        view.onPinch = onPinch
        return view
    }

    func updateUIView(_ uiView: AttendancePreviewView, context: Context) {
        uiView.onFocus = onFocus
        uiView.onPinch = onPinch
    }
}

private final class AttendancePreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    var onFocus: ((CGPoint) -> Void)?
    var onPinch: ((CGFloat, UIGestureRecognizer.State) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTap(_:))))
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(didPinch(_:))))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func didTap(_ recognizer: UITapGestureRecognizer) {
        let layerPoint = recognizer.location(in: self)
        onFocus?(previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint))
    }

    @objc private func didPinch(_ recognizer: UIPinchGestureRecognizer) {
        onPinch?(recognizer.scale, recognizer.state)
    }
}

#Preview("點名成功") {
    NavigationStack {
        MoodleAttendanceSubmissionView(
            attendanceURL: URL(
                string: "https://euni.niu.edu.tw/mod/attendance/attendance.php?qrpass=preview&sessid=123456"
            )!,
            previewOutcome: MoodleAttendanceWebOutcome(
                kind: .recorded,
                message: "您在此上課時段的出席已被記錄。",
                courseModuleID: 1234
            )
        )
    }
}
