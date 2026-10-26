import Foundation
import SwiftUI
import PhotosUI
import Vision
import ImageIO
import CoreImage.CIFilterBuiltins
import Combine

/// A decoded code waiting for the user's confirmation; bound to the account that scanned it.
struct ScheduleImportCandidate: Identifiable {
    let id = UUID()
    let payload: ScheduleSharePayload
    let existing: ExchangedSchedule?
    fileprivate let account: String?
    fileprivate let sessionID: String?
}

@MainActor
final class ScheduleExchangeViewModel: ObservableObject {
    let store: ScheduleExchangeStore
    /// School data only; custom courses are never shared. Updated when the home schedule finishes loading.
    @Published var schedule: ClassSchedule?

    @Published var shareTerm: ScheduleShareTerm
    @Published private(set) var qrText: String?
    @Published private(set) var qrImage: UIImage?
    @Published private(set) var shareMessage: String?

    @Published var candidate: ScheduleImportCandidate?
    @Published var importMessage: String?
    @Published private(set) var isReadingPhoto = false
    /// One code at a time from either the camera or a photo. Closed until the scanner opens,
    /// while a code or photo is being handled, and again once the scanner closes.
    @Published private(set) var isAcceptingScans = false

    private var importGeneration = 0
    private var photoTask: Task<Void, Never>?
    private static let ciContext = CIContext()

    init(schedule: ClassSchedule?, store: ScheduleExchangeStore? = nil, now: Date = Date()) {
        self.schedule = schedule
        self.store = store ?? .shared
        shareTerm = ScheduleShareTerm(containing: now)
    }

    var currentTerm: ScheduleShareTerm { ScheduleShareTerm(containing: Date()) }
    var shareTermOptions: [ScheduleShareTerm] { [currentTerm, currentTerm.next] }

    var realName: String? {
        let name = UserDefaults.standard.string(forKey: StorageKeys.name)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : nil
    }

    var nickname: String {
        let preferences = store.preferences
        if preferences.nicknameMode == .realName, let realName { return realName }
        return preferences.customNickname
    }

    // MARK: - Sharing

    func regenerateCode(now: Date = Date()) {
        qrText = nil
        qrImage = nil
        guard store.status == .ready else { return }
        guard let schedule else {
            shareMessage = "尚未載入課表，請先回到課表頁更新。"
            return
        }
        let name = ScheduleSharePayload.cleanNickname(nickname)
        guard !name.isEmpty else {
            shareMessage = "請先輸入暱稱。"
            return
        }
        let preferences = store.preferences
        let payload = ScheduleSharePayload(schedule: schedule, shareID: preferences.shareID, term: shareTerm,
                                           nickname: name, includeRooms: preferences.includeRooms,
                                           includeTeachers: preferences.includeTeachers, createdAt: now)
        guard !payload.slots.isEmpty else {
            shareMessage = "課表中沒有可分享的課程。"
            return
        }
        do {
            let text = try payload.encoded()
            qrText = text
            qrImage = Self.qrImage(text)
            shareMessage = qrImage == nil ? "無法產生 QR Code，請重試。" : nil
        } catch ScheduleShareError.tooLarge {
            shareMessage = preferences.includeRooms || preferences.includeTeachers
                ? "課表內容太多，QR Code 會難以掃描。請關閉「教室」或「授課教師」後再試。"
                : "課表內容太多，無法放進一個 QR Code。"
        } catch {
            shareMessage = "無法產生 QR Code，請重試。"
        }
    }

    private static func qrImage(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = ciContext.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }

    // MARK: - Importing

    func beginScanning() {
        cancelAll()
        isAcceptingScans = true
    }

    /// Camera results arrive on the main actor; anything after the first accepted code is ignored.
    func handleScannedText(_ text: String) {
        guard isAcceptingScans, candidate == nil, importMessage == nil, !isReadingPhoto else { return }
        isAcceptingScans = false
        decode(text)
    }

    /// Pauses the camera so a photo result and a camera result can never both reach the preview.
    func importPhoto(_ item: PhotosPickerItem) {
        guard isAcceptingScans, candidate == nil else { return }
        photoTask?.cancel()
        importGeneration &+= 1
        let generation = importGeneration
        let account = currentAccount, sessionID = currentSessionID
        isAcceptingScans = false
        isReadingPhoto = true
        importMessage = nil
        photoTask = Task { [weak self] in
            let result: Result<[String], Error>
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw PhotoError.unreadable }
                result = .success(try await Task.detached(priority: .userInitiated) { try Self.detectCodes(in: data) }.value)
            } catch {
                result = .failure(error)
            }
            guard let self, !Task.isCancelled, generation == self.importGeneration,
                  account == self.currentAccount, sessionID == self.currentSessionID,
                  self.candidate == nil else { return }
            self.isReadingPhoto = false
            switch result {
            case .success(let codes):
                if let code = codes.first(where: { $0.hasPrefix("NIUTT") }) ?? codes.first {
                    self.decode(code)
                } else {
                    self.importMessage = "照片中找不到 QR Code，請確認截圖清楚完整。"
                }
            case .failure(let error):
                self.importMessage = (error as? PhotoError) == .tooLarge ? "照片檔案太大，請改用截圖。" : "無法讀取這張照片。"
            }
        }
    }

    func cancelPhotoImport() {
        photoTask?.cancel()
        photoTask = nil
        importGeneration &+= 1
        isReadingPhoto = false
    }

    private func decode(_ text: String) {
        do {
            let payload = try ScheduleSharePayload.decode(text, now: Date())
            candidate = ScheduleImportCandidate(payload: payload, existing: store.existing(matching: payload),
                                                account: currentAccount, sessionID: currentSessionID)
        } catch let error as ScheduleShareError {
            importMessage = error.message
        } catch {
            importMessage = ScheduleShareError.malformed.message
        }
    }

    /// Saves only if the same account and login session are still active; returns the saved entry's ID.
    @discardableResult
    func confirm(_ candidate: ScheduleImportCandidate, replaceExisting: Bool) -> UUID? {
        guard candidate.account == currentAccount, candidate.sessionID == currentSessionID, store.isCurrent else {
            importMessage = "帳號已變更，未儲存這份課表。"
            return nil
        }
        let savedID = store.save(candidate.payload, replacing: replaceExisting ? candidate.existing?.id : nil)
        if savedID == nil {
            importMessage = store.errorMessage ?? "無法儲存這份課表。"
            store.errorMessage = nil
        }
        return savedID
    }

    /// Discards the pending code or error and resumes scanning.
    func scanAgain() {
        candidate = nil
        importMessage = nil
        isAcceptingScans = true
    }

    /// Called when the scanner closes; late camera or photo callbacks are ignored afterwards.
    func cancelAll() {
        cancelPhotoImport()
        candidate = nil
        importMessage = nil
        isAcceptingScans = false
    }

    private var currentAccount: String? { UserDefaults.standard.string(forKey: StorageKeys.username) }
    private var currentSessionID: String? { UserDefaults.standard.string(forKey: StorageKeys.authSessionID) }

    // MARK: - Photo decoding

    private enum PhotoError: Error, Equatable { case unreadable, tooLarge }

    /// Downscales before detection so a huge image cannot exhaust memory.
    nonisolated private static func detectCodes(in data: Data) throws -> [String] {
        guard data.count <= 40 * 1024 * 1024 else { throw PhotoError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw PhotoError.unreadable }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PhotoError.unreadable
        }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }
}

// MARK: - Common free periods

extension ScheduleExchangeViewModel {
    /// The signed-in user's own table as a participant, for the current term only.
    func myPayload(for term: ScheduleShareTerm) -> ScheduleSharePayload? {
        guard let schedule, term == currentTerm else { return nil }
        return ScheduleSharePayload(schedule: schedule, shareID: UUID(), term: term, nickname: "我",
                                    includeRooms: false, includeTeachers: false, createdAt: Date())
    }
}
