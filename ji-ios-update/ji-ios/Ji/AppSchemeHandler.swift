import Foundation
import WebKit

/// 把 App 包里的网页文件、以及照片文件，通过 ji://app/ 提供给 WKWebView
final class AppSchemeHandler: NSObject, WKURLSchemeHandler {
    static let homeURL = URL(string: "ji://app/index.html")!

    private static let mimeTypes: [String: String] = [
        "html": "text/html", "js": "text/javascript", "css": "text/css",
        "png": "image/png", "jpg": "image/jpeg", "svg": "image/svg+xml",
        "json": "application/json", "webmanifest": "application/manifest+json"
    ]

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        let fileName = (path as NSString).lastPathComponent
        let ext = (fileName as NSString).pathExtension
        let base = (fileName as NSString).deletingPathExtension

        // 照片：ji://app/photo/<id>.jpg（文件名内容即哈希，可以长期缓存）
        if path.hasPrefix("/photo/") {
            if Photos.valid(base), let data = try? Data(contentsOf: Photos.fileURL(base)) {
                respond(urlSchemeTask, url, 200, "image/jpeg", data, cache: "public, max-age=31536000, immutable")
            } else {
                respond(urlSchemeTask, url, 404, "text/plain", Data(), cache: "no-store")
            }
            return
        }

        guard let file = Bundle.main.url(forResource: base, withExtension: ext),
              let data = try? Data(contentsOf: file) else {
            respond(urlSchemeTask, url, 404, "text/plain", Data(), cache: "no-store")
            return
        }
        respond(urlSchemeTask, url, 200, Self.mimeTypes[ext] ?? "application/octet-stream", data, cache: "no-store")
    }

    private func respond(_ task: WKURLSchemeTask, _ url: URL, _ status: Int, _ mime: String, _ data: Data, cache: String) {
        let headers = [
            "Content-Type": "\(mime); charset=utf-8",
            "Content-Length": "\(data.count)",
            "Cache-Control": cache
        ]
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
