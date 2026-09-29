import Foundation

nonisolated struct EnrollmentRecord: Decodable, Equatable, Identifiable, Sendable {
    let semester: String
    let studentID: String
    let name: String
    let department: String
    let grade: String
    let studentStatus: String
    let registrationStatus: String
    let registrationDate: String
    var id: String { "\(semester)-\(studentID)" }

    var semesterTitle: String {
        guard semester.count == 4, let term = semester.last, "12".contains(term),
              Int(semester.dropLast()) != nil else { return semester }
        return "\(semester.dropLast()) 學年度第 \(term) 學期"
    }
}

nonisolated struct EnrollmentSnapshot: Decodable, Sendable {
    let records: [EnrollmentRecord]
    let canPrint: Bool
}

nonisolated enum EnrollmentError: Error, Equatable {
    case sessionExpired
    case invalidResponse
    case unavailable
    case tooLarge
}

nonisolated enum EnrollmentEndpoint {
    static let mainFrame = URL(string: "https://acade.niu.edu.tw/NIU/MainFrame.aspx")
    static let registration = "https://acade.niu.edu.tw/NIU/Application/ENR/ENR50/ENR5020_.aspx?progcd=ENR5020"

    static func isLegacyPortalLanding(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "ccsys.niu.edu.tw"
            && ["/sso/std002.aspx", "/sso/stdmain.aspx"].contains(url.path.lowercased())
    }

    static func allowsRegistrationNavigation(_ url: URL) -> Bool {
        (url.scheme == "https" && url.host?.lowercased() == "acade.niu.edu.tw")
            || isLegacyPortalLanding(url) || url.absoluteString == "about:blank"
    }

    static func certificate(studentID: String) -> URL? {
        guard studentID.range(of: #"^[A-Za-z0-9]{4,32}$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: "https://ccsys.niu.edu.tw/MvcTeam/AcadeExport/StudyProved/\(studentID)")
    }

    // Reject redirects before carrying a personal document request to another destination.
    static func isCertificate(_ url: URL, studentID: String) -> Bool {
        guard let expected = certificate(studentID: studentID) else { return false }
        return url.scheme == "https" && url.host?.lowercased() == expected.host
            && url.port == nil && url.user == nil && url.password == nil
            && url.path.lowercased() == expected.path.lowercased() && url.query == nil
    }

    static func isCertificateLogin(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "ccsys.niu.edu.tw"
            && url.port == nil && url.user == nil && url.password == nil
            && url.path.lowercased() == "/mvcteam/account/login"
    }
}

enum EnrollmentPageScript {
    // Use the school's menu handler and target frame. Loading ENR5020_.aspx as
    // the top document removes the MainFrame helpers that its child pages expect.
    static let openRegistrationMenu = #"""
    (() => {
        const menu = window.frames['menuFrame'];
        if (!menu) return 'waiting-menu';
        const links = Array.from(menu.document.querySelectorAll('a'));
        const text = a => (a.innerText || a.textContent || '').replace(/\s+/g, '').trim();
        const leaf = links.find(a => /\/ENR5020_\.aspx(?:\?|$)/i.test(a.getAttribute('href') || '')
            || ['查詢註冊', '註冊查詢'].includes(text(a)));
        if (leaf) {
            const target = leaf.getAttribute('target') || menu.document.querySelector('base')?.getAttribute('target') || '_self';
            const targetWindow = target === '_self' ? menu : target === '_parent' ? menu.parent
                : target === '_top' ? window : window.frames[target];
            window.__niuEnrollmentTarget = target.startsWith('_') ? null : target;
            window.__niuEnrollmentTargetWindow = targetWindow || null;
            try {
                window.__niuEnrollmentTarget = targetWindow?.name || window.__niuEnrollmentTarget;
                window.__niuEnrollmentPreviousDocument = targetWindow?.document || null;
            }
            catch (_) { window.__niuEnrollmentPreviousDocument = null; }
            leaf.click();
            return 'opened-registration';
        }
        for (const title of ['註冊作業', '學籍及畢審']) {
            const branch = links.find(a => text(a).includes(title));
            if (branch) { branch.click(); return 'opening-menu'; }
        }
        return 'waiting-menu';
    })()
    """#

    // Evaluate in WKNavigationAction.targetFrame before an authentication redirect
    // commits; the previous same-origin document still identifies its target subtree.
    static let isRegistrationFrame = #"""
    (() => {
        try {
            const root = window.top;
            for (let w = window; w && w !== root; w = w.parent) {
                if (w === root.__niuEnrollmentTargetWindow) return true;
                const src = w.frameElement?.getAttribute('src') || '';
                if (/(?:^|\/)ENR5020_(?:01)?\.aspx(?:\?|$)/i.test(src)
                    || /\/ENR5020_(?:01)?\.aspx$/i.test(w.location.pathname)) return true;
            }
        } catch (_) { /* An unrelated cross-origin frame cannot identify this query. */ }
        return false;
    })()
    """#

    // Inspect only the registration frame, never the hidden timeout/login frame in MainFrame.
    static let snapshot = #"""
    (() => {
        function find(w, isTarget = false) {
            try {
                // A click schedules navigation; the old outer document and all of
                // its children remain readable until commit, even for the same URL.
                if (w === window.__niuEnrollmentTargetWindow && w.document === window.__niuEnrollmentPreviousDocument) return null;
                // Restrict expiry detection to the menu's actual target subtree.
                // MainFrame also contains an unrelated, permanently expired hidden frame.
                const src = w.frameElement?.getAttribute('src') || '';
                isTarget = isTarget || w === window.__niuEnrollmentTargetWindow
                    || (window.__niuEnrollmentTarget && w.name === window.__niuEnrollmentTarget)
                    || /(?:^|\/)ENR5020_(?:01)?\.aspx(?:\?|$)/i.test(src);
                if (isTarget && /\/(?:TimeoutPage|Default|Login)\.aspx$/i.test(w.location.pathname)) return 'session-expired';
                if (/\/ENR5020_01\.aspx$/i.test(w.location.pathname)) return w.document;
                for (let i = 0; i < w.frames.length; i++) {
                    const d = find(w.frames[i], isTarget); if (d) return d;
                }
            } catch (_) { /* A cross-origin frame is not a registration result. */ }
            return null;
        }
        const d = find(window);
        if (!d) return null;
        if (d === 'session-expired') return d;
        const table = d.getElementById('DataGrid');
        if (!table) {
            if (/查無資料|無符合.*資料|沒有資料/.test(d.body.innerText))
                return JSON.stringify({records: [], canPrint: false});
            return null;
        }
        const clean = e => (e ? e.innerText : '').replace(/\s+/g, ' ').trim();
        const headers = Array.from(table.querySelectorAll('th')).map(e => clean(e).replace(/[↑↓\s]/g, ''));
        const fields = {semester:'註冊學年期',studentID:'學號',name:'姓名',department:'系所',grade:'年級',studentStatus:'在學狀態',registrationStatus:'註冊狀態',registrationDate:'註冊日期'};
        if (Object.values(fields).some(h => !headers.includes(h))) return 'invalid';
        const records = [];
        for (const row of table.rows) {
            if (row.querySelector('th')) continue;
            if (row.cells.length !== headers.length) {
                if (/查無資料|無符合.*資料|沒有資料/.test(clean(row))) continue;
                return 'invalid';
            }
            const record = {};
            for (const [key, header] of Object.entries(fields)) record[key] = clean(row.cells[headers.indexOf(header)]);
            if (!record.studentID || !record.semester) return 'invalid';
            records.push(record);
        }
        const button = d.getElementById('GoToPrint');
        return JSON.stringify({records, canPrint: !!button && !button.disabled && records.length > 0});
    })()
    """#
}
