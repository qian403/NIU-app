import Foundation
import SwiftSoup

nonisolated struct MailHTMLDocument: Sendable {
    let markup: String
    let insertionToken: String
    let hasExternalImages: Bool
    let referencedParts: Set<String>
    let hasOwnColors: Bool

    func rendered(externalImages: Bool) -> String {
        let colors = hasOwnColors ? "html{color-scheme:only light;background:white;color:black}"
            : "html{color-scheme:light dark;background:Canvas;color:CanvasText}body{background:Canvas;color:CanvasText}"
        let head = """
        <meta http-equiv="Content-Security-Policy" content="\(MailHTMLPolicy.csp(externalImages: externalImages))">
        <meta name="referrer" content="no-referrer">
        <meta name="viewport" content="initial-scale=1">
        <style>\(colors)
        html,body{-webkit-text-size-adjust:100%!important}
        body{margin:0;font-family:-apple-system;font-size:17px}
        img{max-width:100%;height:auto}
        </style>
        """
        return markup.replacingOccurrences(of: insertionToken, with: head)
    }
}

nonisolated enum MailHTMLNavigation: Equatable {
    case initial, external(URL), compose(to: String, subject: String), cancel
}

nonisolated enum MailHTMLPolicy {
    static let scheme = "niu-mail-cid"

    // App-owned, read-only geometry; never return text, attributes or URLs.
    // Rects see fixed-width descendants even when an ancestor clips overflow.
    static let measurementScript = """
    (() => {
        const root = document.documentElement, body = document.body;
        let right = 0, bottom = 0;
        for (const element of document.querySelectorAll('*')) {
            const rect = element.getBoundingClientRect();
            right = Math.max(right, rect.right);
            bottom = Math.max(bottom, rect.bottom);
        }
        return {width: Math.max(root.scrollWidth, body ? body.scrollWidth : 0),
                height: Math.max(root.scrollHeight, body ? body.scrollHeight : 0),
                clientWidth: root.clientWidth, right, bottom};
    })()
    """

    /// Native display scale, independent of WebKit pageZoom / viewport reflow.
    /// No minimum scale: even very wide mail must fit without horizontal scrolling.
    static func fittingScale(contentWidth: Double, viewportWidth: Double) -> Double {
        guard contentWidth.isFinite, viewportWidth.isFinite, contentWidth > 0, viewportWidth > 0 else { return 1 }
        return min(1, viewportWidth / contentWidth)
    }

    static func csp(externalImages: Bool) -> String {
        "default-src 'none'; img-src cid: niu-mail-cid: data:\(externalImages ? " https:" : ""); style-src 'unsafe-inline'; font-src data:; base-uri 'none'; form-action 'none'"
    }

    static func rules(externalImages: Bool) -> String {
        // WebKit's restricted regex syntax does not support alternation; keep schemes separate.
        // The blanket block also matches about:blank, used by loadHTMLString(baseURL: nil).
        // Allow only that exact document URL; the navigation delegate still controls main-frame loads.
        let remote = externalImages ? #",{"trigger":{"url-filter":"^https://","resource-type":["image"]},"action":{"type":"ignore-previous-rules"}}"# : ""
        return #"""
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
        {"trigger":{"url-filter":"^about:blank$","resource-type":["document"]},"action":{"type":"ignore-previous-rules"}},
        {"trigger":{"url-filter":"^cid:","resource-type":["image","font"]},"action":{"type":"ignore-previous-rules"}},
        {"trigger":{"url-filter":"^niu-mail-cid:","resource-type":["image","font"]},"action":{"type":"ignore-previous-rules"}},
        {"trigger":{"url-filter":"^data:","resource-type":["image","font"]},"action":{"type":"ignore-previous-rules"}}
        """# + remote + "]"
    }

    static func navigation(_ url: URL?, userActivated: Bool, initialLoad: Bool, mainFrame: Bool) -> MailHTMLNavigation {
        guard let url else { return .cancel }
        if initialLoad && mainFrame && !userActivated && url.absoluteString == "about:blank" { return .initial }
        guard userActivated else { return .cancel }
        switch url.scheme?.lowercased() {
        case "https", "http": return .external(url)
        case "mailto":
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return .cancel }
            let to = ([components.path] + (components.queryItems ?? []).filter { $0.name.lowercased() == "to" }.compactMap(\.value))
                .filter { !$0.isEmpty }.joined(separator: ", ")
            let subject = components.queryItems?.first { $0.name.lowercased() == "subject" }?.value ?? ""
            guard !to.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !subject.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return .cancel }
            return .compose(to: to, subject: subject)
        default: return .cancel
        }
    }

    @concurrent static func prepare(_ html: String, images: [MailAttachmentInfo]) async throws -> MailHTMLDocument {
        try Task.checkCancellation()
        let result = try sanitize(html, images: images)
        try Task.checkCancellation()
        return result
    }

    static func sanitize(_ html: String, images: [MailAttachmentInfo]) throws -> MailHTMLDocument {
        guard html.utf8.count <= 2 * 1024 * 1024 else { throw NativeMailError.tooLarge }
        let document = try SwiftSoup.parse(html)
        // All link elements are removed: remote stylesheets, prefetch and DNS hints included.
        try document.select("script,iframe,frame,frameset,object,embed,form,input,button,textarea,select,meta,base,link,video,audio,source,track,svg,math").remove()
        var referenced = Set<String>()
        var external = false
        var ownColors = false
        var ids: [String: String] = [:]
        for item in images {
            if let cid = item.contentID { ids[cid.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))] = item.id }
        }
        let cidPattern = try NSRegularExpression(pattern: #"(?i)cid:([^\s\"'<>\)]+)"#)
        func rewrite(_ value: String) -> String {
            var result = value
            for match in cidPattern.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
                guard let range = Range(match.range, in: result), let cidRange = Range(match.range(at: 1), in: value) else { continue }
                let cid = String(value[cidRange]).removingPercentEncoding ?? String(value[cidRange])
                var replacement = "about:blank"
                if let part = ids[cid] {
                    referenced.insert(part)
                    var url = URLComponents(); url.scheme = scheme; url.host = "part"; url.path = "/" + part
                    replacement = url.string ?? "about:blank"
                }
                result.replaceSubrange(range, with: replacement)
            }
            return result.replacingOccurrences(of: #"(?i)(url\(\s*["']?)//"#, with: "$1https://", options: .regularExpression)
        }
        func remote(_ value: String) -> Bool {
            value.range(of: #"(?i)(https?://|//)"#, options: .regularExpression) != nil
        }
        func colored(_ value: String) -> Bool {
            value.range(of: #"(?i)(^|[;{\s])(background(?:-color)?|color)\s*:"#, options: .regularExpression) != nil
        }
        for element in try document.select("*").array() {
            try Task.checkCancellation()
            for attribute in element.getAttributes()?.asList() ?? [] {
                let key = attribute.getKey().lowercased(), value = attribute.getValue()
                let compact = value.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }
                let normalized = String(String.UnicodeScalarView(compact)).lowercased()
                if key.hasPrefix("on") || ["srcdoc", "srcset", "ping", "autofocus", "autoplay"].contains(key) ||
                    normalized.hasPrefix("javascript:") || normalized.hasPrefix("vbscript:") || normalized.hasPrefix("data:text/html") {
                    try element.removeAttr(key); continue
                }
                if key == "style" {
                    external = external || (value.lowercased().contains("url") && remote(value))
                    ownColors = ownColors || colored(value)
                    try element.attr(key, rewrite(value))
                } else if key == "background" || (element.tagName() == "img" && key == "src") {
                    external = external || remote(value)
                    let source = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    try element.attr(key, rewrite(source.hasPrefix("//") ? "https:" + source : source))
                }
                if ["body", "table", "td"].contains(element.tagName()) && ["bgcolor", "text"].contains(key) { ownColors = true }
            }
            if element.tagName() == "style" {
                let css = try element.html()
                external = external || (css.lowercased().contains("url") && remote(css))
                ownColors = ownColors || colored(css)
                try element.html(rewrite(css))
            }
        }
        // An unguessable comment lets presentation add CSP first, without parsing on the main actor.
        let token = "<!--niu-head-\(UUID().uuidString)-->"
        try document.head()?.prepend(token)
        return MailHTMLDocument(markup: try document.outerHtml(), insertionToken: token,
                                hasExternalImages: external, referencedParts: referenced, hasOwnColors: ownColors)
    }
}
