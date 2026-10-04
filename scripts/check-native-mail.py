#!/usr/bin/env python3
"""Offline native-mail state/credential/race tests. No real Keychain or network."""
from pathlib import Path
import subprocess
import tempfile
import os
import json
import plistlib
import re

root = Path(__file__).resolve().parents[1]
# Execute the exact App-owned measurement against a write-trapping DOM. Only
# size getters are exposed, so DOM mutation / resource access fails the test.
policy_source = (root / "Features/Mail/Native/MailHTMLPolicy.swift").read_text()
measurement = re.search(r'static let measurementScript = """(.*?)"""', policy_source, re.S).group(1)
subprocess.run(["node", "-e", r'''
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = process.argv[1];
function readonly(value) {
    return new Proxy(Object.freeze(value), {
        get(target, key) { assert(Object.hasOwn(target, key), `Unexpected DOM access: ${String(key)}`); return target[key]; },
        set() { throw Error('DOM write'); },
        defineProperty() { throw Error('DOM defineProperty'); },
        deleteProperty() { throw Error('DOM delete'); }
    });
}
for (const [rootWidth, bodyWidth, rootHeight, bodyHeight, right, bottom] of
        [[335,700,1,600,700,600],[700,335,800,48,700,800],[402,402,100,100,700,600]]) {
    const document = readonly({documentElement: readonly({scrollWidth:rootWidth, scrollHeight:rootHeight, clientWidth:402}),
        body: readonly({scrollWidth:bodyWidth, scrollHeight:bodyHeight}),
        querySelectorAll(selector) {
            assert.equal(selector, '*');
            return [readonly({getBoundingClientRect() { return readonly({right:200, bottom:48}); }}),
                    readonly({getBoundingClientRect() { return readonly({right, bottom}); }})];
        }});
    const result = vm.runInNewContext('"use strict"; ' + source, {document}, {timeout:1000});
    assert.equal(result.width, Math.max(rootWidth, bodyWidth));
    assert.equal(result.height, Math.max(rootHeight, bodyHeight));
    assert.equal(result.clientWidth, 402);
    assert.equal(result.right, right);
    assert.equal(result.bottom, bottom);
}
console.log('PASS: read-only geometry includes clipped 700px descendant and bottom despite 402px scrollWidth');
''', measurement], check=True)
html_view_source = (root / "Features/Mail/Native/MailHTMLView.swift").read_text()
assert 'allowsContentJavaScript = false' in html_view_source and 'in: .defaultClient' in html_view_source
assert 'UIFontMetrics' not in html_view_source
app_info = plistlib.loads((root / "App/Info.plist").read_bytes())
assert "NSAppTransportSecurity" not in app_info, "Mail must not introduce app-wide ATS exceptions"
service_source = (root / "Features/Mail/Native/NativeMailService.swift").read_text()
components_source = (root / "Features/Mail/Native/MailComponents.swift").read_text()
assert "offset: 0, count: 1024" in service_source and "count - 8" not in service_source
for role in ("inbox", "sent", "drafts", "trash", "junk"):
    assert f"folder.attributes.contains(.{role})" in service_source
assert "Self.folderRole($0) == .trash" in service_source
assert any(f'.lineLimit(banner.kind == .failure ? {lines} : nil)' in components_source for lines in (1, 2))
assert '.accessibilityLabel(banner.text)' in components_source
fixture_source = (root / "Features/Mail/Native/NativeMailUIFixtureService.swift").read_text()
assert fixture_source.startswith("#if DEBUG\n") and fixture_source.rstrip().endswith("#endif")
assert 'hasAttachment: !Self.catalog(structure).attachments.isEmpty' in service_source
assert 'inlineImages: Self.catalog(structure).inlineImages' in service_source
assert '(catalog.attachments + catalog.inlineImages).contains' in service_source
assert 'MailPartMetadata.hasOriginalFilename(part.filename, cidFallback: cidFallback)' in service_source
assert 'MessagePart(section: part.section, contentType: part.contentType).suggestedFilename' in service_source
assert 'offset: 0, count: limit + 1' in service_source
# Compile the exact production email builders into the offline service fixture.
email_builders = service_source[service_source.index("    static func outgoingEmail("):
                                service_source.index("    static func plainTextHTML(")]
assert service_source.index("try await smtp.sendEmail(email)") < service_source.index("Self.sentCopy(of: email")
assert "server.append(email: sentEmail" in service_source
assert "count: encodedLimit + 1" in service_source
assert "MailTransferPolicy.responseBufferLimit" in service_source
assert "UInt64(MailTransferPolicy.attachmentEncodedLimit + 1)" in service_source
checks = r'''
import Foundation
import Combine
import SwiftSoup
import WebKit

@MainActor enum StorageKeys { static let authSessionID = "synthetic-mail-session" }
@MainActor struct LoginRepository {
    static let shared = Self()
    func getSavedCredentials() -> (username: String, password: String)? { fatalError("Real credentials forbidden") }
}
// Default dependency is deliberately unusable. Every model below receives a controlled fixture.
nonisolated struct NativeMailService: NativeMailServing {
    func inbox(credentials: MailCredentials, folder: String, limit: Int) async throws -> MailInboxSnapshot { fatalError() }
    func message(credentials: MailCredentials, key: MailMessageKey) async throws -> MailMessageContent { fatalError() }
    func attachment(credentials: MailCredentials, key: MailMessageKey, part: String, maximumBytes: Int) async throws -> Data { fatalError() }
    func setSeen(credentials: MailCredentials, key: MailMessageKey, seen: Bool) async throws { fatalError() }
    func setFlagged(credentials: MailCredentials, key: MailMessageKey, flagged: Bool) async throws { fatalError() }
    func moveToTrash(credentials: MailCredentials, key: MailMessageKey, allowMarkDeleted: Bool) async throws { fatalError() }
    func send(credentials: MailCredentials, draft: MailDraft) async throws -> MailSendOutcome { fatalError() }
}
actor Fixture: NativeMailServing {
    var inboxWaiters: [String: CheckedContinuation<MailInboxSnapshot, Error>] = [:]
    var detailWaiters: [UInt32: CheckedContinuation<MailMessageContent, Error>] = [:]
    var sendWaiter: CheckedContinuation<MailSendOutcome, Error>?
    var delayMutations = false
    var mutationWaiters: [String: CheckedContinuation<Void, Error>] = [:]
    var delayAttachments = false
    var attachmentWaiters: [String: CheckedContinuation<Data, Error>] = [:]
    var attachmentCalls: [String: Int] = [:]
    var attachmentLimits: [String: Int] = [:]
    var maximumActiveAttachments = 0
    func setDelayedAttachments(_ value: Bool) { delayAttachments = value }
    func finishAttachment(_ uid: UInt32, _ part: String, data: Data) {
        guard let waiter = attachmentWaiters.removeValue(forKey: "\(uid):\(part)") else { fatalError("missing attachment") }
        waiter.resume(returning: data) // Deliberately ignores cancellation, like a late network response.
    }
    var seenCalls = 0
    var trashCalls = 0
    func setDelayedMutations(_ value: Bool) { delayMutations = value }
    func operation(_ key: String) async throws {
        if delayMutations { try await withCheckedThrowingContinuation { mutationWaiters[key] = $0 } }
    }
    func setSeen(credentials: MailCredentials, key: MailMessageKey, seen: Bool) async throws {
        seenCalls += 1
        try await operation("seen")
    }
    func setFlagged(credentials: MailCredentials, key: MailMessageKey, flagged: Bool) async throws { try await operation("flag") }
    func moveToTrash(credentials: MailCredentials, key: MailMessageKey, allowMarkDeleted: Bool) async throws {
        trashCalls += 1
        try await operation("trash")
    }
    func finishMutation(_ key: String, error: NativeMailError? = nil) {
        guard let waiter = mutationWaiters.removeValue(forKey: key) else { fatalError("missing operation") }
        if let error { waiter.resume(throwing: error) } else { waiter.resume() }
    }
    var inboxCalls = 0
    var sendCalls = 0
    var usernames: [String] = []
    func inbox(credentials: MailCredentials, folder: String, limit: Int) async throws -> MailInboxSnapshot {
        inboxCalls += 1; usernames.append(credentials.username)
        return try await withCheckedThrowingContinuation { inboxWaiters[credentials.username + ":" + folder] = $0 }
    }
    func message(credentials: MailCredentials, key: MailMessageKey) async throws -> MailMessageContent {
        try await withCheckedThrowingContinuation { detailWaiters[key.uid] = $0 }
    }
    func attachment(credentials: MailCredentials, key: MailMessageKey, part: String, maximumBytes: Int) async throws -> Data {
        let id = "\(key.uid):\(part)"
        attachmentCalls[id, default: 0] += 1; attachmentLimits[id] = maximumBytes
        if delayAttachments {
            return try await withCheckedThrowingContinuation {
                attachmentWaiters[id] = $0
                maximumActiveAttachments = max(maximumActiveAttachments, attachmentWaiters.count)
            }
        }
        return Data("fixture".utf8)
    }
    func send(credentials: MailCredentials, draft: MailDraft) async throws -> MailSendOutcome {
        sendCalls += 1
        return try await withCheckedThrowingContinuation { sendWaiter = $0 }
    }
    func finishInbox(_ name: String, _ folder: String = "INBOX", uid: UInt32 = 1, fail: Bool = false,
                     folders: [MailFolder]? = nil) {
        let waiter = inboxWaiters.removeValue(forKey: name + ":" + folder)!
        if fail { waiter.resume(throwing: NativeMailError.connection); return }
        waiter.resume(returning: MailInboxSnapshot(folders: folders ?? [MailFolder(id: folder, name: folder)],
            messages: [summary(uid, folder: folder)], total: 1))
    }
    func finishDetail(_ uid: UInt32, text: String, fail: Bool = false, images: [MailAttachmentInfo] = [], html: String? = nil) {
        guard let waiter = detailWaiters.removeValue(forKey: uid) else { fatalError("missing detail") }
        if fail { waiter.resume(throwing: NativeMailError.connection); return }
        waiter.resume(returning:
            MailMessageContent(text: text, simplifiedHTML: false, replyAddress: "fixture@example.com", messageID: nil, attachments: images.filter(\.hasFilename), html: html, inlineImages: images))
    }
    func finishSend(_ error: NativeMailError? = nil, copy: Bool = true) {
        let waiter = sendWaiter!; sendWaiter = nil
        if let error { waiter.resume(throwing: error) } else { waiter.resume(returning: .accepted(copySaved: copy)) }
    }
}
func summary(_ uid: UInt32, folder: String = "INBOX") -> MailSummary {
    MailSummary(id: MailMessageKey(folder: folder, validity: 77, uid: uid), subject: "合成信件", sender: "fixture@example.com", date: nil, unread: true)
}
@MainActor func settle(_ condition: @escaping @MainActor () async -> Bool) async throws {
    for _ in 0..<500 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    fatalError("Fixture did not reach expected state")
}
@main struct Checks {
    @MainActor static func main() async throws {
        let cidImage = MailAttachmentInfo(id: "2.1", name: "cid.png", size: 128, mime: "image/png", contentID: "<photo@example.com>")
        let dirty = """
        <html><head><base href="https://evil.example/"><meta http-equiv="refresh" content="0;url=https://evil.example">
        <link rel="stylesheet" href="https://evil.example/style.css"><link rel="prefetch" href="https://evil.example/">
        <style>table{color:white;background:#112233}td{background-image:url('https://example.com/bg.png')}</style></head>
        <body onload="alert(1)"><script>alert(1)</script><iframe src="https://evil.example/"></iframe>
        <form><input><button>send</button></form><object></object><embed><textarea>x</textarea><select></select>
        <a href="java&#x0A;script:alert(1)" onclick="bad()">bad</a><img src="data:text/html,bad" onerror="bad()">
        <a href="vbscript:bad">bad</a><a href="https://example.com/">good</a>
        <table bgcolor="#112233"><tr><td style="background-image:url(cid:photo%40example.com)">
        <img src="cid:photo@example.com"><img src="https://example.com/pixel.png"></td></tr></table></body></html>
        """
        let cleaned = try await MailHTMLPolicy.prepare(dirty, images: [cidImage])
        let parsed = try SwiftSoup.parse(cleaned.markup)
        let forbidden = try parsed.select("script,iframe,frame,object,embed,form,input,button,textarea,select,meta,base,link")
        precondition(forbidden.isEmpty())
        for node in try parsed.select("*").array() {
            for attribute in node.getAttributes()?.asList() ?? [] {
                precondition(!attribute.getKey().lowercased().hasPrefix("on"))
                precondition(!attribute.getValue().contains("javascript:") && !attribute.getValue().contains("vbscript:") && !attribute.getValue().contains("data:text/html"))
            }
        }
        precondition(cleaned.markup.contains("niu-mail-cid://part/2.1") && cleaned.referencedParts == ["2.1"])
        precondition(cleaned.hasExternalImages && cleaned.hasOwnColors && cleaned.markup.contains("<style>"))
        for sample in ["<img src='http://example.com/x'>", "<body background='https://example.com/x'>x</body>",
                       "<p style=\"background:url(https://example.com/x)\">x</p>", "<style>p{background:url(//example.com/x)}</style>"] {
            let sampleDocument = try MailHTMLPolicy.sanitize(sample, images: [])
            precondition(sampleDocument.hasExternalImages)
        }
        let local = try MailHTMLPolicy.sanitize("<p>Hello</p><img src='cid:photo@example.com'>", images: [cidImage])
        precondition(!local.hasExternalImages && !local.hasOwnColors)
        let markup = cleaned.rendered(externalImages: false)
        let safe = try SwiftSoup.parse(markup)
        let policy = try safe.select("meta[http-equiv=Content-Security-Policy]").first()!.attr("content")
        precondition(policy == MailHTMLPolicy.csp(externalImages: false))
        precondition(policy.contains("default-src 'none'") && policy.contains("img-src cid: niu-mail-cid: data:") &&
                     policy.contains("style-src 'unsafe-inline'") && policy.contains("font-src data:") && !policy.contains("https:"))
        precondition(markup.contains("-webkit-text-size-adjust:100%"))
        precondition(!markup.contains("overflow-wrap:anywhere"))
        precondition(!markup.contains("overflow-x:auto!important") && !markup.contains("overflow-x:hidden"))
        precondition(markup.contains("img{max-width:100%;height:auto}") && !markup.contains("table{max-width:100%}"))
        let wideMail = try MailHTMLPolicy.sanitize("<table width='640'><tr><td>Newsletter</td></tr></table>", images: [])
        let wideBody = try SwiftSoup.parse(wideMail.markup).body()!
        precondition(wideBody.children().first()?.tagName() == "table", "No nested scrolling container")
        let wideTable = try wideBody.select("table").first()!
        let wideTableWidth = try wideTable.attr("width")
        precondition(wideTableWidth == "640", "Keep the natural newsletter width")
        let fitted = MailHTMLPolicy.fittingScale(contentWidth: 700, viewportWidth: 402)
        precondition(abs(fitted - 402.0 / 700) < 0.000001)
        precondition(abs(26 * fitted - 14.9314285714) < 0.000001, "Scale fonts with the whole page")
        precondition(MailHTMLPolicy.fittingScale(contentWidth: 400, viewportWidth: 402) == 1)
        precondition(MailHTMLPolicy.fittingScale(contentWidth: 2000, viewportWidth: 402) == 0.201)
        precondition(MailHTMLPolicy.fittingScale(contentWidth: 700, viewportWidth: 320) == 320.0 / 700)
        precondition(MailHTMLPolicy.fittingScale(contentWidth: 900, viewportWidth: 402) < fitted,
                     "Late wide image must fit without horizontal scrolling")
        for invalid in [0.0, -1, Double.nan, Double.infinity] {
            precondition(MailHTMLPolicy.fittingScale(contentWidth: invalid, viewportWidth: 402) == 1)
            precondition(MailHTMLPolicy.fittingScale(contentWidth: 700, viewportWidth: invalid) == 1)
        }
        print("PASS: native fit 700/402, proportional fonts, narrow mail, very wide mail, rotation and late images")
        let fixedFont = try MailHTMLPolicy.sanitize("<style>td{font-size:14px}</style><table><tr><td style='font-size:14px'>Large text</td></tr></table>", images: [])
        let fixedMarkup = fixedFont.rendered(externalImages: false)
        precondition(fixedMarkup.contains("-webkit-text-size-adjust:100%"))
        precondition(!fixedMarkup.contains("200.0%") && !fixedMarkup.contains("141."))
        precondition(fixedMarkup.contains("font-size:14px"), "Preserve the sender's fixed font sizes")
        precondition(markup.contains("color-scheme:only light") && local.rendered(externalImages: false).contains("color-scheme:light dark"))
        // Use an isolated store so compilation never reads/writes the app's rule-list cache.
        let ruleStoreURL = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("ContentRuleLists")
        try FileManager.default.createDirectory(at: ruleStoreURL, withIntermediateDirectories: true)
        let ruleStore = WKContentRuleListStore(url: ruleStoreURL)!
        for remote in [false, true] {
            let rendered = try SwiftSoup.parse(cleaned.rendered(externalImages: remote))
            let csp = try rendered.select("meta[http-equiv=Content-Security-Policy]").first()!.attr("content")
            let directives = csp.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            let imageSources = directives.first { $0.hasPrefix("img-src ") }!.split(separator: " ").dropFirst()
            precondition(imageSources == (remote ? ["cid:", "niu-mail-cid:", "data:", "https:"] : ["cid:", "niu-mail-cid:", "data:"]))
            let encodedRules = MailHTMLPolicy.rules(externalImages: remote)
            let rules = try JSONSerialization.jsonObject(with: Data(encodedRules.utf8)) as! [[String: Any]]
            for rule in rules {
                let trigger = rule["trigger"] as! [String: Any]
                let filter = trigger["url-filter"] as! String
                precondition(!filter.contains("|"), "WebKit url-filter does not support alternation")
                precondition(!filter.dropFirst().contains("^"), "WebKit permits ^ only at the start")
                precondition(!filter.dropLast().contains("$"), "WebKit permits $ only at the end")
            }
            precondition((rules[0]["action"] as! [String: String])["type"] == "block")
            if remote { precondition((rules.last!["trigger"] as! [String: Any])["resource-type"] as! [String] == ["image"]) }
            // Apply the ordered content-rule actions independently of CSP.
            func blocked(_ url: String, resource: String) throws -> Bool {
                var result = false
                for rule in rules {
                    let trigger = rule["trigger"] as! [String: Any]
                    if let types = trigger["resource-type"] as? [String], !types.contains(resource) { continue }
                    let filter = try NSRegularExpression(pattern: trigger["url-filter"] as! String, options: .caseInsensitive)
                    guard filter.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil else { continue }
                    let action = (rule["action"] as! [String: String])["type"]!
                    precondition(["block", "ignore-previous-rules"].contains(action))
                    result = action == "block"
                }
                return result
            }
            let blankBlocked = try blocked("about:blank", resource: "document")
            precondition(!blankBlocked, "loadHTMLString's initial document must be allowed")
            for url in ["about:blank/extra", "about:blank?extra", "about:srcdoc", "data:text/html,hello", "cid:part", "niu-mail-cid://part/1"] {
                let documentBlocked = try blocked(url, resource: "document")
                precondition(documentBlocked, "The document exception must match only about:blank")
            }
            for scheme in ["cid:", "niu-mail-cid:", "data:"] {
                for resource in ["image", "font", "script", "style-sheet", "raw"] {
                    let resourceBlocked = try blocked(scheme + "part", resource: resource)
                    precondition(resourceBlocked == !["image", "font"].contains(resource), "Local scheme exceptions allow only images/fonts")
                }
            }
            for scheme in ["http", "https"] {
                let url = "\(scheme)://example.com/pixel.png"
                let imageBlocked = try blocked(url, resource: "image")
                precondition(imageBlocked == !(remote && scheme == "https"), "Only HTTPS images are allowed after consent")
                for resource in ["script", "style-sheet", "document", "font", "raw"] {
                    let resourceBlocked = try blocked(url, resource: resource)
                    precondition(resourceBlocked, "Consent must not allow other remote resource types")
                }
            }
            let compiled = try await ruleStore.compileContentRuleList(forIdentifier: "fixture-\(remote)-v2", encodedContentRuleList: encodedRules)
            precondition(compiled != nil, "WebKit must compile the actual production rules")
            print("PASS: content-rule JSON, restricted regex, resource policy and macOS WebKit compilation (externalImages=\(remote))")
        }
        print("PASS: rendered CSP and content rules block HTTP images before/after consent; HTTPS images allowed only after consent")
        for scheme in ["https", "http"] {
            let url = URL(string: "\(scheme)://example.com/")!
            precondition(MailHTMLPolicy.navigation(url, userActivated: true, initialLoad: false, mainFrame: true) == .external(url))
            precondition(MailHTMLPolicy.navigation(url, userActivated: false, initialLoad: true, mainFrame: true) == .cancel)
        }
        precondition(MailHTMLPolicy.navigation(URL(string: "mailto:peer@example.com?subject=Hello%20NIU"), userActivated: true, initialLoad: false, mainFrame: false) == .compose(to: "peer@example.com", subject: "Hello NIU"))
        for url in ["javascript:bad", "data:text/html,bad", "file:///private/x", "niu-mail-cid://part/2.1", "tel:123"] {
            precondition(MailHTMLPolicy.navigation(URL(string: url), userActivated: true, initialLoad: false, mainFrame: true) == .cancel)
        }
        precondition(MailHTMLPolicy.navigation(URL(string: "about:blank"), userActivated: false, initialLoad: true, mainFrame: true) == .initial)
        precondition(MailHTMLPolicy.navigation(URL(string: "about:blank"), userActivated: false, initialLoad: false, mainFrame: true) == .cancel)
        print("PASS: SwiftSoup HTML sanitization, CID rewriting, external image detection, CSP/block rules, color policy and navigation decisions")
        var session = "A"
        var user = "student-a"
        let fixture = Fixture()
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("files")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let orphan = root.appendingPathComponent("previous-session")
        try Data("old synthetic data".utf8).write(to: orphan)
        let fileStore = MailLocalFiles(root: root)
        await fileStore.prepare()
        precondition(!FileManager.default.fileExists(atPath: orphan.path), "clean artifacts from previous process")
        let model = NativeMailViewModel(service: fixture, fileStore: fileStore, session: { session }, credentials: { (user, "synthetic-password") })
        model.prepare(account: user)
        try await settle { await fixture.inboxCalls == 1 }
        session = "B"; user = "student-b"; model.prepare(account: user)
        try await settle { await fixture.inboxCalls == 2 }
        await fixture.finishInbox("student-b", uid: 2)
        try await settle { !model.isLoading }
        await fixture.finishInbox("student-a", uid: 1)
        await Task.yield()
        precondition(model.messages.first?.id.uid == 2 && model.account == "student-b", "stale account response")
        let names = await fixture.usernames
        precondition(names == ["student-a", "student-b"], "use matching saved username")

        model.reload()
        try await settle { await fixture.inboxCalls == 3 }
        await fixture.finishInbox("student-b", fail: true)
        try await settle { !model.isLoading }
        precondition(model.messages.first?.id.uid == 2 && model.errorMessage != nil, "refresh keeps valid cache")

        model.reload()
        try await settle { await fixture.inboxCalls == 4 }
        model.chooseFolder("Sent")
        try await settle { await fixture.inboxCalls == 5 }
        await fixture.finishInbox("student-b", "Sent", uid: 8)
        try await settle { !model.isLoading }
        await fixture.finishInbox("student-b", uid: 3)
        await Task.yield()
        precondition(model.folder == "Sent" && model.messages.first?.id.uid == 8, "stale folder response")

        model.read(summary(10))
        try await settle { await fixture.detailWaiters[10] != nil }
        model.read(summary(11))
        try await settle { await fixture.detailWaiters[11] != nil }
        await fixture.finishDetail(11, text: "new")
        try await settle { !model.isReading }
        await fixture.finishDetail(10, text: "old")
        await Task.yield()
        precondition(model.content?.text == "new", "stale detail response")

        model.download(MailAttachmentInfo(id: "2", name: "../../sample.txt", size: 7), message: summary(11))
        try await settle { !model.isDownloading }
        let downloaded = model.sharedFile!
        precondition(downloaded.lastPathComponent == "sample.txt")
        precondition(FileManager.default.fileExists(atPath: downloaded.path))

        // MIME policy uses the same metadata classifier as the production service.
        func part(_ id: String, mime: String = "image/png", disposition: String? = nil,
                  cid: String? = nil, named: Bool = false, attached: Bool = false) -> MailPartMetadata {
            MailPartMetadata(info: MailAttachmentInfo(id: id, name: "image.png", size: 1024,
                mime: mime, contentID: cid, hasFilename: named), disposition: disposition, isAttachment: attached)
        }
        precondition(!MailPartMetadata.hasOriginalFilename("photo@example.com", cidFallback: "photo@example.com"),
                     "SwiftMail's CID-derived filename is not an explicit attachment name")
        precondition(MailPartMetadata.hasOriginalFilename("photo.png", cidFallback: "photo@example.com"))
        precondition(!MailPartMetadata.hasOriginalFilename(nil, cidFallback: nil))
        let cidFilename = " \t<PHOTO@Example.com>\n"
        let contentID = "<photo@example.com>"
        let cidNamed = MailPartMetadata.hasOriginalFilename(cidFilename, cidFallback: contentID)
        precondition(!cidNamed, "CID-derived filename ignores surrounding whitespace, angle brackets and case")
        let cidCatalog = MailPartCatalog([
            part("cid-filename", disposition: "inline", cid: contentID, named: cidNamed)
        ])
        precondition(cidCatalog.inlineImages.map(\.id) == ["cid-filename"] && cidCatalog.attachments.isEmpty,
                     "CID-derived filename belongs only in inline images, not attachments")
        let catalog = MailPartCatalog([
            part("1", mime: "text/plain"), part("2", disposition: "INLINE", named: true),
            part("3", cid: "<cid>"), part("3a", cid: "named-cid", named: true), part("4", mime: "application/pdf", disposition: "inline", cid: "pdf", named: true),
            part("5", mime: "message/rfc822", attached: true),
            part("5.1", disposition: "inline", named: true), part("5.2", cid: "nested"),
            part("6", mime: "image/jpeg", attached: true), part("50", disposition: "inline"),
            part("2", disposition: "inline", named: true)
        ])
        precondition(catalog.inlineImages.map(\.id) == ["2", "3", "3a", "50"], "own inline/CID images, no nested or duplicate parts")
        precondition(catalog.attachments.map(\.id) == ["2", "3a", "4", "5", "6"], "named inline images and non-images join attachments")
        let pngService = NativeMailUIFixtureService()
        let pngCredentials = MailCredentials(username: "test@niu.edu.tw", password: "synthetic")
        let pngKey = MailMessageKey(folder: "INBOX", validity: 1, uid: 19)
        let pngContent = try await pngService.message(credentials: pngCredentials, key: pngKey)
        precondition(pngContent.inlineImages.count == 2 && pngContent.attachments.count == 1)
        precondition(pngContent.inlineImages[1].contentID != nil && !pngContent.inlineImages[1].hasFilename)
        let png = try await pngService.attachment(credentials: pngCredentials, key: pngKey, part: "photo")
        precondition(png.starts(with: [137, 80, 78, 71]), "fixture generates a real PNG")
        // Real locked SwiftMail MIME writer, for both SMTP encoding modes.
        var bccDraft = MailDraft()
        bccDraft.to = "visible@example.com"; bccDraft.cc = "carbon@example.com"
        bccDraft.bcc = "first@example.com； second@example.com,third@example.com"
        bccDraft.subject = "BCC regression"; bccDraft.body = "Synthetic body"
        bccDraft.inReplyTo = "<parent@example.com>"
        bccDraft.references = ["<ancestor@example.com>", "<parent@example.com>"]
        for onlyBCC in [false, true] {
            if onlyBCC { bccDraft.to = ""; bccDraft.cc = "" }
            try bccDraft.validate()
            let smtpEmail = try NativeMailService.outgoingEmail(credentials: pngCredentials, draft: bccDraft)
            let sentEmail = try NativeMailService.sentCopy(of: smtpEmail, bcc: bccDraft.bcc)
            precondition(smtpEmail.bccRecipients.map(\.address) == ["first@example.com", "second@example.com", "third@example.com"])
            precondition(sentEmail.messageID == smtpEmail.messageID)
            for use8Bit in [false, true] {
                let smtp = smtpEmail.constructContent(use8BitMIME: use8Bit)
                let backup = sentEmail.constructContent(use8BitMIME: use8Bit)
                let smtpHeaders = smtp.components(separatedBy: "\r\n\r\n")[0]
                let backupHeaders = backup.components(separatedBy: "\r\n\r\n")[0]
                precondition(!smtpHeaders.lowercased().contains("\r\nbcc:"))
                for address in smtpEmail.bccRecipients { precondition(!smtp.contains(address.address)) }
                precondition(backupHeaders.contains("\r\nBcc: first@example.com, second@example.com, third@example.com\r\n"))
                precondition(backupHeaders.contains("In-Reply-To: <parent@example.com>"))
                precondition(backupHeaders.contains("References: <ancestor@example.com> <parent@example.com>"))
                precondition(backupHeaders.contains("Message-Id: \(bccDraft.messageID)"))
                precondition(smtpEmail.additionalHeaders?["Bcc"] == nil, "backup must not mutate SMTP value")
            }
        }
        for injected in ["safe@example.com\r\nBcc: attacker@example.com", "safe@example.com\n", "safe@example.com\r", "safe@example.com\u{0}"] {
            let email = try NativeMailService.outgoingEmail(credentials: pngCredentials, draft: bccDraft)
            do { _ = try NativeMailService.sentCopy(of: email, bcc: injected); fatalError("Bcc header injection accepted") }
            catch NativeMailError.invalidRecipient {}
        }
        bccDraft.bcc = ""; bccDraft.to = "visible@example.com"
        let noBCC = try NativeMailService.outgoingEmail(credentials: pngCredentials, draft: bccDraft)
        let noBCCBackup = try NativeMailService.sentCopy(of: noBCC, bcc: "")
        precondition(noBCCBackup.additionalHeaders?["Bcc"] == nil)
        print("PASS: locked SwiftMail constructContent preserves full sent-copy Bcc (including Bcc-only), SMTP omits Bcc, header injection rejected")

        let mb = 1024 * 1024
        // A real 1x1 PNG: 70 decoded bytes, 94 Base64 bytes without padding.
        let unpaddedPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg"
        precondition(unpaddedPNG.utf8.count == 94 && !unpaddedPNG.contains("="))
        // Restore transport padding for Foundation's strict Base64 decoder.
        let decodedPNG = Data(base64Encoded: unpaddedPNG + "==")!
        precondition(decodedPNG.count == 70 && decodedPNG.starts(with: [137, 80, 78, 71]))
        let unpaddedImage = MailAttachmentInfo(id: "unpadded", name: "pixel.png", size: unpaddedPNG.utf8.count,
                                              mime: "image/png", encoding: "base64")
        precondition(MailInlinePolicy.automaticIDs([unpaddedImage]) == ["unpadded"])
        let unpaddedBudget = MailInlinePolicy.automaticLimits([unpaddedImage])["unpadded"]!
        precondition(unpaddedBudget >= decodedPNG.count)
        try MailTransferPolicy.validateEncodedSize(unpaddedPNG.utf8.count, maximumDecodedBytes: unpaddedBudget)
        try MailTransferPolicy.validateDecodedSize(decodedPNG.count, maximumBytes: unpaddedBudget)
        print("PASS: unpadded 94-byte Base64 PNG reserves enough automatic budget for 70 decoded bytes")
        func encodedPayload(_ bytes: Int, columns: Data.Base64EncodingOptions = .lineLength76Characters) -> Data {
            Data(repeating: 0xa5, count: bytes).base64EncodedData(options: [columns, .endLineWithCarriageReturn, .endLineWithLineFeed])
        }
        for columns in [Data.Base64EncodingOptions.lineLength64Characters, .lineLength76Characters] {
            for size in [12 * mb, MailDraft.attachmentLimit] {
                let encoded = encodedPayload(size, columns: columns)
                precondition(encoded.count > MailDraft.attachmentLimit)
                try MailTransferPolicy.validateEncodedSize(encoded.count, maximumDecodedBytes: MailDraft.attachmentLimit)
                let decoded = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)!
                precondition(decoded.count == size)
                try MailTransferPolicy.validateDecodedSize(decoded.count, maximumBytes: MailDraft.attachmentLimit)
            }
            let boundaryImages = [
                MailAttachmentInfo(id: "ten", name: "ten.png", size: encodedPayload(10 * mb, columns: columns).count, encoding: "base64"),
                MailAttachmentInfo(id: "five", name: "five.png", size: encodedPayload(5 * mb, columns: columns).count, encoding: "base64")
            ]
            precondition(MailInlinePolicy.automaticLimits(boundaryImages) == ["ten": 10 * mb, "five": 5 * mb])
        }
        let excess = encodedPayload(MailDraft.attachmentLimit + 1)
        try MailTransferPolicy.validateEncodedSize(excess.count, maximumDecodedBytes: MailDraft.attachmentLimit)
        do {
            try MailTransferPolicy.validateDecodedSize(Data(base64Encoded: excess, options: .ignoreUnknownCharacters)!.count,
                                                       maximumBytes: MailDraft.attachmentLimit)
            fatalError("oversized decoded attachment accepted")
        } catch NativeMailError.tooLarge {}
        do { try MailTransferPolicy.validateEncodedSize(MailTransferPolicy.attachmentEncodedLimit + 1, maximumDecodedBytes: MailDraft.attachmentLimit); fatalError("encoded overflow accepted") }
        catch NativeMailError.tooLarge {}
        do { _ = try MailTransferPolicy.encodedLimit(for: -1); fatalError("negative budget") }
        catch NativeMailError.tooLarge {}
        precondition(MailTransferPolicy.attachmentEncodedLimit + 1 < MailTransferPolicy.responseBufferLimit)
        let encodedImages = [
            MailAttachmentInfo(id: "ten", name: "ten.png", size: encodedPayload(10 * mb).count, encoding: "base64"),
            MailAttachmentInfo(id: "five", name: "five.png", size: encodedPayload(5 * mb).count, encoding: "BASE64"),
            MailAttachmentInfo(id: "over", name: "over.png", size: encodedPayload(mb).count, encoding: "base64")
        ]
        let inlineLimits = MailInlinePolicy.automaticLimits(encodedImages)
        precondition(inlineLimits == ["ten": 10 * mb, "five": 5 * mb], "inline decoded single/total budgets include MIME wrapping")
        precondition(inlineLimits.values.reduce(0, +) == MailInlinePolicy.messageLimit)
        print("PASS: 12 MiB and 15 MiB decoded Base64 (64/76 columns) accepted; >15 MiB decoded and encoded overflow rejected; inline 10/15 MiB budgets enforced")
        let forwardFixture = Fixture()
        await forwardFixture.setDelayedAttachments(true)
        let forwardModel = NativeMailViewModel(service: forwardFixture, fileStore: fileStore,
            session: { "forward-test" }, credentials: { ("forward-test", "synthetic") })
        forwardModel.prepare(account: "forward-test")
        try await settle { await forwardFixture.inboxWaiters["forward-test:INBOX"] != nil }
        await forwardFixture.finishInbox("forward-test")
        try await settle { !forwardModel.isLoading }
        forwardModel.compose(.forward, summary: summary(77))
        try await settle { await forwardFixture.detailWaiters[77] != nil }
        let forwarded = [MailAttachmentInfo(id: "large", name: "large.bin", size: encodedPayload(12 * mb).count, encoding: "base64")]
        await forwardFixture.finishDetail(77, text: "forward", images: forwarded)
        try await settle { !forwardModel.isPreparingDraft }
        forwardModel.draft.attachments = [MailOutgoingAttachment(name: "existing.bin", mime: "application/octet-stream", data: Data(count: 3 * mb))]
        forwardModel.includeForwardAttachments()
        try await settle { await forwardFixture.attachmentWaiters["77:large"] != nil }
        let forwardLimit = await forwardFixture.attachmentLimits["77:large"]
        precondition(forwardLimit == 12 * mb, "forward passes remaining decoded budget, not BODYSTRUCTURE octets")
        await forwardFixture.finishAttachment(77, "large", data: Data(count: 12 * mb))
        try await settle { !forwardModel.isImporting }
        precondition(forwardModel.draft.attachments.map { $0.data.count } == [3 * mb, 12 * mb])
        precondition(forwardModel.forwardAttachments.isEmpty && forwardModel.sendMessage == nil)
        forwardModel.discardDraft()
        forwardModel.compose(.forward, summary: summary(78))
        try await settle { await forwardFixture.detailWaiters[78] != nil }
        await forwardFixture.finishDetail(78, text: "oversize", images: forwarded)
        try await settle { !forwardModel.isPreparingDraft }
        forwardModel.includeForwardAttachments()
        try await settle { await forwardFixture.attachmentWaiters["78:large"] != nil }
        await forwardFixture.finishAttachment(78, "large", data: Data(count: MailDraft.attachmentLimit + 1))
        try await settle { !forwardModel.isImporting }
        precondition(forwardModel.draft.attachments.isEmpty && forwardModel.sendMessage == NativeMailError.tooLarge.errorDescription)
        forwardModel.reset()
        print("PASS: forwarding accepts encoded 16+ MiB / decoded 12 MiB with 3 MiB existing draft; actual decoded overflow rejected")
        let images = [
            MailAttachmentInfo(id: "a", name: "a.png", size: 6 * mb, mime: "image/png"),
            MailAttachmentInfo(id: "b", name: "b.png", size: 6 * mb, mime: "image/png"),
            MailAttachmentInfo(id: "c", name: "c.png", size: 2 * mb, mime: "image/png"),
            MailAttachmentInfo(id: "budget", name: "budget.png", size: 2 * mb, mime: "image/png"),
            MailAttachmentInfo(id: "large", name: "large.png", size: 11 * mb, mime: "image/png"),
            MailAttachmentInfo(id: "unknown", name: "unknown.png", size: nil, mime: "image/png")
        ]
        precondition(MailInlinePolicy.automaticIDs(images) == Set(["a", "b", "c"]))
        precondition(MailInlinePolicy.automaticIDs([
            MailAttachmentInfo(id: "boundary", name: "x", size: 10 * mb),
            MailAttachmentInfo(id: "remaining", name: "y", size: 5 * mb)
        ]).count == 2, "inclusive 10 MB / 15 MB boundaries")
        await fixture.setDelayedAttachments(true)
        model.read(summary(12))
        try await settle { await fixture.detailWaiters[12] != nil }
        await fixture.finishDetail(12, text: "inline", images: images)
        try await settle { await fixture.attachmentWaiters.count == 2 }
        precondition(model.content?.inlineImages.count == 6 && model.inlineStatus["budget"] == "圖片過大，點擊下載")
        let oversizedCalls = await fixture.attachmentCalls["12:large"]
        let budgetCalls = await fixture.attachmentCalls["12:budget"]
        precondition(oversizedCalls == nil && budgetCalls == nil, "oversize never auto downloads")
        model.download(images[0], message: summary(12)) // joins the thumbnail's in-flight request
        await fixture.finishAttachment(12, "a", data: png)
        try await settle { model.inlineThumbnails["a"] != nil && model.sharedFile != nil }
        let inlineURL = model.downloadedFiles["a"]!
        let image = model.inlineThumbnails["a"]!
        precondition(max(image.width, image.height) <= 1600 && model.sharedFile == inlineURL)
        model.download(images[0], message: summary(12))
        let joinedCalls = await fixture.attachmentCalls["12:a"]
        precondition(joinedCalls == 1, "thumbnail and attachment reuse exactly one download")
        try await settle { await fixture.attachmentWaiters["12:c"] != nil }
        let peak = await fixture.maximumActiveAttachments
        precondition(peak == 2, "at most two simultaneous automatic downloads")
        let oldCID = Task { try await model.cidData(part: "b", message: summary(12).id) }
        await Task.yield()
        // Switching messages releases decoded images and discards late replies for the same part IDs.
        model.read(summary(13))
        precondition(model.inlineThumbnails.isEmpty && model.downloadedFiles.isEmpty)
        try await settle { await fixture.detailWaiters[13] != nil }
        await fixture.finishDetail(13, text: "next", images: [images[0]])
        try await settle { await fixture.attachmentWaiters["13:a"] != nil }
        await fixture.finishAttachment(12, "b", data: png)
        await fixture.finishAttachment(12, "c", data: png)
        do { _ = try await oldCID.value; fatalError("stale CID delivered") } catch is CancellationError {}
        print("PASS: switching messages discards pending CID scheme data")
        await fixture.finishAttachment(13, "a", data: Data("unsupported image".utf8))
        try await settle { model.activeDownloads.isEmpty }
        precondition(model.inlineThumbnails.isEmpty && Set(model.downloadedFiles.keys) == Set(["a"]))
        precondition(model.inlineStatus["a"] == "此格式無法顯示縮圖，點擊預覽檔案")
        model.read(summary(14))
        try await settle { await fixture.detailWaiters[14] != nil }
        await fixture.finishDetail(14, text: "logout race", images: [images[0]])
        try await settle { await fixture.attachmentWaiters["14:a"] != nil }
        // Closing also cancels pending responses, retaining files only until the existing logout cleanup.
        model.closeMessage()
        await fixture.finishAttachment(14, "a", data: png)
        await fixture.setDelayedAttachments(false)
        precondition(model.inlineThumbnails.isEmpty && model.activeDownloads.isEmpty)
        precondition(FileManager.default.fileExists(atPath: inlineURL.path))
        // Referenced CID with unknown size has an explicit, shared-queue download path.
        let unknownCID = MailAttachmentInfo(id: "manual", name: "manual.png", size: nil,
            mime: "image/png", contentID: "manual@example.com", hasFilename: false)
        await fixture.setDelayedAttachments(true)
        model.read(summary(16))
        try await settle { await fixture.detailWaiters[16] != nil }
        await fixture.finishDetail(16, text: "manual CID", images: [unknownCID], html: "<img src='cid:manual@example.com'>")
        try await settle { !model.isReading }
        precondition(model.htmlDocument?.referencedParts == ["manual"] && model.activeDownloads.isEmpty)
        do { _ = try await model.cidData(part: "manual", message: summary(16).id); fatalError("unknown size auto fetch") }
        catch NativeMailError.tooLarge {}
        model.downloadHTMLImage(unknownCID, message: summary(16))
        try await settle { await fixture.attachmentWaiters["16:manual"] != nil }
        let manualPayload = png + Data(count: 11 * mb)
        await fixture.finishAttachment(16, "manual", data: manualPayload)
        try await settle { model.htmlImageRevision == 1 && model.activeDownloads.isEmpty }
        let manualCID = try await model.cidData(part: "manual", message: summary(16).id)
        precondition(manualCID == manualPayload && manualCID.count > MailInlinePolicy.imageLimit && model.sharedFile == nil, "CID manual download reloads HTML without QuickLook")
        model.closeMessage()
        await fixture.setDelayedAttachments(false)
        print("PASS: referenced CID manual download, shared cache, HTML reload and fixed HTML text-size CSS")
        print("PASS: inline MIME/CID ownership, named inline attachments, 10/15 MB limits, two-download queue, shared file, ImageIO thumbnail, unsupported format, stale image replies and close cancellation")

        model.draft.to = "recipient@example.com"; model.draft.subject = "synthetic"
        model.send(); model.send()
        try await settle { await fixture.sendCalls == 1 }
        await fixture.finishSend(.deliveryUnknown)
        try await settle { !model.isSending }
        precondition(model.sendLocked && model.sendMessage != nil && !model.draft.isEmpty && model.banner?.kind == .unknown && !model.composing)
        model.newDraft()
        precondition(model.sendLocked && !model.draft.isEmpty, "reopen preserves uncertain submission")
        model.send()
        let count = await fixture.sendCalls
        precondition(count == 1, "unknown send outcome blocks duplicate submission")

        model.discardDraft()
        let importingDraftID = model.draft.messageID
        model.importAttachments([])
        model.newDraft()
        precondition(model.draft.messageID == importingDraftID, "reopening during import preserves draft identity")
        try await settle { !model.isImporting }
        model.draft.to = "recipient@example.com"; model.send()
        try await settle { await fixture.sendCalls == 2 }
        await fixture.finishSend(copy: false)
        try await settle { !model.isSending }
        precondition(model.sendLocked && model.draft.isEmpty && model.sendMessage!.contains("請勿重寄"), "sent copy failure is accepted delivery")

        precondition(model.banner?.kind == .warning)
        model.discardDraft(); model.draft.to = "recipient@example.com"; model.composing = true; model.send()
        precondition(!model.composing && model.banner?.kind == .sending)
        try await settle { await fixture.sendCalls == 3 }
        await fixture.finishSend(.rejected)
        try await settle { !model.isSending }
        precondition(model.banner?.kind == .failure && !model.sendLocked && model.draft.to == "recipient@example.com")
        precondition(model.banner?.text.contains(NativeMailError.rejected.errorDescription!) == true,
                     "failure banner retains the controlled error reason for display and VoiceOver")
        precondition(model.banner?.canOpenDraft == true, "failure banner preserves open-draft action")
        model.reopenDraft()
        precondition(model.composing && model.draft.to == "recipient@example.com", "failure reopens retained draft")
        model.send()
        try await settle { await fixture.sendCalls == 4 }
        await fixture.finishSend()
        try await settle { !model.isSending }
        precondition(model.banner?.kind == .success && model.banner?.text == "郵件已寄出" && model.draft.isEmpty && model.successFeedback == 2)

        await fixture.setDelayedMutations(true)
        let before = model.messages[0]
        model.setFlagged(before, flagged: true)
        precondition(model.messages[0].flagged, "optimistic flag")
        try await settle { await fixture.mutationWaiters["flag"] != nil }
        await fixture.finishMutation("flag", error: .connection)
        try await settle { model.pendingMutations.isEmpty }
        precondition(!model.messages[0].flagged && model.operationError != nil, "flag rollback")
        model.setSeen(before, seen: true)
        precondition(!model.messages[0].unread, "optimistic seen")
        try await settle { await fixture.mutationWaiters["seen"] != nil }
        await fixture.finishMutation("seen", error: .connection)
        try await settle { model.pendingMutations.isEmpty }
        precondition(model.messages[0].unread, "seen rollback")
        model.setFlagged(before, flagged: true)
        try await settle { await fixture.mutationWaiters["flag"] != nil }
        model.read(before)
        try await settle { await fixture.detailWaiters[before.id.uid] != nil }
        await fixture.finishDetail(before.id.uid, text: "Opened during flag update")
        try await settle { !model.isReading }
        await fixture.finishMutation("flag")
        try await settle { await fixture.mutationWaiters["seen"] != nil }
        await fixture.finishMutation("seen")
        try await settle { model.pendingMutations.isEmpty }
        precondition(!model.messages[0].unread && model.messages[0].flagged, "opening during flag mutation queues seen update")
        model.closeMessage()
        let seenCalls = await fixture.seenCalls
        model.read(before)
        try await settle { await fixture.detailWaiters[before.id.uid] != nil }
        await fixture.finishDetail(before.id.uid, text: "", fail: true)
        try await settle { !model.isReading }
        let afterFailedRead = await fixture.seenCalls
        precondition(afterFailedRead == seenCalls && model.detailError != nil, "failed content does not mark read")
        model.closeMessage()
        model.moveToTrash(before)
        precondition(model.messages.isEmpty && model.total == 0, "optimistic trash")
        try await settle { await fixture.mutationWaiters["trash"] != nil }
        await fixture.finishMutation("trash", error: .mutationUncertain)
        try await settle { model.pendingMutations.isEmpty }
        precondition(model.messages[0].id == before.id && model.total == 1 && model.uncertainMutations.contains(before.id), "trash rollback and uncertain-operation lock")

        let namedRecipient = MailAddress(name: "王小明", address: "student@example.com")
        let unnamedRecipient = MailAddress(address: "peer@example.com")
        precondition(MailHeaderPresentation.recipientSummary([]) == "收件人：未提供")
        precondition(MailHeaderPresentation.recipientSummary([namedRecipient]) == "收件人：王小明")
        precondition(MailHeaderPresentation.recipientSummary([unnamedRecipient]) == "收件人：peer@example.com")
        precondition(MailHeaderPresentation.recipientSummary([namedRecipient, unnamedRecipient]) == "收件人：王小明 等 2 人")
        precondition(MailHeaderPresentation.recipientSummary([unnamedRecipient, namedRecipient, unnamedRecipient]) == "收件人：peer@example.com 等 3 人")
        precondition(MailHeaderPresentation.recipientLabel([namedRecipient, unnamedRecipient]) == "收件人：王小明")
        precondition(MailHeaderPresentation.recipientCountLabel([namedRecipient]) == nil)
        precondition(MailHeaderPresentation.recipientCountLabel([namedRecipient, unnamedRecipient]) == "等 2 人")
        precondition(namedRecipient.fullDescription == "王小明 <student@example.com>")
        precondition(unnamedRecipient.fullDescription == "peer@example.com")
        precondition(MailAddress(displayString: "\"王小明\" <student@example.com>") == namedRecipient)
        let sameReply = MailAddress(name: "不同顯示名稱", address: " STUDENT@EXAMPLE.COM ")
        precondition(MailHeaderPresentation.distinctReplyTo([sameReply], from: [namedRecipient]).isEmpty,
                     "Reply-To compares addresses, ignoring names, case and surrounding whitespace")
        precondition(MailHeaderPresentation.distinctReplyTo([], from: [namedRecipient]).isEmpty)
        precondition(MailHeaderPresentation.distinctReplyTo([unnamedRecipient], from: [namedRecipient]) == [unnamedRecipient])
        precondition(MailHeaderPresentation.distinctReplyTo([sameReply, unnamedRecipient], from: [namedRecipient]) == [sameReply, unnamedRecipient],
                     "a different Reply-To list preserves all recipients")
        let headerDate = ISO8601DateFormatter().date(from: "2026-10-03T08:21:00Z")!
        precondition(MailHeaderPresentation.headerDate(headerDate) == "2026年10月3日 下午4:21")
        precondition(MailHeaderPresentation.fullDate(headerDate) == "2026年10月3日 星期六 下午4:21")
        let midnightDate = ISO8601DateFormatter().date(from: "2026-10-03T16:12:00Z")!
        precondition(MailHeaderPresentation.headerDate(midnightDate) == "2026年10月4日 上午12:12")
        precondition(MailHeaderPresentation.fullDate(midnightDate) == "2026年10月4日 星期日 上午12:12")
        model.discardDraft()
        model.newDraft(to: namedRecipient.address)
        precondition(model.composing && model.draft.to == namedRecipient.address && model.draft.subject.isEmpty && model.draft.inReplyTo == nil)
        model.draft.body = "保留既有內容"
        model.newDraft(to: unnamedRecipient.address)
        precondition(model.draft.to == namedRecipient.address && model.draft.body == "保留既有內容" && model.sendMessage != nil)
        model.discardDraft()
        print("PASS: collapsed recipient summaries, full address/date labels, distinct Reply-To and address compose preserves existing draft")

        let original = MailMessageContent(text: "line 1\nline 2", simplifiedHTML: false, replyAddress: "sender@example.com",
            messageID: "<original@example.com>", attachments: [], to: ["student-b@niu.edu.tw", "peer@example.com"],
            cc: ["cc@example.com"], replyAllTo: ["student-b@niu.edu.tw", "peer@example.com", "sender@example.com"],
            replyAllCC: ["PEER@example.com", "cc@example.com", "student-b@niu.edu.tw"], references: ["<ancestor@example.com>"])
        let reply = MailDraft.prefilled(.reply, summary: before, content: original, ownAddress: model.accountAddress)
        precondition(reply.to == "sender@example.com" && reply.body.contains("> line 1\n> line 2") && reply.references.count == 2)
        let all = MailDraft.prefilled(.replyAll, summary: before, content: original, ownAddress: model.accountAddress)
        precondition(all.to == "sender@example.com, peer@example.com" && all.cc == "cc@example.com", "self exclusion and deduplication")
        var sentContent = original
        sentContent = MailMessageContent(text: original.text, simplifiedHTML: false, replyAddress: model.accountAddress,
            messageID: original.messageID, attachments: [], replyAllTo: ["recipient@example.com"])
        precondition(MailDraft.prefilled(.reply, summary: before, content: sentContent, ownAddress: model.accountAddress).to == "recipient@example.com", "reply to sent mail uses original recipients")
        let reSummary = MailSummary(id: before.id, subject: "Re: hello", sender: before.sender, date: nil, unread: false)
        precondition(MailDraft.prefilled(.reply, summary: reSummary, content: original, ownAddress: model.accountAddress).subject == "Re: hello")
        let fwdSummary = MailSummary(id: before.id, subject: "Fwd: hello", sender: before.sender, date: nil, unread: false)
        let forward = MailDraft.prefilled(.forward, summary: fwdSummary, content: original, ownAddress: model.accountAddress)
        precondition(forward.subject == "Fwd: hello" && forward.to.isEmpty && forward.inReplyTo == nil && forward.body.contains("轉寄郵件") && forward.body.contains("收件人："))

        // A stale screen's disappearance must not cancel the incoming screen's list.
        let outgoingOwner = UUID(), incomingOwner = UUID()
        model.activateList(owner: outgoingOwner); model.activateList(owner: incomingOwner)
        model.reload()
        try await settle { await fixture.inboxCalls == 6 }
        model.suspendList(owner: outgoingOwner)
        precondition(model.isLoading)
        await fixture.finishInbox("student-b", "Sent", uid: 88)
        try await settle { !model.isLoading }
        precondition(model.messages[0].id.uid == 88 && model.uncertainMutations.isEmpty)

        model.discardDraft(); model.draft.to = "recipient@example.com"; model.send()
        try await settle { await fixture.sendCalls == 5 }
        model.setFlagged(summary(999), flagged: true)
        try await settle { await fixture.mutationWaiters["flag"] != nil }
        await fixture.setDelayedAttachments(true)
        model.read(summary(15))
        try await settle { await fixture.detailWaiters[15] != nil }
        await fixture.finishDetail(15, text: "pending at logout", images: [images[0]])
        try await settle { await fixture.attachmentWaiters["15:a"] != nil }
        model.reset()
        await fixture.finishAttachment(15, "a", data: png)
        await fixture.finishMutation("flag", error: .connection)
        await fixture.finishSend()
        await Task.yield()
        precondition(!FileManager.default.fileExists(atPath: downloaded.path), "logout removes downloaded file")
        precondition(!FileManager.default.fileExists(atPath: inlineURL.path) && model.inlineThumbnails.isEmpty && model.inlineStatus.isEmpty,
                     "logout removes inline files and releases images")
        precondition(model.account.isEmpty && model.messages.isEmpty && model.content == nil && model.draft.isEmpty && model.sendMessage == nil && model.banner == nil && model.pendingMutations.isEmpty && model.operationError == nil && model.downloadedFiles.isEmpty && model.linkedBody.characters.isEmpty)

        let blocked = NativeMailViewModel(service: fixture, fileStore: fileStore, session: { "C" }, credentials: { ("different", "synthetic") })
        blocked.prepare(account: "student-c")
        precondition(blocked.errorMessage != nil && !blocked.isLoading, "mismatched credentials fail before network")
        let addresses = try MailDraft.addresses("a@example.com, b@example.com")
        precondition(addresses.count == 2)
        do { _ = try MailDraft.addresses("a@example.com\r\nBcc: other@example.com"); fatalError("header injection") } catch NativeMailError.invalidRecipient {}
        var draft = MailDraft(); draft.to = "a@example.com"; draft.subject = "hello\r\nBcc: other@example.com"
        do { try draft.validate(); fatalError("subject injection") } catch NativeMailError.invalidDraft {}
        draft.subject = "safe"; draft.bcc = "invalid"
        do { try draft.validate(); fatalError("invalid bcc") } catch NativeMailError.invalidRecipient {}
        draft.bcc = "private@example.com"; try draft.validate()
        draft.to = ""; try draft.validate() // BCC-only mail is valid.
        draft.to = "a@example.com"
        draft.subject = "safe"; draft.attachments = [MailOutgoingAttachment(name: "x", mime: "text/plain", data: Data(count: MailDraft.attachmentLimit + 1))]
        do { try draft.validate(); fatalError("oversized attachment") } catch NativeMailError.tooLarge {}
        let roleFixture = Fixture()
        let roleModel = NativeMailViewModel(service: roleFixture, fileStore: fileStore,
            session: { "role-session" }, credentials: { ("role-user", "synthetic") })
        let fakeTrash = MailFolder(id: "custom", name: "垃圾桶", role: .other)
        let realTrash = MailFolder(id: "Deleted.localized", name: "回收區", role: .trash)
        precondition(fakeTrash.title == "垃圾桶" && fakeTrash.symbol == "folder", "display title does not determine role")
        precondition(realTrash.title == "垃圾桶" && realTrash.symbol == "trash", "role determines title and symbol")
        roleModel.prepare(account: "role-user")
        try await settle { await roleFixture.inboxCalls == 1 }
        await roleFixture.finishInbox("role-user", folders: [fakeTrash])
        try await settle { !roleModel.isLoading }
        roleModel.requestDelete(summary(1))
        precondition(roleModel.deleteConfirmation != nil, "same-named ordinary folder cannot bypass confirmation")
        let noTrashCalls = await roleFixture.trashCalls
        precondition(noTrashCalls == 0, "no destructive call before confirmation")
        roleModel.deleteConfirmation = nil
        roleModel.reload()
        try await settle { await roleFixture.inboxCalls == 2 }
        await roleFixture.finishInbox("role-user", folders: [fakeTrash, realTrash])
        try await settle { !roleModel.isLoading }
        roleModel.requestDelete(summary(1))
        try await settle { await roleFixture.trashCalls == 1 && roleModel.pendingMutations.isEmpty }
        precondition(roleModel.deleteConfirmation == nil, "localized trash role accepts move")
        roleModel.requestDelete(summary(9, folder: realTrash.id))
        precondition(roleModel.deleteConfirmation?.id.folder == realTrash.id, "already in trash requires confirmation")
        roleModel.reset()
        // Exercise the actual DEBUG UI service, using only synthetic credentials.
        let uiFixture = NativeMailUIFixtureService(now: Date(timeIntervalSince1970: 1_790_000_000))
        let uiCredentials = MailCredentials(username: "test@niu.edu.tw", password: "synthetic-ui-password")
        let uiInbox = try await uiFixture.inbox(credentials: uiCredentials, folder: "INBOX", limit: 50)
        precondition(uiInbox.folders.count == 5 && uiInbox.folders.allSatisfy { $0.unreadCount != nil })
        var fixtureMessageCount = 0
        for folder in uiInbox.folders {
            fixtureMessageCount += try await uiFixture.inbox(credentials: uiCredentials, folder: folder.id, limit: 50).total
        }
        precondition(fixtureMessageCount == 20, "UI fixture has twenty messages across five folders")
        let uiMessage = uiInbox.messages.first!
        let uiContent = try await uiFixture.message(credentials: uiCredentials, key: uiMessage.id)
        precondition(uiContent.toRecipients.count == 2 && uiContent.ccRecipients.count == 2)
        precondition(uiContent.toRecipients.first?.name == "測試同學" && uiContent.ccRecipients.first?.name == "同學")
        precondition(uiContent.replyTo.first?.address == "events@example.com")
        precondition(MailHeaderPresentation.distinctReplyTo(uiContent.replyTo, from: uiContent.from) == uiContent.replyTo)
        precondition(uiContent.attachments.count == 2 && uiContent.text.contains("https://example.com/"))
        for attachment in uiContent.attachments {
            let data = try await uiFixture.attachment(credentials: uiCredentials, key: uiMessage.id, part: attachment.id)
            precondition(data.count == attachment.size, "fixture attachment metadata matches local content")
        }
        try await uiFixture.setSeen(credentials: uiCredentials, key: uiMessage.id, seen: true)
        let seenInbox = try await uiFixture.inbox(credentials: uiCredentials, folder: "INBOX", limit: 50)
        precondition(seenInbox.messages.first?.unread == false, "fixture mutations survive refresh")
        var uiDraft = MailDraft(); uiDraft.to = "recipient@example.com"; uiDraft.body = "合成內容"
        let clock = ContinuousClock(), started = ContinuousClock.now
        _ = try await uiFixture.send(credentials: uiCredentials, draft: uiDraft)
        precondition(clock.now - started >= .milliseconds(1400), "fixture send exposes the pending UI state")
        let failureFixture = NativeMailUIFixtureService(sendFailure: true)
        do {
            _ = try await failureFixture.send(credentials: uiCredentials, draft: uiDraft)
            fatalError("fixture failure mode must reject delivery")
        } catch NativeMailError.rejected {}
        for screen in ["list", "detail", "detail-expanded", "inline", "html", "notification", "compose", "reply", "sending", "sent", "failure"] {
            precondition(NativeMailUIFixtureScreen.launchScreen(arguments: ["app", "-NIUMailUIFixtureScreen", screen])?.rawValue == screen)
        }
        for arguments in [["app"], ["app", "-NIUMailUIFixtureScreen"],
                          ["app", "-NIUMailUIFixtureScreen", "delete-confirm"],
                          ["app", "-NIUMailUIFixtureScreen", "unknown"]] {
            precondition(NativeMailUIFixtureScreen.launchScreen(arguments: arguments) == nil)
        }
        let composeDraft = NativeMailUIFixtureService.screenshotDraft(invalidRecipient: true)
        let recipientTokens = composeDraft.to.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        precondition(composeDraft.to.hasSuffix(",") && recipientTokens.count == 3)
        precondition(recipientTokens.filter { (try? MailDraft.addresses($0))?.count == 1 }.count == 2)
        precondition(!composeDraft.canSend && !composeDraft.subject.isEmpty && composeDraft.body.contains("\n") && composeDraft.attachments.count == 1)
        let screenModel = NativeMailViewModel(service: uiFixture, fileStore: fileStore,
            session: { "ui-screen" }, credentials: { ("test@niu.edu.tw", "synthetic-ui-password") })
        screenModel.prepare(account: "test@niu.edu.tw")
        try await settle { screenModel.hasLoaded && !screenModel.isLoading }
        let inlineMessage = uiInbox.messages.first { $0.id.uid == 19 }!
        screenModel.read(inlineMessage)
        try await settle { screenModel.inlineThumbnails.count == 2 && screenModel.activeDownloads.isEmpty }
        let inlineFiles = screenModel.downloadedFiles
        precondition(inlineFiles.count == 2 && screenModel.content?.attachments.count == 1)
        screenModel.suspendReads()
        precondition(screenModel.inlineThumbnails.isEmpty)
        screenModel.loadInlineImages()
        try await settle { screenModel.inlineThumbnails.count == 2 && screenModel.activeDownloads.isEmpty }
        precondition(screenModel.downloadedFiles == inlineFiles, "foreground rebuilds thumbnails from shared local files")
        screenModel.read(uiInbox.messages.first { $0.id.uid == 18 }!)
        try await settle { !screenModel.isReading && screenModel.htmlDocument != nil }
        precondition(screenModel.content?.html?.contains("<table") == true && screenModel.htmlDocument?.referencedParts == ["cid"])
        precondition(screenModel.htmlDocument?.hasExternalImages == true && !screenModel.allowsExternalImages)
        let fixtureHTML = try SwiftSoup.parse(screenModel.content!.html!)
        let fixtureSources = try fixtureHTML.select("img").array().map { try $0.attr("src") }
        precondition(fixtureSources.filter { $0.hasPrefix("https://") }.count == 1 &&
                     fixtureSources.filter { $0.hasPrefix("http://") }.count == 1, "HTML fixture contains both external image protocols")
        screenModel.allowExternalImages()
        precondition(!screenModel.allowsExternalImages, "HTML fixture never opts into network")
        let cidData = try await screenModel.cidData(part: "cid", message: screenModel.selected!.id)
        precondition(cidData.starts(with: [137, 80, 78, 71]))
        screenModel.read(uiInbox.messages.first { $0.id.uid == 17 }!)
        try await settle { !screenModel.isReading && screenModel.htmlDocument != nil }
        let notification = try SwiftSoup.parse(screenModel.htmlDocument!.rendered(externalImages: false))
        let templateWidth = try notification.select("table").first()!.attr("width")
        let titleStyle = try notification.select("div").first()!.attr("style")
        let templateText = try notification.text()
        precondition(templateWidth == "700" && titleStyle.contains("height:48px") && titleStyle.contains("font-size:26px"))
        precondition(titleStyle.contains("overflow:hidden") && templateText.contains("底部驗收標記：合成通知結束。"))
        precondition(screenModel.htmlDocument?.hasExternalImages == false)
        print("PASS: synthetic 700px login notification, fixed 48px/26px title and bottom marker")
        screenModel.closeMessage()
        precondition(screenModel.htmlDocument == nil && !screenModel.allowsExternalImages)
        screenModel.compose(.replyAll, summary: uiMessage)
        try await settle { screenModel.composing && !screenModel.isPreparingDraft }
        precondition(screenModel.draft.to == "events@example.com, alex@example.com" && screenModel.draft.cc == "peer@example.com, assistant@example.com")
        precondition(screenModel.draft.body.contains("> ") && screenModel.draft.inReplyTo == uiContent.messageID)
        screenModel.showUIFixtureBanner(.sending)
        precondition(screenModel.isSending && screenModel.banner?.kind == .sending && !screenModel.composing)
        try await Task.sleep(for: .milliseconds(1600))
        precondition(screenModel.isSending && screenModel.banner?.kind == .sending, "screenshot sending stays pending")
        screenModel.showUIFixtureBanner(.sent)
        try await Task.sleep(for: .milliseconds(3200))
        precondition(screenModel.banner?.kind == .success && screenModel.draft.isEmpty && !screenModel.isSending,
                     "screenshot success survives the normal three-second dismissal")
        screenModel.showUIFixtureBanner(.failure)
        precondition(screenModel.banner?.kind == .failure && screenModel.banner?.canOpenDraft == true && !screenModel.sendLocked)
        precondition(screenModel.banner?.text.contains(NativeMailError.rejected.errorDescription!) == true && screenModel.draft.canSend)
        screenModel.reopenDraft()
        precondition(screenModel.composing && screenModel.draft.attachments.count == 1)
        screenModel.reset()
        print("PASS: DEBUG screen arguments, compose recipient tokens/attachment, reply-all prefill, persistent sending/sent banners and failure draft recovery")
        print("PASS: DEBUG UI fixture folders/messages, linked body, two local attachments, mutation persistence, 1.5-second send and failure mode")
        print("PASS: folder-role deletion and display, failure banner reason and draft action, send banners, failed draft reopen, flag/seen/trash rollback, reply/all/forward prefills, native mail credential binding, account/folder/detail races, refresh cache, send single-flight, ambiguous delivery lock, sent-copy failure, logout cleanup, recipient/header/size validation")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="niu-native-mail-check-") as directory:
    temp = Path(directory)
    source = temp / "Checks.swift"
    source.write_text(checks + "\nextension NativeMailService {\n" + email_builders + "\n}\n")
    binary = temp / "checks"
    # Compile the project's existing checkout in isolation. Never resolve/download dependencies.
    explicit_soup = os.environ.get("NIU_SWIFTSOUP_SOURCE")
    candidates = ([Path(explicit_soup)] if explicit_soup else []) + list(
        (Path.home() / "Library/Developer/Xcode/DerivedData").glob("*/SourcePackages/checkouts/SwiftSoup"))
    candidates += [Path("/tmp/niu-mail-dd/SourcePackages/checkouts/SwiftSoup")]
    candidates += list((root / ".build/checkouts").glob("SwiftSoup"))
    resolved = json.loads((root / "NIU-App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved").read_text())
    soup_revision = next(pin["state"]["revision"] for pin in resolved["pins"] if pin["identity"].lower() == "swiftsoup")
    def matches_pin(path):
        if not (path / "Sources/SwiftSoup.swift").is_file():
            return False
        revision = subprocess.run(["git", "-C", str(path), "rev-parse", "HEAD"], capture_output=True, text=True)
        return revision.returncode == 0 and revision.stdout.strip() == soup_revision
    soup = next((p for p in candidates if matches_pin(p)), None)
    if soup is None:
        raise SystemExit("Missing existing SwiftSoup checkout; set NIU_SWIFTSOUP_SOURCE to the locked local checkout (offline).")
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-emit-library", "-emit-module", "-module-name", "SwiftSoup",
                    "-module-cache-path", str(temp / "ModuleCache"), "-emit-module-path", str(temp / "SwiftSoup.swiftmodule"),
                    *map(str, sorted((soup / "Sources").rglob("*.swift"))), "-o", str(temp / "libSwiftSoup.dylib")], check=True)
    # Build MIME-only sources from the locked checkout; no package resolution,
    # SMTP, IMAP, or network mocks. Only unused network imports are removed in
    # temporary copies; SwiftCross's UTType re-export uses Apple's native module.
    mail_revision = next(pin["state"]["revision"] for pin in resolved["pins"] if pin["identity"].lower() == "swiftmail")
    explicit_mail = os.environ.get("NIU_SWIFTMAIL_SOURCE")
    mail_candidates = ([Path(explicit_mail)] if explicit_mail else []) + [soup.parent / "SwiftMail"]
    mail_candidates += [p.parent / "SwiftMail" for p in candidates]
    mail = None
    for candidate in mail_candidates:
        if not (candidate / "Sources/SwiftMail/Extensions/Email+Content.swift").is_file():
            continue
        revision = subprocess.run(["git", "-C", str(candidate), "rev-parse", "HEAD"], capture_output=True, text=True)
        if revision.returncode == 0 and revision.stdout.strip() == mail_revision:
            mail = candidate
            break
    if mail is None:
        raise SystemExit("Missing locked SwiftMail checkout; set NIU_SWIFTMAIL_SOURCE (offline).")
    cross = mail.parent / "SwiftCross"
    cross_revision = next(pin["state"]["revision"] for pin in resolved["pins"] if pin["identity"].lower() == "swiftcross")
    revision = subprocess.run(["git", "-C", str(cross), "rev-parse", "HEAD"], capture_output=True, text=True)
    if revision.returncode or revision.stdout.strip() != cross_revision:
        raise SystemExit("Missing locked SwiftCross checkout next to SwiftMail (offline).")
    mail_sources = mail / "Sources/SwiftMail"
    mime_paths = [mail_sources / path for path in [
        "Core/Models/Email.swift", "Core/Models/EmailAddress.swift", "Core/Models/MessageID.swift",
        "Core/Models/Attachment.swift", "Core/Models/AddressListEntry.swift",
        "Extensions/Email+Content.swift", "Extensions/EmailAddress+StringConversion.swift",
        "IMAP/Extensions/Data+Utilities.swift", "IMAP/Extensions/Int+Utilities.swift",
        "Extensions/String+RFC2047Encode.swift", "Extensions/String+SafeContent.swift",
        "MIME/MIMEHeaderEncoding.swift", "MIME/EMLParser+Parameters.swift", "MIME/EMLParser+RFC2231.swift",
    ]]
    mime_paths += sorted((mail_sources / "MIME/Address").glob("*.swift"))
    mime_paths += sorted((mail_sources / "Extensions").glob("String+QuotedPrintable*.swift"))
    mime_paths += [cross / "Sources/SwiftCross/StringEncoding+IANA.swift"]
    mime_files = []
    for index, path in enumerate(mime_paths):
        destination = temp / f"MIME{index}.swift"
        contents = path.read_text().replace("import NIO\n", "").replace("import NIOSSL\n", "")
        contents = contents.replace("import SwiftCross\n", "import UniformTypeIdentifiers\n")
        destination.write_text(contents)
        mime_files.append(destination)
    namespace = temp / "MIMENamespace.swift"
    namespace.write_text("enum EMLParser {}\n")
    mime_files.append(namespace)
    files = mime_files + [root / "Features/Mail/Native/MailHTMLPolicy.swift", root / "Features/Mail/Models/MailModels.swift",
             root / "Features/Mail/Native/NativeMailModels.swift",
             root / "Features/Mail/Native/NativeMailViewModel.swift",
             root / "Features/Mail/Native/NativeMailUIFixtureService.swift"]
    subprocess.run(["xcrun", "swiftc", "-D", "DEBUG", "-swift-version", "5", "-parse-as-library",
                    "-module-cache-path", str(temp / "ModuleCache"),
                    "-I", str(temp), "-L", str(temp), "-lSwiftSoup", "-Xlinker", "-rpath", "-Xlinker", str(temp),
                    *map(str, files), str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(temp)], check=True, timeout=30)
