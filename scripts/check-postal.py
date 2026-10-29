#!/usr/bin/env python3
"""Offline postal parsing/state regressions; --live checks a synthetic empty query."""
import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--live', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
source = r'''
import Foundation
import Synchronization

nonisolated struct StubPostalService: PostalServing {
    let load: @Sendable (PostalQuery) async throws -> PostalPage
    var loadNext: @Sendable (PostalPage) async throws -> PostalPage = { _ in throw PostalError.unavailable }
    var onInvalidate: @Sendable () -> Void = {}
    func search(_ query: PostalQuery) async throws -> PostalPage { try await load(query) }
    func nextPage(after page: PostalPage) async throws -> PostalPage { try await loadNext(page) }
    func invalidate() { onInvalidate() }
}
actor ServiceGate {
    var pending: [CheckedContinuation<any PostalServing, Never>] = []
    func make() async -> any PostalServing {
        await withCheckedContinuation { pending.append($0) }
    }
    var count: Int { pending.count }
    func resolve(_ index: Int, with service: any PostalServing) {
        pending[index].resume(returning: service)
    }
}
/// Requests for the three statuses start concurrently, so tests release them by status or name, not by order.
actor Gate {
    var pending: [(PostalQuery, CheckedContinuation<PostalPage, Error>)] = []
    var started = 0
    var statuses: [PostalStatus] = []
    func load(_ query: PostalQuery) async throws -> PostalPage {
        started += 1
        statuses.append(query.status)
        return try await withCheckedThrowingContinuation { pending.append((query, $0)) }
    }
    func resolve(_ status: PostalStatus) throws {
        guard let index = pending.firstIndex(where: { $0.0.status == status }) else { preconditionFailure("No pending \(status)") }
        let (query, continuation) = pending.remove(at: index)
        continuation.resume(returning: try PostalHTML.page(Checks.fixture(), query: query))
    }
    func resolveAll(name: String) throws {
        for (query, continuation) in pending where query.name == name {
            continuation.resume(returning: try PostalHTML.page(Checks.fixture(), query: query))
        }
        pending.removeAll { $0.0.name == name }
    }
}
actor PageGate {
    var pending: [(PostalPage, CheckedContinuation<PostalPage, Error>)] = []
    func load(_ page: PostalPage) async throws -> PostalPage {
        try await withCheckedThrowingContinuation { pending.append((page, $0)) }
    }
    var count: Int { pending.count }
    func fail(_ index: Int) { pending[index].1.resume(throwing: PostalError.unavailable) }
    func resolve(_ index: Int) throws {
        let (page, continuation) = pending[index]
        let html = Checks.fixture(pages: 2, index: 1).replacingOccurrences(of: "<td>1</td>", with: "<td>2</td>")
        continuation.resume(returning: try PostalHTML.page(html, query: page.query))
    }
}
/// Answers every request with a fixed status code, so the real PostalService status mapping is exercised offline.
final class StatusProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var retryAfter: String?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var headers: [String: String] = [:]
        if let value = Self.retryAfter { headers["Retry-After"] = value }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct Checks {
    static func fixture(rows: String? = nil, pages: Int = 1, index: Int = 0, next: String = "") -> String {
        let headings = ["序號", "收件日期", "郵件號碼", "收件單位", "收件者", "類別", "數量", "是否簽收", "簽收(退件)日期", "備註"]
        let header = headings.map { "<th class='rgHeader'>\($0)</th>" }.joined()
        let cells = ["1", "2026/9/30", "TEST&amp;123", "學生", "測試&#21516;學", "宅急便", "1", "&nbsp;", "&nbsp;", "請帶證件<br/>領取"]
        let row = "<tr class='rgRow'>" + cells.map { "<td>\($0)</td>" }.joined() + "</tr>"
        let meta = "[{\"ClientID\":\"RadGrid1_ctl00\",\"PageCount\":\(pages),\"CurrentPageIndex\":\(index)}]"
        let encoded = String(data: try! JSONEncoder().encode(meta), encoding: .utf8)!
        return """
        <input type='hidden' name='__VIEWSTATE' value='synthetic&amp;state'/>
        <input type='hidden' name='__EVENTVALIDATION' value='synthetic-validation'/>
        <input type='text' name='Key_name'/><input type='submit' name='Btn_Search'/>
        <table class='rgMasterTable' id='RadGrid1_ctl00'><thead><tr>\(header)</tr></thead>
        <tbody>\(rows ?? row)</tbody><tfoot>\(next)</tfoot></table>
        <script>var data={"_gridTableViewsData":\(encoded)};</script>
        """
    }
    static func rejected(_ html: String) {
        do { _ = try PostalHTML.page(html, query: PostalQuery(name: "測試同學")); preconditionFailure("Malformed response accepted") }
        catch PostalError.invalidResponse {} catch { preconditionFailure("Wrong parse error") }
    }
    @MainActor static func settle(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("State did not settle")
    }
    @MainActor static func main() async throws {
        let query = PostalQuery(name: "測試同學")
        let page = try PostalHTML.page(fixture(), query: query)
        precondition(page.records.count == 1)
        precondition(page.records[0].recipient == "測試同學")
        precondition(page.records[0].trackingNumber == "TEST&123")
        precondition(page.records[0].signature.isEmpty)
        precondition(page.records[0].note == "請帶證件 領取")
        let empty = fixture(rows: "<tr class='rgNoRecords'><td colspan='10'>查無資料</td></tr>")
        let emptyPage = try PostalHTML.page(empty, query: query)
        precondition(emptyPage.records.isEmpty)
        rejected(fixture(rows: ""))
        rejected(fixture().replacingOccurrences(of: "收件日期", with: "changed"))
        rejected(fixture().replacingOccurrences(of: "<td>1</td>", with: ""))
        rejected("<html>登入逾時</html>")
        rejected(fixture().replacingOccurrences(of: "_gridTableViewsData", with: "missing"))
        let form = PostalHTML.searchForm(try PostalHTML.form(in: fixture()), query: query)
        precondition(form["__VIEWSTATE"] == "synthetic&state" && form["RB_Date"] == "0")
        let encoded = String(decoding: PostalHTML.encodeForm(["Key_name": "林 &+同學", "DL_Status": "Y"]), as: UTF8.self)
        precondition(encoded.contains("%26%2B") && encoded.contains("DL_Status=Y"))
        let next = "<input type='submit' name='RadGrid1$ctl00$ctl03$ctl01$ctl03' class='rgPageNext' value=''/>"
        let multiple = try PostalHTML.page(fixture(pages: 2, next: next), query: query)
        precondition(multiple.nextForm?["RadGrid1$ctl00$ctl03$ctl01$ctl03"] == "")
        precondition(multiple.nextForm?["Btn_Search"] == nil && multiple.nextForm?["Key_name"] == query.name)
        let unsupported = try PostalHTML.page(fixture(pages: 2), query: query)
        precondition(unsupported.nextForm == nil && unsupported.pageCount == 2)
        precondition(!PostalQuery(name: "  ").canSearch)
        precondition(PostalQuery(phone: "0912000000").canSearch)
        print("PASS: records, entities, explicit empty state, strict schema, form encoding, paging, input validation")

        let gate = Gate()
        let model = PostalQueryViewModel(makeService: { StubPostalService(load: { query in try await gate.load(query) }) })
        model.query = query; model.search()
        try await settle { await gate.started == 3 }
        let requested = await gate.statuses
        precondition(Set(requested) == Set(PostalStatus.allCases))
        precondition(model.isSearching && model.isLoading && model.resultQuery == nil)
        try await gate.resolve(.collected)
        try await settle { model.countText(for: .collected) == "1" }
        precondition(model.resultQuery == nil && model.isLoading && model.isLoading(.waiting))
        model.query.status = .collected
        precondition(model.records.count == 1 && model.resultQuery?.status == .collected && !model.isLoading)
        try await Task.sleep(for: .milliseconds(30))
        let started1 = await gate.started
        precondition(started1 == 3)
        model.query.name = "新條件"
        precondition(model.filtersChanged && !model.isSearching && model.records.count == 1)
        model.search()
        try await settle { await gate.started == 6 }
        try await gate.resolveAll(name: "測試同學")
        try await Task.sleep(for: .milliseconds(30))
        precondition(model.records.isEmpty && model.isSearching)
        try await gate.resolveAll(name: "新條件")
        try await settle { !model.isSearching }
        precondition(model.resultQuery == PostalQuery(name: "新條件", status: .collected) && model.countText(for: .waiting) == "1")
        model.search()
        try await settle { await gate.started == 9 }
        model.reset()
        try await gate.resolveAll(name: "新條件")
        try await Task.sleep(for: .milliseconds(30))
        precondition(model.records.isEmpty && model.resultQuery == nil && model.submitted == nil)
        precondition(!model.query.canSearch && !model.isSearching && model.countText(for: .waiting) == nil)
        let failing = PostalQueryViewModel(makeService: { StubPostalService(load: { query in
            if query.status == .returned { throw URLError(.notConnectedToInternet) }
            return try PostalHTML.page(fixture(), query: query)
        }) })
        failing.query = query; failing.search()
        try await settle { !failing.isSearching }
        precondition(failing.resultQuery?.status == .waiting && failing.errorMessage == nil)
        failing.query.status = .returned
        precondition(failing.resultQuery == nil && failing.errorMessage?.contains("網路") == true)
        precondition(failing.countText(for: .returned) == nil && failing.countText(for: .collected) == "1")
        failing.query.name = ""
        failing.search()
        precondition(failing.errorMessage?.contains("其中一項") == true && !failing.isSearching)
        precondition(PostalQueryViewModel.message(for: PostalError.invalidResponse).contains("格式"))
        print("PASS: one search fetches all statuses, switching needs no request, stale/cancelled results ignored, per-status errors")

        let ownGate = Gate()
        let personal = PostalQueryViewModel(makeService: {
            StubPostalService(load: { query in try await ownGate.load(query) })
        })
        personal.prepare(account: " A001 ", name: " 測試同學 ")
        try await settle { await ownGate.started == 3 }
        precondition(personal.query == PostalQuery(name: "測試同學") && personal.isLoading)
        personal.prepare(account: "a001", name: "測試同學")
        try await ownGate.resolveAll(name: "測試同學")
        try await settle { !personal.isSearching }
        precondition(personal.resultQuery?.name == "測試同學")
        let started2 = await ownGate.started
        precondition(started2 == 3)
        personal.selectOwnStatus(.returned)
        precondition(personal.resultQuery?.status == .returned && !personal.isLoading)
        let started3 = await ownGate.started
        precondition(started3 == 3)
        personal.search()
        try await settle { await ownGate.started == 6 }
        try await ownGate.resolveAll(name: "測試同學")
        try await settle { !personal.isSearching }
        precondition(personal.resultQuery?.status == .returned)
        personal.query = PostalQuery(name: "其他同學", phone: "0912000000", trackingNumber: "OTHER", status: .returned)
        personal.searchOwnMail()
        try await settle { await ownGate.started == 9 }
        precondition(personal.query == PostalQuery(name: "測試同學"))
        personal.prepare(account: "b002", name: "另一位同學")
        try await settle { await ownGate.started == 12 }
        try await ownGate.resolveAll(name: "測試同學")
        try await Task.sleep(for: .milliseconds(30))
        precondition(personal.records.isEmpty && personal.isLoading && personal.ownName == "另一位同學")
        try await ownGate.resolveAll(name: "另一位同學")
        try await settle { !personal.isSearching }
        precondition(personal.resultQuery?.name == "另一位同學")
        personal.searchOwnMail()
        try await settle { await ownGate.started == 15 }
        personal.prepare(account: nil, name: nil)
        try await ownGate.resolveAll(name: "另一位同學")
        try await Task.sleep(for: .milliseconds(30))
        precondition(personal.ownName == nil && personal.records.isEmpty && !personal.query.canSearch && !personal.isSearching)
        personal.prepare(account: "b002", name: "另一位同學")
        try await settle { await ownGate.started == 18 }
        try await ownGate.resolveAll(name: "另一位同學")
        try await settle { !personal.isSearching }
        personal.selectOwnStatus(.returned)
        personal.prepare(account: "b002", name: "更新姓名")
        try await settle { await ownGate.started == 21 }
        try await ownGate.resolveAll(name: "更新姓名")
        try await settle { !personal.isSearching }
        precondition(personal.resultQuery == PostalQuery(name: "更新姓名", status: .returned))
        personal.prepare(account: "b002", name: "")
        precondition(personal.ownName == nil && personal.resultQuery == nil && personal.records.isEmpty)
        print("PASS: own mail fetches all statuses, switching is instant, refresh retains status, account/profile changes discard stale results")

        let fallback = PostalQueryViewModel(makeService: {
            StubPostalService(load: { query in try PostalHTML.page(fixture(), query: query) })
        })
        fallback.prepare(account: "a001", name: " \n ")
        precondition(fallback.ownName == nil && !fallback.isSearching && !fallback.query.canSearch)
        fallback.prepare(account: "a001", name: "A001")
        precondition(fallback.ownName == nil && !fallback.isSearching)
        fallback.query.name = "手動查詢"
        fallback.prepare(account: "a001", name: "測試同學")
        precondition(fallback.ownName == "測試同學" && fallback.query.name == "手動查詢" && !fallback.isSearching)
        fallback.reset()
        fallback.prepare(account: "a001", name: nil)
        fallback.prepare(account: "a001", name: "測試同學")
        try await settle { !fallback.isSearching }
        precondition(fallback.resultQuery?.name == "測試同學")
        print("PASS: automatic own-mail lookup, shortcut clears filters, account switch/logout discard stale results, reentry, missing/late profile")

        let factory = ServiceGate()
        let discarded = Mutex(0)
        let started = Mutex(0)
        let delayedService = StubPostalService(load: { query in
            started.withLock { $0 += 1 }
            return try PostalHTML.page(fixture(), query: query)
        }, onInvalidate: { discarded.withLock { $0 += 1 } })
        let delayed = PostalQueryViewModel(makeService: { await factory.make() })
        delayed.query = query; delayed.search()
        try await settle { await factory.count == 3 }
        precondition(delayed.isSearching)
        delayed.query.name = "新條件"; delayed.search()
        try await settle { await factory.count == 6 }
        for index in 0..<3 { await factory.resolve(index, with: delayedService) }
        try await settle { discarded.withLock { $0 == 3 } }
        precondition(started.withLock { $0 == 0 } && delayed.isSearching)
        for index in 3..<6 { await factory.resolve(index, with: delayedService) }
        try await settle { !delayed.isSearching }
        precondition(delayed.resultQuery?.name == "新條件" && started.withLock { $0 == 3 })
        delayed.search()
        try await settle { await factory.count == 9 }
        precondition(discarded.withLock { $0 == 6 })
        delayed.reset()
        for index in 6..<9 { await factory.resolve(index, with: delayedService) }
        try await settle { discarded.withLock { $0 == 9 } }
        precondition(delayed.records.isEmpty && delayed.resultQuery == nil && !delayed.isSearching)
        precondition(started.withLock { $0 == 3 })
        print("PASS: asynchronous session setup, one session per status, replaced/reset setup and old results invalidated")

        let pageGate = PageGate()
        let paging = PostalQueryViewModel(makeService: {
            StubPostalService(
                load: { query in try PostalHTML.page(fixture(pages: 2, next: next), query: query) },
                loadNext: { page in try await pageGate.load(page) }
            )
        })
        paging.query = query; paging.search()
        try await settle { !paging.isSearching }
        paging.loadMore()
        try await settle { await pageGate.count == 1 }
        await pageGate.fail(0)
        try await settle { !paging.isLoading }
        precondition(paging.records.count == 1 && paging.errorMessage != nil && paging.page?.pageIndex == 0)
        paging.loadMore()
        try await settle { await pageGate.count == 2 }
        try await pageGate.resolve(1)
        try await settle { !paging.isLoading }
        precondition(paging.records.count == 2 && paging.page?.pageIndex == 1 && paging.errorMessage == nil)
        paging.query.status = .returned
        precondition(paging.records.count == 1 && paging.page?.pageIndex == 0)
        precondition(paging.countText(for: .returned) == "1+" && paging.countText(for: .waiting) == "2")
        paging.search()
        try await settle { !paging.isSearching }
        paging.loadMore()
        try await settle { await pageGate.count == 3 }
        paging.search()
        try await settle { !paging.isSearching }
        try await pageGate.resolve(2)
        try await Task.sleep(for: .milliseconds(30))
        precondition(paging.records.count == 1 && paging.resultQuery?.status == .returned && paging.page?.pageIndex == 0)
        print("PASS: pagination per status, failure preserving results, retry, other statuses untouched, cancellation during a new query")
        PostalQueryViewModel.clearThrottle()
        let calls = Mutex([PostalStatus: Int]())
        let limitedOnce = Mutex(false)
        let throttling = PostalQueryViewModel(makeService: {
            StubPostalService(load: { query in
                calls.withLock { $0[query.status, default: 0] += 1 }
                if query.status == .collected, limitedOnce.withLock({ value in defer { value = true }; return !value }) {
                    throw PostalError.rateLimited(retryAfter: 0)
                }
                return try PostalHTML.page(fixture(), query: query)
            })
        }, minimumRetryDelay: 0)
        throttling.query = query; throttling.search()
        try await settle { !throttling.isSearching }
        precondition(PostalQueryViewModel.isThrottled)
        precondition(throttling.countText(for: .waiting) == "1" && throttling.countText(for: .returned) == "1")
        precondition(throttling.countText(for: .collected) == nil && throttling.errorMessage == nil)
        throttling.selectStatus(.collected)
        try await settle { !throttling.isSearching }
        precondition(throttling.resultQuery?.status == .collected && calls.withLock { $0[.collected] } == 2)
        throttling.search()
        try await settle { !throttling.isSearching }
        precondition(calls.withLock { $0[.collected] == 3 && $0[.waiting] == 1 && $0[.returned] == 1 })
        throttling.selectStatus(.returned)
        try await settle { !throttling.isSearching }
        precondition(calls.withLock { $0[.returned] } == 2 && throttling.resultQuery?.status == .returned)
        throttling.selectStatus(.collected)
        precondition(calls.withLock { $0[.collected] } == 3 && throttling.resultQuery?.status == .collected)

        let shownCalls = Mutex(0)
        let stubborn = PostalQueryViewModel(makeService: { StubPostalService(load: { _ in
            shownCalls.withLock { $0 += 1 }
            throw PostalError.rateLimited(retryAfter: 0)
        }) }, minimumRetryDelay: 0)
        stubborn.query = query; stubborn.search()
        try await settle { !stubborn.isSearching }
        precondition(shownCalls.withLock { $0 } == 2 && stubborn.errorMessage?.contains("限制") == true)

        let flaky = Mutex(0)
        let recovering = PostalQueryViewModel(makeService: { StubPostalService(load: { query in
            if flaky.withLock({ $0 += 1; return $0 == 1 }) { throw PostalError.rateLimited(retryAfter: 0) }
            return try PostalHTML.page(fixture(), query: query)
        }) }, minimumRetryDelay: 0)
        recovering.query = query; recovering.search()
        try await settle { !recovering.isSearching }
        precondition(recovering.resultQuery?.status == .waiting && recovering.errorMessage == nil && flaky.withLock { $0 } == 2)

        let waitCalls = Mutex(0)
        let patient = PostalQueryViewModel(makeService: { StubPostalService(load: { _ in
            waitCalls.withLock { $0 += 1 }
            throw PostalError.rateLimited(retryAfter: 30)
        }) }, minimumRetryDelay: 0)
        patient.query = query; patient.search()
        try await settle { waitCalls.withLock { $0 } == 1 }
        try await Task.sleep(for: .milliseconds(30))
        precondition(patient.isLoading)
        patient.reset()
        try await Task.sleep(for: .milliseconds(50))
        precondition(waitCalls.withLock { $0 } == 1 && !patient.isSearching && patient.errorMessage == nil)
        PostalQueryViewModel.clearThrottle()
        precondition(PostalQueryViewModel.message(for: PostalError.rateLimited(retryAfter: nil)).contains("限制"))
        for (status, header, expected) in [(429, "7", PostalError.rateLimited(retryAfter: 7)),
                                           (503, nil, PostalError.rateLimited(retryAfter: nil)),
                                           (429, "Wed, 21 Oct 2026 07:28:00 GMT", PostalError.rateLimited(retryAfter: nil)),
                                           (500, nil, PostalError.unavailable)] as [(Int, String?, PostalError)] {
            StatusProtocol.status = status
            StatusProtocol.retryAfter = header
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StatusProtocol.self]
            let service = PostalService(configuration: configuration)
            do { _ = try await service.search(query); preconditionFailure("HTTP \(status) accepted") }
            catch let error as PostalError { precondition(error == expected, "HTTP \(status) mapped to \(error)") }
            service.invalidate()
        }
        print("PASS: 429/503 fall back to on-demand loading, shown status retried once, cancellable wait, shared cooldown, HTTP 429/503 and Retry-After mapping")
        if CommandLine.arguments.contains("--live") {
            let live = PostalService()
            defer { live.invalidate() }
            let result = try await live.search(PostalQuery(name: "NIU_APP_TEST_NO_RECIPIENT_8F271"))
            precondition(result.records.isEmpty)
            print("PASS: live URLSession GET/POST using synthetic recipient returned explicit empty results")
        }
    }
}
'''
with tempfile.TemporaryDirectory(prefix='niu-postal-check-') as directory:
    folder = Path(directory)
    checks = folder / 'Checks.swift'
    checks.write_text(source)
    files = [root / f'Features/Postal/{path}' for path in (
        'Models/PostalModels.swift', 'Services/PostalService.swift', 'ViewModels/PostalQueryViewModel.swift')]
    binary = folder / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(folder / 'ModuleCache'),
                    '-parse-as-library', *map(str, files), str(checks), '-o', str(binary)], check=True)
    subprocess.run([str(binary)] + (['--live'] if args.live else []), check=True, timeout=90 if args.live else 20)
