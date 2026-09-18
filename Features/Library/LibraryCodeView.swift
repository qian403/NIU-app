import SwiftUI
import UIKit

struct LibraryCodeView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var kind: LibraryCodeKind = .entrance
    @State private var image: UIImage?
    @State private var updatedAt: Date?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var refreshID = 0
    @State private var displayedRequest: RequestIdentity?
    @State private var service = LibraryCodeService()
    @State private var isVisible = false

    private struct RequestIdentity: Equatable {
        let account: String
        let kind: LibraryCodeKind
        let active: Bool
        let refreshID: Int
    }

    private var requestIdentity: RequestIdentity {
        RequestIdentity(
            account: appState.isAuthenticated ? appState.currentUser?.username ?? "" : "",
            kind: kind,
            active: scenePhase == .active,
            refreshID: refreshID
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Picker("通行碼類型", selection: $kind) {
                    ForEach(LibraryCodeKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                VStack(spacing: 8) {
                    Image(systemName: kind == .entrance ? "qrcode" : "barcode")
                        .font(.system(size: 32))
                        .foregroundStyle(.tint)
                    Text(kind == .entrance ? "圖書館門禁" : "圖書館櫃台借書")
                        .font(.title2.bold())
                    Text(kind == .entrance ? "僅限當日進出圖書館使用" : "請向圖書館櫃台出示此條碼")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                // Keep the same footprint for the image, loading and error states.
                Color.white
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        codeContent
                            .padding(20)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .privacySensitive()

                Text("最後更新：\(updatedAt?.formatted(date: .omitted, time: .standard) ?? "—")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .opacity(showsUpdateTime ? 1 : 0)
                    .accessibilityHidden(!showsUpdateTime)

                Button {
                    refreshID += 1
                } label: {
                    Label("重新整理", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading || scenePhase != .active)

                Text("顯示期間每 5 分鐘自動更新，請連線取得最新圖碼。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: 540)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .background {
            LibraryCodeBrightnessView(isActive: isVisible && scenePhase == .active)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        .navigationTitle("圖書館通行碼")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task(id: requestIdentity) {
            await displayCodes(for: requestIdentity)
        }
        .onAppear { isVisible = true }
        .onDisappear {
            isVisible = false
            clearCode()
        }
    }

    private var showsUpdateTime: Bool {
        updatedAt != nil && displayedRequest == requestIdentity && image != nil
    }

    @ViewBuilder
    private var codeContent: some View {
        if scenePhase != .active {
            Label("回到 App 後重新取得通行碼", systemImage: "lock.fill")
                .foregroundStyle(.black.opacity(0.65))
        } else if displayedRequest == requestIdentity, let image {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 360)
                .accessibilityLabel(kind.title)
        } else if displayedRequest == requestIdentity, let errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.largeTitle)
                Text(errorMessage)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.black.opacity(0.65))
        } else {
            ProgressView("取得\(kind.title)中…")
                .tint(.gray)
                .foregroundStyle(.black.opacity(0.65))
        }
    }

    @MainActor
    private func displayCodes(for request: RequestIdentity) async {
        clearCode()
        displayedRequest = request
        guard request.active else { return }
        guard !request.account.isEmpty else {
            errorMessage = LibraryCodeError.missingAccount.localizedDescription
            return
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!

        while !Task.isCancelled {
            image = nil
            updatedAt = nil
            errorMessage = nil
            isLoading = true
            let requestStartedAt = Date()
            do {
                let newImage = try await service.image(for: request.kind, account: request.account)
                try Task.checkCancellation()
                guard requestIdentity == request else { return }
                // A code issued just before midnight may finish downloading
                // on the following day. Discard it and request today's code.
                guard calendar.isDate(requestStartedAt, inSameDayAs: Date()) else {
                    continue
                }
                image = newImage
                updatedAt = Date()
            } catch {
                guard !Task.isCancelled, requestIdentity == request else { return }
                // Avoid displaying transport errors containing a credential-bearing URL.
                errorMessage = (error as? LibraryCodeError)?.localizedDescription
                    ?? "無法連線至圖書館，請檢查網路後重新整理。"
            }
            isLoading = false

            // The portal refreshes every 300 seconds; also discard the code at
            // midnight in Taiwan, regardless of the device's time zone.
            let now = Date()
            let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
            let delay = min(300, max(0.1, midnight.timeIntervalSince(now)))
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
        }
    }

    private func clearCode() {
        image = nil
        updatedAt = nil
        errorMessage = nil
        isLoading = false
        displayedRequest = nil
    }
}

/// Owns a temporary brightness override for the screen displaying this page.
private struct LibraryCodeBrightnessView: UIViewRepresentable {
    let isActive: Bool

    func makeUIView(context: Context) -> BrightnessView { BrightnessView() }

    func updateUIView(_ uiView: BrightnessView, context: Context) {
        uiView.isActive = isActive
        uiView.updateBrightness()
    }

    static func dismantleUIView(_ uiView: BrightnessView, coordinator: ()) {
        uiView.isActive = false
        uiView.restoreBrightness()
    }

    final class BrightnessView: UIView {
        var isActive = false
        private var savedBrightness: CGFloat?
        private var adjustedScreen: UIScreen?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateBrightness()
        }

        func updateBrightness() {
            guard isActive, let screen = window?.windowScene?.screen else {
                restoreBrightness()
                return
            }
            guard adjustedScreen !== screen else { return }
            restoreBrightness()
            savedBrightness = screen.brightness
            adjustedScreen = screen
            screen.brightness = 1
        }

        func restoreBrightness() {
            if let adjustedScreen, let savedBrightness {
                adjustedScreen.brightness = savedBrightness
            }
            adjustedScreen = nil
            savedBrightness = nil
        }
    }
}
