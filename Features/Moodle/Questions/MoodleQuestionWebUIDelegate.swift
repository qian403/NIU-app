import UIKit
import WebKit

/// Keeps JavaScript submission confirmations interactive inside the activity.
@MainActor
final class MoodleQuestionWebUIDelegate: NSObject, WKUIDelegate {
    private weak var presentedAlert: UIAlertController?
    private var pendingReply: ((String?) -> Void)?
    private var dialogID: UUID?

    func cancel() {
        let reply = pendingReply
        pendingReply = nil
        dialogID = nil
        presentedAlert?.dismiss(animated: false)
        presentedAlert = nil
        reply?(nil)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        present(in: webView, message: message, allowsCancel: false) { _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        present(in: webView, message: message, allowsCancel: true) { completionHandler($0 != nil) }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        present(in: webView, message: prompt, allowsCancel: true,
                input: defaultText ?? "", completion: completionHandler)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              let scheme = navigationAction.request.url?.scheme?.lowercased(),
              ["https", "http"].contains(scheme) else { return nil }
        webView.load(navigationAction.request)
        return nil
    }

    private func present(
        in webView: WKWebView,
        message: String,
        allowsCancel: Bool,
        input: String? = nil,
        completion: @escaping (String?) -> Void
    ) {
        guard pendingReply == nil, var presenter = webView.window?.rootViewController else {
            completion(nil)
            return
        }
        while let presented = presenter.presentedViewController { presenter = presented }
        guard !presenter.isBeingDismissed else {
            completion(nil)
            return
        }
        let id = UUID()
        let alert = UIAlertController(title: "M 園區", message: message, preferredStyle: .alert)
        if let input {
            alert.addTextField {
                $0.text = input
                $0.accessibilityLabel = message
            }
        }
        if allowsCancel {
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
                self?.complete(id: id, value: nil)
            })
        }
        alert.addAction(UIAlertAction(title: "確定", style: .default) { [weak self, weak alert] _ in
            self?.complete(id: id, value: alert?.textFields?.first?.text ?? "")
        })
        dialogID = id
        pendingReply = completion
        presentedAlert = alert
        presenter.present(alert, animated: true)
    }

    private func complete(id: UUID, value: String?) {
        guard id == dialogID else { return }
        let reply = pendingReply
        pendingReply = nil
        dialogID = nil
        presentedAlert = nil
        reply?(value)
    }
}
