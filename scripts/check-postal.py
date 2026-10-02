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
actor Gate {
    var pending: [(PostalQuery, CheckedContinuation<PostalPage, Error>)] = []
    func load(_ query: PostalQuery) async throws -> PostalPage {
        try await withCheckedThrowingContinuation { pending.append((query, $0)) }
    }
    var count: Int { pending.count }
    func resolve(_ index: Int) throws {
        let (query, continuation) = pending[index]
        continuation.resume(returning: try PostalHTML.page(Checks.fixture(), query: query))
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
        let service = StubPostalService(load: { query in try await gate.load(query) })
        let model = PostalQueryViewModel(makeService: { service })
        model.query = query; model.search()
        try await settle { await gate.count == 1 }
        model.query.status = .collected; model.search()
        try await settle { await gate.count == 2 }
        try await gate.resolve(0)
        try await Task.sleep(for: .milliseconds(30))
        precondition(model.records.isEmpty && model.isLoading)
        try await gate.resolve(1)
        try await settle { !model.isLoading }
        precondition(model.records.count == 1 && model.resultQuery?.status == .collected)
        model.query.name = "新條件"
        precondition(model.filtersChanged)
        model.search()
        try await settle { await gate.count == 3 }
        model.reset()
        try await gate.resolve(2)
        try await Task.sleep(for: .milliseconds(30))
        precondition(model.records.isEmpty && model.resultQuery == nil && !model.query.canSearch)
        model.query = query; model.search()
        try await settle { await gate.count == 4 }
        model.query.name = "編輯中"
        try await gate.resolve(3)
        try await Task.sleep(for: .milliseconds(30))
        precondition(model.records.isEmpty && !model.isLoading)
        let failing = PostalQueryViewModel(makeService: { StubPostalService(load: { _ in throw URLError(.notConnectedToInternet) }) })
        failing.query = query; failing.search()
        try await settle { !failing.isLoading }
        precondition(failing.resultQuery == nil && failing.errorMessage?.contains("網路") == true)
        precondition(PostalQueryViewModel.message(for: PostalError.invalidResponse).contains("格式"))
        print("PASS: stale requests, filter edits, reset/account cleanup, empty vs network/parse errors")

        let ownGate = Gate()
        let personal = PostalQueryViewModel(makeService: {
            StubPostalService(load: { query in try await ownGate.load(query) })
        })
        personal.prepare(account: " A001 ", name: " 測試同學 ")
        try await settle { await ownGate.count == 1 }
        precondition(personal.query == PostalQuery(name: "測試同學") && personal.isLoading)
        personal.prepare(account: "a001", name: "測試同學")
        try await ownGate.resolve(0)
        try await settle { !personal.isLoading }
        precondition(personal.resultQuery?.name == "測試同學")
        let ownSearchCount = await ownGate.count
        precondition(ownSearchCount == 1)
        personal.query = PostalQuery(name: "其他同學", phone: "0912000000", trackingNumber: "OTHER", status: .returned)
        personal.searchOwnMail()
        try await settle { await ownGate.count == 2 }
        precondition(personal.query == PostalQuery(name: "測試同學"))
        personal.prepare(account: "b002", name: "另一位同學")
        try await settle { await ownGate.count == 3 }
        try await ownGate.resolve(1)
        try await Task.sleep(for: .milliseconds(30))
        precondition(personal.records.isEmpty && personal.isLoading && personal.ownName == "另一位同學")
        try await ownGate.resolve(2)
        try await settle { !personal.isLoading }
        precondition(personal.resultQuery?.name == "另一位同學")
        personal.searchOwnMail()
        try await settle { await ownGate.count == 4 }
        personal.prepare(account: nil, name: nil)
        try await ownGate.resolve(3)
        try await Task.sleep(for: .milliseconds(30))
        precondition(personal.ownName == nil && personal.records.isEmpty && !personal.query.canSearch)
        personal.prepare(account: "b002", name: "另一位同學")
        try await settle { await ownGate.count == 5 }
        try await ownGate.resolve(4)
        try await settle { !personal.isLoading }
        precondition(personal.resultQuery?.name == "另一位同學")

        personal.selectOwnStatus(.collected)
        try await settle { await ownGate.count == 6 }
        precondition(personal.isLoading && personal.query.status == .collected)
        personal.selectOwnStatus(.returned)
        try await settle { await ownGate.count == 7 }
        try await ownGate.resolve(5)
        try await Task.sleep(for: .milliseconds(30))
        precondition(personal.resultQuery == nil && personal.isLoading)
        try await ownGate.resolve(6)
        try await settle { !personal.isLoading }
        precondition(personal.resultQuery?.status == .returned)
        personal.selectOwnStatus(.returned)
        precondition(!personal.isLoading)
        personal.search()
        try await settle { await ownGate.count == 8 }
        try await ownGate.resolve(7)
        try await settle { !personal.isLoading }
        precondition(personal.resultQuery?.status == .returned)
        personal.prepare(account: "b002", name: "更新姓名")
        try await settle { await ownGate.count == 9 }
        try await ownGate.resolve(8)
        try await settle { !personal.isLoading }
        precondition(personal.resultQuery == PostalQuery(name: "更新姓名", status: .returned))
        personal.prepare(account: "b002", name: "")
        precondition(personal.ownName == nil && personal.resultQuery == nil && personal.records.isEmpty)
        print("PASS: status changes auto-search, rapid switches reject stale results, refresh retains status, profile changes refresh identity")

        let fallback = PostalQueryViewModel(makeService: {
            StubPostalService(load: { query in try PostalHTML.page(fixture(), query: query) })
        })
        fallback.prepare(account: "a001", name: " \n ")
        precondition(fallback.ownName == nil && !fallback.isLoading && !fallback.query.canSearch)
        fallback.prepare(account: "a001", name: "A001")
        precondition(fallback.ownName == nil && !fallback.isLoading)
        fallback.query.name = "手動查詢"
        fallback.prepare(account: "a001", name: "測試同學")
        precondition(fallback.ownName == "測試同學" && fallback.query.name == "手動查詢" && !fallback.isLoading)
        fallback.reset()
        fallback.prepare(account: "a001", name: nil)
        fallback.prepare(account: "a001", name: "測試同學")
        try await settle { !fallback.isLoading }
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
        try await settle { await factory.count == 1 }
        precondition(delayed.isLoading)
        delayed.query.name = "新條件"; delayed.search()
        try await settle { await factory.count == 2 }
        await factory.resolve(0, with: delayedService)
        try await settle { discarded.withLock { $0 == 1 } }
        precondition(started.withLock { $0 == 0 } && delayed.isLoading)
        await factory.resolve(1, with: delayedService)
        try await settle { !delayed.isLoading }
        precondition(delayed.resultQuery?.name == "新條件" && started.withLock { $0 == 1 })
        delayed.search()
        try await settle { await factory.count == 3 }
        delayed.reset()
        let beforeResetReturn = discarded.withLock { $0 }
        await factory.resolve(2, with: delayedService)
        try await settle { discarded.withLock { $0 == beforeResetReturn + 1 } }
        precondition(delayed.records.isEmpty && delayed.resultQuery == nil && !delayed.isLoading)
        precondition(started.withLock { $0 == 1 })
        print("PASS: asynchronous session setup, replaced/reset setup invalidated before network requests")

        let pageGate = PageGate()
        let paging = PostalQueryViewModel(makeService: {
            StubPostalService(
                load: { query in try PostalHTML.page(fixture(pages: 2, next: next), query: query) },
                loadNext: { page in try await pageGate.load(page) }
            )
        })
        paging.query = query; paging.search()
        try await settle { !paging.isLoading }
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
        paging.search()
        try await settle { !paging.isLoading }
        paging.loadMore()
        try await settle { await pageGate.count == 3 }
        paging.query.status = .returned
        paging.search()
        try await settle { !paging.isLoading }
        try await pageGate.resolve(2)
        try await Task.sleep(for: .milliseconds(30))
        precondition(paging.records.count == 1 && paging.resultQuery?.status == .returned && paging.page?.pageIndex == 0)
        print("PASS: pagination append, failure preserving results, retry, cancellation during a new query")
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
