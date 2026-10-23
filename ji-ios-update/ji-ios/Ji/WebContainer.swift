import SwiftUI
import UIKit
import WebKit

struct WebContainer: UIViewRepresentable {
    func makeCoordinator() -> Bridge { Bridge() }

    func makeUIView(context: Context) -> WKWebView {
        let bridge = context.coordinator

        let userContent = WKUserContentController()
        var start = BridgeScript.start
        if let backup = Store.backupJSON() {
            // 只有 localStorage 为空时才会真正恢复（见 BridgeScript）
            start = "window.__JI_BACKUP__=" + backup + ";\n" + start
        }
        userContent.addUserScript(WKUserScript(source: start, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        userContent.addUserScript(WKUserScript(source: BridgeScript.end, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        userContent.add(bridge, name: "ji")

        let config = WKWebViewConfiguration()
        config.userContentController = userContent
        // 自定义协议 ji://app/ ：给网页一个固定不变的来源，localStorage 不会因为路径变化丢失
        config.setURLSchemeHandler(AppSchemeHandler(), forURLScheme: "ji")
        config.allowsInlineMediaPlayback = true
        config.dataDetectorTypes = []

        let web = JiWebView(frame: .zero, configuration: config)
        web.navigationDelegate = bridge
        web.uiDelegate = bridge
        bridge.web = web

        web.isOpaque = false
        web.backgroundColor = UIColor(red: 238 / 255, green: 237 / 255, blue: 231 / 255, alpha: 1)
        web.scrollView.backgroundColor = web.backgroundColor
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.bounces = false
        web.scrollView.keyboardDismissMode = .interactive
        web.scrollView.minimumZoomScale = 1
        web.scrollView.maximumZoomScale = 1
        web.allowsLinkPreview = false
        web.allowsBackForwardNavigationGestures = false
        #if DEBUG
        if #available(iOS 16.4, *) { web.isInspectable = true }
        #endif

        web.load(URLRequest(url: AppSchemeHandler.homeURL))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// 安全区变化时把数值告诉网页（网页自己的 env() 失效时作为兜底）
final class JiWebView: WKWebView {
    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        let i = safeAreaInsets
        evaluateJavaScript("window.__jiInsets&&window.__jiInsets(\(i.top),\(i.bottom))", completionHandler: nil)
    }
}

/// 网页 <-> 原生 的桥
final class Bridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    weak var web: WKWebView?

    // MARK: 网页发来的消息
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        let id = (body["id"] as? NSNumber)?.intValue ?? 0

        switch cmd {
        case "persist":
            if let json = body["data"] as? String { Store.writeBackup(json) }
        case "haptic":
            Haptics.fire(body["style"] as? String ?? "light")
        case "share":
            Sharer.present(name: body["name"] as? String,
                           b64: body["b64"] as? String,
                           text: body["text"] as? String) { [weak self] in
                self?.resolve(id, "ok")
            }
        case "photoSave":
            let pid = body["pid"] as? String ?? ""
            let b64 = body["b64"] as? String ?? ""
            Photos.save(id: pid, b64: b64) { [weak self] ok in self?.resolve(id, ok ? "ok" : "err") }
        case "photoGC":
            if let keep = body["keep"] as? [String], !keep.isEmpty { Photos.collectGarbage(keep: Set(keep)) }
        case "notifyAuth":
            Notifier.requestAuth { [weak self] status in
                DispatchQueue.main.async {
                    self?.resolve(id, status)
                    self?.setPerm(status)
                }
            }
        case "schedule":
            if let items = body["items"] as? [[String: Any]] { Notifier.sync(items) }
        default:
            break
        }
    }

    private func resolve(_ id: Int, _ value: String) {
        DispatchQueue.main.async { [weak self] in
            self?.web?.evaluateJavaScript("window.__jiResolve&&window.__jiResolve(\(id),'\(value)')", completionHandler: nil)
        }
    }

    private func setPerm(_ status: String) {
        DispatchQueue.main.async { [weak self] in
            self?.web?.evaluateJavaScript("window.__jiPerm&&window.__jiPerm('\(status)')", completionHandler: nil)
        }
    }

    // MARK: 导航
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme ?? ""
        if ["ji", "about", "blob", "data"].contains(scheme) {
            decisionHandler(.allow)
        } else {
            if ["http", "https", "tel", "mailto"].contains(scheme) { UIApplication.shared.open(url) }
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Notifier.status { [weak self] status in self?.setPerm(status) }
        let i = webView.safeAreaInsets
        webView.evaluateJavaScript("window.__jiInsets&&window.__jiInsets(\(i.top),\(i.bottom))", completionHandler: nil)
    }

    // 网页进程被系统回收时自动重新载入
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.load(URLRequest(url: AppSchemeHandler.homeURL))
    }

    // MARK: JS 弹窗（网页本身用自定义弹窗，这里只是兜底）
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        guard let top = Sharer.topController() else { completionHandler(); return }
        top.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        guard let top = Sharer.topController() else { completionHandler(false); return }
        top.present(alert, animated: true)
    }
}
