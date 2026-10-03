import Foundation
import Combine
import UniformTypeIdentifiers
import ImageIO
import CoreGraphics

@MainActor
final class NativeMailViewModel: ObservableObject {
    static let shared = NativeMailViewModel()
    @Published private(set) var account = ""
    @Published private(set) var folders: [MailFolder] = []
    @Published private(set) var messages: [MailSummary] = []
    @Published private(set) var folder = "INBOX"
    @Published private(set) var total = 0
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var errorMessage: String?
    @Published var selected: MailSummary?
    @Published private(set) var content: MailMessageContent?
    @Published private(set) var htmlDocument: MailHTMLDocument?
    @Published private(set) var allowsExternalImages = false
    @Published private(set) var htmlImageRevision = 0
    @Published private(set) var detailError: String?
    @Published private(set) var isReading = false
    @Published private(set) var isDownloading = false
    @Published var sharedFile: URL?
    @Published var draft = MailDraft()
    @Published private(set) var isSending = false
    @Published private(set) var isImporting = false
    @Published private(set) var sendMessage: String?
    @Published private(set) var sendLocked = false
    @Published var composing = false
    @Published private(set) var banner: MailBanner?
    @Published var operationError: String?
    @Published private(set) var successFeedback = 0
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var downloadingPart: String?
    @Published private(set) var inlineThumbnails: [String: CGImage] = [:]
    @Published private(set) var inlineStatus: [String: String] = [:]
    @Published private(set) var activeDownloads: Set<String> = []
    @Published private(set) var downloadedFiles: [String: URL] = [:]
    @Published private(set) var linkedBody = AttributedString("")
    @Published private(set) var pendingMutations: Set<MailMessageKey> = []
    @Published private(set) var deletedMessage: MailMessageKey?
    @Published private(set) var uncertainMutations: Set<MailMessageKey> = []
    @Published private(set) var isPreparingDraft = false
    @Published var deleteConfirmation: MailSummary?
    @Published private(set) var forwardAttachments: [MailAttachmentInfo] = []

    var accountAddress: String { account.contains("@") || account.isEmpty ? account : account + "@niu.edu.tw" }
    var canLoadMore: Bool { !isLoading && errorMessage == nil && limit < min(total, 1000) }
    var statusText: String {
        if isLoading { return "正在檢查郵件…" }
        if let errorMessage { return errorMessage }
        guard let lastUpdated else { return "尚未更新" }
        if Date().timeIntervalSince(lastUpdated) < 60 { return "剛剛更新" }
        return "已更新 " + lastUpdated.formatted(date: .omitted, time: .shortened)
    }
    private var mutationTasks: [MailMessageKey: Task<Void, Never>] = [:]
    private var bannerTask: Task<Void, Never>?
    private var composeTask: Task<Void, Never>?
    private var composeToken = UUID()
    private var forwardKey: MailMessageKey?
    private var pendingOpenedSeen: MailMessageKey?

    private let fileStore: MailLocalFiles
    private let service: any NativeMailServing
    private let session: @MainActor () -> String?
    private let credentials: @MainActor () -> (username: String, password: String)?
    private var sessionID: String?
    private var epoch = UUID()
    private var inboxToken = UUID()
    private var listOwner: UUID?
    private var detailToken = UUID()
    private var listTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private struct DownloadJob {
        let item: MailAttachmentInfo
        let message: MailSummary
        let automatic: Bool
        let thumbnail: Bool
    }
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var downloadQueue: [DownloadJob] = []
    private var previewAfterDownload: Set<String> = []
    private var sendTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var files: [URL] = []
    private var limit = 50

    init(service: any NativeMailServing = NativeMailService(),
         fileStore: MailLocalFiles = .shared,
         session: @escaping @MainActor () -> String? = { UserDefaults.standard.string(forKey: StorageKeys.authSessionID) },
         credentials: @escaping @MainActor () -> (username: String, password: String)? = { LoginRepository.shared.getSavedCredentials() }) {
        self.service = service; self.fileStore = fileStore; self.session = session; self.credentials = credentials
        Task { await fileStore.prepare() }
    }

    deinit {
        listTask?.cancel(); detailTask?.cancel(); sendTask?.cancel(); importTask?.cancel()
        bannerTask?.cancel(); composeTask?.cancel()
        for task in mutationTasks.values { task.cancel() }
        for task in downloadTasks.values { task.cancel() }
    }

    func prepare(account: String) {
        let normalized = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let current = session(), !normalized.isEmpty else { reset(); return }
        if self.account != normalized || sessionID != current {
            reset(); self.account = normalized; sessionID = current
        }
        if !hasLoaded && !isLoading { reload() }
    }

    func reset() {
        epoch = UUID()
        bannerTask?.cancel(); bannerTask = nil; composeTask?.cancel(); composeTask = nil; composeToken = UUID()
        for task in mutationTasks.values { task.cancel() }
        mutationTasks = [:]; pendingMutations = []; uncertainMutations = []; deletedMessage = nil
        banner = nil; operationError = nil; composing = false; lastUpdated = nil
        forwardAttachments = []; forwardKey = nil; isPreparingDraft = false; deleteConfirmation = nil
        suspendReads(); closeMessage(); listOwner = nil
        sendTask?.cancel(); sendTask = nil
        importTask?.cancel(); importTask = nil
        account = ""; sessionID = nil; folders = []; messages = []; total = 0; folder = "INBOX"
        hasLoaded = false; errorMessage = nil; selected = nil; content = nil; detailError = nil
        draft = MailDraft(); sendMessage = nil; sendLocked = false; isSending = false; isImporting = false
        sharedFile = nil
        for file in files { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        files = []; limit = 50
    }

    func activateList(owner: UUID) { listOwner = owner }

    func suspendList(owner: UUID) {
        guard listOwner == owner else { return }
        listOwner = nil
        inboxToken = UUID(); listTask?.cancel(); listTask = nil; isLoading = false
    }

    func cancelComposePreparation() {
        composeToken = UUID(); composeTask?.cancel(); composeTask = nil; isPreparingDraft = false
    }

    func suspendReads() {
        inboxToken = UUID(); detailToken = UUID()
        listTask?.cancel(); listTask = nil; detailTask?.cancel(); detailTask = nil
        cancelDownloads()
        isLoading = false; isReading = false; isDownloading = false; downloadingPart = nil
        cancelComposePreparation()
    }

    private func login() throws -> MailCredentials {
        guard sessionID != nil, session() == sessionID, let saved = credentials(),
              saved.username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == account,
              !saved.password.isEmpty else { throw NativeMailError.credentials }
        return MailCredentials(username: account, password: saved.password)
    }

    private func current(_ epoch: UUID) -> Bool {
        self.epoch == epoch && sessionID != nil && session() == sessionID && !Task.isCancelled
    }

    func chooseFolder(_ name: String) {
        guard name != folder else { if !hasLoaded && !isLoading { reload() }; return }
        folder = name; messages = []; total = 0; hasLoaded = false; limit = 50
        selected = nil; closeMessage(); reload()
    }

    func reload(more: Bool = false) {
        guard pendingMutations.isEmpty, !more || canLoadMore else { return }
        listTask?.cancel(); inboxToken = UUID()
        let token = inboxToken, epoch = epoch, folder = folder, service = service
        let requestedLimit = min(1000, more ? limit + 50 : max(50, limit))
        errorMessage = nil
        do {
            let credentials = try login()
            isLoading = true
            listTask = Task { [weak self] in
                do {
                    let snapshot = try await service.inbox(credentials: credentials, folder: folder, limit: requestedLimit)
                    guard let self, self.current(epoch), self.inboxToken == token else { return }
                    self.folders = snapshot.folders; self.messages = snapshot.messages; self.total = snapshot.total
                    self.limit = requestedLimit; self.hasLoaded = true; self.lastUpdated = Date()
                    self.uncertainMutations = self.uncertainMutations.filter { $0.folder != folder }
                } catch {
                    guard let self, self.current(epoch), self.inboxToken == token else { return }
                    self.errorMessage = Self.message(error)
                }
                guard let self, self.current(epoch), self.inboxToken == token else { return }
                self.isLoading = false; self.listTask = nil
            }
        } catch { isLoading = false; errorMessage = Self.message(error) }
    }

    func refresh() async {
        let epoch = epoch
        for task in mutationTasks.values { await task.value }
        guard current(epoch) else { return }
        reload(); await listTask?.value
    }

    func loadMoreIfNeeded(_ summary: MailSummary) {
        if summary.id == messages.last?.id && canLoadMore { reload(more: true) }
    }

    func read(_ summary: MailSummary) {
        closeMessage(); selected = summary
        let token = detailToken, epoch = epoch, service = service
        do {
            let credentials = try login()
            isReading = true
            detailTask = Task { [weak self] in
                do {
                    let result = try await service.message(credentials: credentials, key: summary.id)
                    guard let self, self.current(epoch), self.detailToken == token else { return }
                    let htmlDocument: MailHTMLDocument?
                    if let html = result.html { htmlDocument = try? await MailHTMLPolicy.prepare(html, images: result.inlineImages) }
                    else { htmlDocument = nil }
                    let body = await Self.detectLinks(result.text)
                    guard self.current(epoch), self.detailToken == token else { return }
                    self.content = result; self.linkedBody = body; self.htmlDocument = htmlDocument
                    self.loadInlineImages()
                    if self.latest(summary).unread {
                        if self.pendingMutations.contains(summary.id) { self.pendingOpenedSeen = summary.id }
                        else { self.setSeen(summary, seen: true) }
                    }
                } catch {
                    guard let self, self.current(epoch), self.detailToken == token else { return }
                    self.detailError = Self.message(error)
                }
                guard let self, self.current(epoch), self.detailToken == token else { return }
                self.isReading = false; self.detailTask = nil
            }
        } catch { detailError = Self.message(error) }
    }

    func closeMessage() {
        detailToken = UUID(); detailTask?.cancel(); detailTask = nil
        cancelDownloads()
        htmlDocument = nil; allowsExternalImages = false; htmlImageRevision = 0
        content = nil; linkedBody = AttributedString(""); detailError = nil; isReading = false; isDownloading = false; sharedFile = nil
        downloadingPart = nil; downloadedFiles = [:]; pendingOpenedSeen = nil
    }

    private func cancelDownloads() {
        for task in downloadTasks.values { task.cancel() }
        downloadTasks = [:]; downloadQueue = []; previewAfterDownload = []
        activeDownloads = []; inlineThumbnails = [:]; inlineStatus = [:]
        isDownloading = false; downloadingPart = nil
    }

    func loadInlineImages() {
        guard let content, let selected else { return }
        let automatic = MailInlinePolicy.automaticIDs(content.inlineImages)
        for item in content.inlineImages where inlineThumbnails[item.id] == nil && inlineStatus[item.id] == nil {
            guard automatic.contains(item.id) else {
                inlineStatus[item.id] = item.size == nil ? "圖片大小不明，點擊下載" : "圖片過大，點擊下載"
                continue
            }
            inlineStatus[item.id] = "正在載入圖片…"
            enqueue(DownloadJob(item: item, message: selected, automatic: true, thumbnail: true))
        }
    }

    func allowExternalImages() {
        guard htmlDocument?.hasExternalImages == true else { return }
        // The screenshot service must remain offline even if its banner is tapped.
#if DEBUG
        guard !(service is NativeMailUIFixtureService) else { return }
#endif
        allowsExternalImages = true
    }

    func composeMailto(to: String, subject: String) {
        guard !isSending, !isImporting, !isPreparingDraft else { return }
        guard draft.isEmpty else {
            sendMessage = "目前已有草稿，請先儲存內容或刪除草稿，再撰寫另一封郵件。"
            composing = true; return
        }
        draft = MailDraft(); draft.to = to; draft.subject = subject
        sendLocked = false; sendMessage = nil; composing = true
    }

    func downloadHTMLImage(_ item: MailAttachmentInfo, message: MailSummary) {
        guard selected?.id == message.id else { return }
        enqueue(DownloadJob(item: item, message: message, automatic: false, thumbnail: true))
    }

    /// Joins the existing bounded download queue; no second IMAP request or credential owner.
    func cidData(part: String, message: MailMessageKey) async throws -> Data {
        let token = detailToken, epoch = epoch
        guard selected?.id == message, let content,
              content.inlineImages.contains(where: { $0.id == part }),
              downloadedFiles[part] != nil || MailInlinePolicy.automaticIDs(content.inlineImages).contains(part)
        else { throw NativeMailError.tooLarge }
        loadInlineImages()
        while activeDownloads.contains(part) {
            try await Task.sleep(for: .milliseconds(25))
            guard current(epoch), detailToken == token, selected?.id == message else { throw CancellationError() }
        }
        guard current(epoch), detailToken == token, selected?.id == message,
              let url = downloadedFiles[part] else { throw CancellationError() }
        let data = try await Self.readCIDFile(url)
        guard current(epoch), detailToken == token, selected?.id == message else { throw CancellationError() }
        return data
    }

    @concurrent private static func readCIDFile(_ url: URL) async throws -> Data {
        try Task.checkCancellation()
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= MailDraft.attachmentLimit else { throw NativeMailError.tooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= MailDraft.attachmentLimit else { throw NativeMailError.tooLarge }
        try Task.checkCancellation()
        return data
    }

    func download(_ attachment: MailAttachmentInfo, message: MailSummary) {
        guard selected?.id == message.id else { return }
        if let url = downloadedFiles[attachment.id] { sharedFile = url; return }
        previewAfterDownload.insert(attachment.id)
        let thumbnail = content?.inlineImages.contains { $0.id == attachment.id } == true
        enqueue(DownloadJob(item: attachment, message: message, automatic: false, thumbnail: thumbnail))
    }

    private func enqueue(_ job: DownloadJob) {
        guard downloadTasks[job.item.id] == nil, !downloadQueue.contains(where: { $0.item.id == job.item.id }) else { return }
        downloadQueue.append(job)
        activeDownloads.insert(job.item.id)
        pumpDownloads()
    }

    private func pumpDownloads() {
        // One shared queue for thumbnails and attachment cards; at most two network/decode jobs.
        while downloadTasks.count < 2 && !downloadQueue.isEmpty {
            let job = downloadQueue.removeFirst(), token = detailToken, epoch = epoch
            let service = service, fileStore = fileStore, cached = downloadedFiles[job.item.id]
            do {
                let credentials = try login()
                isDownloading = true; downloadingPart = job.item.id
                downloadTasks[job.item.id] = Task { [weak self] in
                    var saved: URL?
                    do {
                        let url: URL
                        if let cached { url = cached }
                        else {
                            let limit = job.automatic ? min(job.item.size ?? 0, MailInlinePolicy.imageLimit) : MailDraft.attachmentLimit
                            let data = try await service.attachment(credentials: credentials, key: job.message.id,
                                                                    part: job.item.id, maximumBytes: limit)
                            try Task.checkCancellation()
                            guard data.count <= limit else { throw NativeMailError.tooLarge }
                            url = try await fileStore.save(data, name: job.item.name)
                            saved = url
                        }
                        try Task.checkCancellation()
                        let thumbnail = job.thumbnail ? await Self.thumbnail(url) : nil
                        try Task.checkCancellation()
                        guard let self, self.current(epoch), self.detailToken == token else {
                            if let saved { try? FileManager.default.removeItem(at: saved.deletingLastPathComponent()) }
                            return
                        }
                        if saved != nil { self.files.append(url) }
                        self.downloadedFiles[job.item.id] = url
                        if job.thumbnail {
                            self.inlineThumbnails[job.item.id] = thumbnail
                            self.inlineStatus[job.item.id] = thumbnail == nil ? "此格式無法顯示縮圖，點擊預覽檔案" : nil
                        }
                        if !job.automatic && self.htmlDocument?.referencedParts.contains(job.item.id) == true {
                            self.htmlImageRevision += 1
                        }
                        if self.previewAfterDownload.remove(job.item.id) != nil { self.sharedFile = url }
                    } catch {
                        if let saved { try? FileManager.default.removeItem(at: saved.deletingLastPathComponent()) }
                        guard let self, self.current(epoch), self.detailToken == token else { return }
                        if job.thumbnail {
                            self.inlineStatus[job.item.id] = (error as? NativeMailError) == .tooLarge
                                ? "圖片過大，點擊下載" : "圖片載入失敗，點擊重試"
                        }
                        if self.previewAfterDownload.remove(job.item.id) != nil { self.detailError = Self.message(error) }
                    }
                    guard let self, self.current(epoch), self.detailToken == token else { return }
                    self.downloadTasks[job.item.id] = nil; self.activeDownloads.remove(job.item.id)
                    self.isDownloading = !self.activeDownloads.isEmpty
                    self.downloadingPart = self.activeDownloads.first
                    self.pumpDownloads()
                }
            } catch {
                activeDownloads.remove(job.item.id); previewAfterDownload.remove(job.item.id)
                inlineStatus[job.item.id] = "圖片載入失敗，點擊重試"
                detailError = Self.message(error)
            }
        }
    }

    @concurrent private static func thumbnail(_ url: URL) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        return autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600
            ] as CFDictionary)
        }
    }

    func newDraft(replyTo summary: MailSummary? = nil) {
        guard !isSending, !isImporting, !isPreparingDraft else { return }
        if let summary { compose(.reply, summary: summary); return }
        if draft.isEmpty { draft = MailDraft(); sendLocked = false; sendMessage = nil }
        composing = true
    }

    func newDraft(to address: String) {
        guard !isSending, !isImporting, !isPreparingDraft else { return }
        guard draft.isEmpty else {
            sendMessage = "目前已有草稿，請先儲存內容或刪除草稿，再撰寫另一封郵件。"
            composing = true; return
        }
        newDraft()
        draft.to = address
    }

    func reopenDraft() { guard !isSending else { return }; composing = true }

    func compose(_ action: MailComposeAction, summary: MailSummary) {
        guard !isSending, !isImporting, !isPreparingDraft else { return }
        guard draft.isEmpty else {
            sendMessage = "目前已有草稿，請先儲存內容或刪除草稿，再撰寫另一封郵件。"
            composing = true; return
        }
        let epoch = epoch, token = UUID(), service = service
        composeToken = token; isPreparingDraft = true
        do {
            let credentials = try login()
            let cached = selected?.id == summary.id ? content : nil
            composeTask = Task { [weak self] in
                do {
                    let result: MailMessageContent
                    if let cached { result = cached }
                    else { result = try await service.message(credentials: credentials, key: summary.id) }
                    guard let self, self.current(epoch), self.composeToken == token else { return }
                    self.draft = MailDraft.prefilled(action, summary: summary, content: result, ownAddress: credentials.address)
                    self.sendLocked = false; self.sendMessage = nil
                    self.forwardKey = action == .forward ? summary.id : nil
                    self.forwardAttachments = action == .forward ? result.attachments : []
                    self.composing = true
                } catch {
                    guard let self, self.current(epoch), self.composeToken == token else { return }
                    self.operationError = Self.message(error)
                }
                guard let self, self.current(epoch), self.composeToken == token else { return }
                self.isPreparingDraft = false; self.composeTask = nil
            }
        } catch { isPreparingDraft = false; operationError = Self.message(error) }
    }

    func includeForwardAttachments() {
        guard !isImporting, !isSending, !sendLocked, let key = forwardKey, !forwardAttachments.isEmpty else { return }
        let epoch = epoch, draftID = draft.messageID, service = service, attachments = forwardAttachments
        let available = MailDraft.attachmentLimit - draft.attachments.reduce(0) { $0 + $1.data.count }
        do {
            let credentials = try login()
            isImporting = true
            importTask = Task { [weak self] in
                do {
                    var items: [MailOutgoingAttachment] = [], remaining = available
                    for item in attachments {
                        try Task.checkCancellation()
                        guard (item.size ?? 0) <= remaining else { throw NativeMailError.tooLarge }
                        let data = try await service.attachment(credentials: credentials, key: key, part: item.id)
                        guard data.count <= remaining else { throw NativeMailError.tooLarge }
                        remaining -= data.count
                        let mime = UTType(filenameExtension: (item.name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                        items.append(MailOutgoingAttachment(name: CampusMailWebPolicy.filename(item.name), mime: mime, data: data))
                    }
                    guard let self, self.current(epoch), self.draft.messageID == draftID else { return }
                    self.draft.attachments += items; self.forwardAttachments = []; self.forwardKey = nil
                } catch {
                    guard let self, self.current(epoch), self.draft.messageID == draftID else { return }
                    self.sendMessage = Self.message(error)
                }
                guard let self, self.current(epoch), self.draft.messageID == draftID else { return }
                self.isImporting = false; self.importTask = nil
            }
        } catch { sendMessage = Self.message(error) }
    }

    func discardDraft() {
        guard !isSending else { return }
        importTask?.cancel(); importTask = nil; isImporting = false
        draft = MailDraft(); sendMessage = nil; sendLocked = false
        forwardAttachments = []; forwardKey = nil; dismissBanner()
    }

    func attachmentImportFailed() {
        sendMessage = "無法讀取選取的檔案，請重新選擇附件。"
    }

    func importAttachments(_ urls: [URL]) {
        guard !isImporting, !isSending, !sendLocked else { return }
        let epoch = epoch, draftID = draft.messageID, fileStore = fileStore
        let available = MailDraft.attachmentLimit - draft.attachments.reduce(0) { $0 + $1.data.count }
        isImporting = true
        importTask = Task { [weak self] in
            do {
                let items = try await fileStore.load(urls, limit: available)
                guard let self, self.current(epoch), self.draft.messageID == draftID else { return }
                self.draft.attachments += items
            } catch {
                guard let self, self.current(epoch), self.draft.messageID == draftID else { return }
                self.sendMessage = Self.message(error)
            }
            guard let self, self.current(epoch), self.draft.messageID == draftID else { return }
            self.isImporting = false; self.importTask = nil
        }
    }

    func send() {
        guard !isSending, !sendLocked, !isImporting else { return }
        let epoch = epoch, service = service, draft = draft
        do {
            try draft.validate()
            let credentials = try login()
            isSending = true; sendMessage = nil; composing = false
            showBanner(.sending, text: "正在傳送…")
            sendTask = Task { [weak self] in
                do {
                    let result = try await service.send(credentials: credentials, draft: draft)
                    guard let self, self.current(epoch) else { return }
                    self.sendLocked = true
                    if case .accepted(let saved) = result {
                        self.sendMessage = saved ? "郵件已寄出" : "已寄出，但寄件備份未儲存。請勿重寄。"
                        self.showBanner(saved ? .success : .warning, text: saved ? "郵件已寄出" : "已寄出，但寄件備份未儲存")
                        self.successFeedback += 1
                    }
                    // Release attachment/body data after accepted delivery.
                    self.draft = MailDraft(); self.forwardAttachments = []; self.forwardKey = nil
                } catch {
                    guard let self, self.current(epoch) else { return }
                    if case NativeMailError.deliveryUnknown = error { self.sendLocked = true }
                    self.sendMessage = Self.message(error)
                    self.showBanner(self.sendLocked ? .unknown : .failure,
                                    text: self.sendLocked ? "寄送結果不明，請先確認收件情況；這份草稿已鎖定，避免重寄。" : "無法寄出郵件：\(self.sendMessage ?? "傳送已取消，請稍後重試。")")
                }
                guard let self, self.current(epoch) else { return }
                self.isSending = false; self.sendTask = nil
            }
        } catch { sendMessage = Self.message(error) }
    }

    func dismissBanner() {
        guard banner?.kind != .sending else { return }
        bannerTask?.cancel(); bannerTask = nil; banner = nil
    }

    #if DEBUG
    /// Stable screenshot states; no send task or automatic success dismissal.
    func showUIFixtureBanner(_ screen: NativeMailUIFixtureScreen) {
        guard screen == .sending || screen == .sent || screen == .failure else { return }
        bannerTask?.cancel(); bannerTask = nil
        composing = false
        draft = screen == .sent ? MailDraft() : NativeMailUIFixtureService.screenshotDraft()
        isSending = screen == .sending
        sendLocked = screen == .sent
        switch screen {
        case .sending:
            sendMessage = nil
            banner = MailBanner(kind: .sending, text: "正在傳送…")
        case .sent:
            sendMessage = "郵件已寄出"
            banner = MailBanner(kind: .success, text: "郵件已寄出")
        case .failure:
            sendMessage = NativeMailError.rejected.errorDescription
            banner = MailBanner(kind: .failure, text: "無法寄出郵件：\(sendMessage ?? "校方拒絕寄送。")")
        default:
            break
        }
    }
    #endif

    private func showBanner(_ kind: MailBanner.Kind, text: String) {
        bannerTask?.cancel()
        let banner = MailBanner(kind: kind, text: text), epoch = epoch
        self.banner = banner
        if kind == .success {
            bannerTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard let self, self.current(epoch), self.banner?.id == banner.id else { return }
                self.banner = nil; self.bannerTask = nil
            }
        }
    }

    func latest(_ summary: MailSummary) -> MailSummary {
        messages.first { $0.id == summary.id } ?? (selected?.id == summary.id ? selected : nil) ?? summary
    }

    func requestDelete(_ summary: MailSummary) {
        if !folders.contains(where: { $0.role == .trash && $0.id != summary.id.folder }) {
            deleteConfirmation = summary
        } else { moveToTrash(summary) }
    }

    func setSeen(_ summary: MailSummary, seen: Bool) { mutate(summary, change: .seen(seen)) }
    func setFlagged(_ summary: MailSummary, flagged: Bool) { mutate(summary, change: .flagged(flagged)) }
    func moveToTrash(_ summary: MailSummary, confirmed: Bool = false) { mutate(summary, change: .trash(confirmed)) }

    private enum Change { case seen(Bool), flagged(Bool), trash(Bool) }
    private func mutate(_ summary: MailSummary, change: Change) {
        let original = latest(summary), key = summary.id
        guard !pendingMutations.contains(key), !uncertainMutations.contains(key) else { return }
        do {
            let credentials = try login(), epoch = epoch, service = service
            inboxToken = UUID(); listTask?.cancel(); listTask = nil; isLoading = false
            pendingMutations.insert(key)
            var updated = original
            var unreadDelta = 0
            switch change {
            case .seen(let seen): updated.unread = !seen; unreadDelta = (seen ? 0 : 1) - (original.unread ? 1 : 0)
            case .flagged(let flagged): updated.flagged = flagged
            case .trash: unreadDelta = original.unread ? -1 : 0
            }
            let deleting: Bool
            if case .trash = change { deleting = true } else { deleting = false }
            if deleting {
                messages.removeAll { $0.id == key }
                if folder == key.folder { total = max(0, total - 1) }
            } else {
                if let index = messages.firstIndex(where: { $0.id == key }) { messages[index] = updated }
                if selected?.id == key { selected = updated }
            }
            adjustUnread(key.folder, by: unreadDelta)
            let delta = unreadDelta
            mutationTasks[key] = Task { [weak self] in
                do {
                    switch change {
                    case .seen(let seen): try await service.setSeen(credentials: credentials, key: key, seen: seen)
                    case .flagged(let flagged): try await service.setFlagged(credentials: credentials, key: key, flagged: flagged)
                    case .trash(let confirmed): try await service.moveToTrash(credentials: credentials, key: key, allowMarkDeleted: confirmed)
                    }
                    guard let self, self.current(epoch) else { return }
                    if deleting {
                        self.deletedMessage = key
                        if self.selected?.id == key { self.selected = nil; self.closeMessage() }
                    }
                } catch {
                    guard let self, self.current(epoch) else { return }
                    if self.folder == key.folder {
                        if deleting {
                            self.messages.append(original); self.messages.sort { $0.id.uid > $1.id.uid }; self.total += 1
                        } else if let index = self.messages.firstIndex(where: { $0.id == key }) { self.messages[index] = original }
                    }
                    if self.selected?.id == key { self.selected = original }
                    self.adjustUnread(key.folder, by: -delta)
                    self.operationError = Self.message(error)
                    if case NativeMailError.noTrash = error { self.deleteConfirmation = original }
                    if case NativeMailError.mutationUncertain = error { self.uncertainMutations.insert(key) }
                }
                guard let self, self.current(epoch) else { return }
                self.pendingMutations.remove(key); self.mutationTasks[key] = nil
                if self.pendingOpenedSeen == key {
                    self.pendingOpenedSeen = nil
                    if let selected = self.selected, selected.id == key, self.content != nil, selected.unread {
                        self.setSeen(selected, seen: true)
                    }
                }
                if !self.hasLoaded && self.pendingMutations.isEmpty { self.reload() }
            }
        } catch { operationError = Self.message(error) }
    }

    private func adjustUnread(_ folder: String, by delta: Int) {
        if let index = folders.firstIndex(where: { $0.id == folder }), let count = folders[index].unreadCount {
            folders[index].unreadCount = max(0, count + delta)
        }
    }

    @concurrent private static func detectLinks(_ text: String) async -> AttributedString {
        var result = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return result }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? ""),
                  let range = Range(match.range, in: text), let attributedRange = Range(range, in: result) else { continue }
            result[attributedRange].link = url
        }
        return result
    }

    private static func message(_ error: Error) -> String? {
        if error is CancellationError { return nil }
        return (error as? NativeMailError)?.errorDescription ?? "郵件操作未完成，請稍後重試。"
    }
}

actor MailLocalFiles {
    static let shared = MailLocalFiles()
    private let root: URL
    init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("NIUNativeMail", isDirectory: true)) {
        self.root = root
    }
    private var prepared = false

    func prepare() {
        guard !prepared else { return }
        prepared = true
        // Remove artifacts left by a terminated previous process, before this process writes any.
        try? FileManager.default.removeItem(at: root)
    }

    func load(_ urls: [URL], limit: Int) async throws -> [MailOutgoingAttachment] {
        var remaining = limit
        var result: [MailOutgoingAttachment] = []
        for url in urls {
            try Task.checkCancellation()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: remaining + 1) ?? Data()
            guard data.count <= remaining else { throw NativeMailError.tooLarge }
            remaining -= data.count
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            result.append(MailOutgoingAttachment(name: CampusMailWebPolicy.filename(url.lastPathComponent), mime: mime, data: data))
        }
        return result
    }

    func save(_ data: Data, name: String) async throws -> URL {
        prepare()
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(CampusMailWebPolicy.filename(name))
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}
