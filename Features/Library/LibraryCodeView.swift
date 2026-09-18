import SwiftUI

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

                codeContent
                    .frame(maxWidth: .infinity, minHeight: 280)
                    .padding(20)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 20))
                    .privacySensitive()

                if let updatedAt, displayedRequest == requestIdentity, image != nil {
                    Text("最後更新：\(updatedAt.formatted(date: .omitted, time: .standard))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

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
        .navigationTitle("圖書館通行碼")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task(id: requestIdentity) {
            await displayCodes(for: requestIdentity)
        }
        .onDisappear { clearCode() }
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
