import SwiftUI
import WebKit

enum WebMessage {
    case quote(String)
    case mention(String)
    case react(subjectID: String, content: String, remove: Bool)
    case open(URL)
}

/// Shows the rendered conversation. Links open in the browser (or in GitHub Triage when the thread is in the inbox).
struct ConversationWebView: NSViewRepresentable {
    var html: String
    /// Element ids to try scrolling to on first load, in order.
    var anchors: [String]
    var onMessage: (WebMessage) -> Void

    /// One in-memory store for every conversation, so avatars and images download once per session
    /// instead of once per thread. Nothing is written to disk.
    private static let dataStore = WKWebsiteDataStore.nonPersistent()

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "ght")
        config.websiteDataStore = Self.dataStore
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        web.allowsMagnification = true
        context.coordinator.web = web
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let c = context.coordinator
        c.onMessage = onMessage
        guard c.html != html else { return }
        let firstLoad = c.html == nil
        c.html = html
        if firstLoad {
            c.pendingScroll = .anchors(anchors)
            web.loadHTMLString(html, baseURL: URL(string: "https://github.com/"))
        } else {
            // A reload of the same thread (after a reply, a reaction…): keep the reader's place, or follow the end.
            web.evaluateJavaScript("[window.scrollY, window.innerHeight, document.documentElement.scrollHeight]") { result, _ in
                if let v = result as? [Double], v.count == 3 {
                    c.pendingScroll = v[0] + v[1] >= v[2] - 60 ? .bottom : .offset(v[0])
                } else {
                    c.pendingScroll = .none
                }
                web.loadHTMLString(html, baseURL: URL(string: "https://github.com/"))
            }
        }
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "ght")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        enum Scroll { case none, anchors([String]), offset(Double), bottom }
        var html: String?
        var pendingScroll: Scroll = .none
        var onMessage: ((WebMessage) -> Void)?
        weak var web: WKWebView?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let js: String
            switch pendingScroll {
            case .none: return
            case .anchors(let ids):
                let list = ids.map { "'\($0.replacingOccurrences(of: "'", with: ""))'" }.joined(separator: ",")
                js = "window.ghtScrollTo([\(list)])"
            case .offset(let y): js = "window.scrollTo(0, \(y))"
            case .bottom: js = "window.scrollTo(0, document.documentElement.scrollHeight)"
            }
            pendingScroll = .none
            webView.evaluateJavaScript(js)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .other, action.targetFrame?.isMainFrame == true, action.request.url?.absoluteString == "https://github.com/" {
                return .allow  // our own loadHTMLString
            }
            if let url = action.request.url, action.navigationType == .linkActivated || action.targetFrame == nil {
                if url.fragment != nil, url.absoluteString.hasPrefix("https://github.com/#") { return .allow }
                onMessage?(.open(url))
                return .cancel
            }
            return action.request.url?.scheme == "about" ? .allow : .cancel
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "quote":
                if let text = body["text"] as? String, !text.isEmpty { onMessage?(.quote(text)) }
            case "mention":
                if let login = body["login"] as? String { onMessage?(.mention(login)) }
            case "react":
                if let subject = body["subject"] as? String, let content = body["content"] as? String {
                    onMessage?(.react(subjectID: subject, content: content, remove: (body["remove"] as? Bool) ?? false))
                }
            default:
                break
            }
        }
    }
}
