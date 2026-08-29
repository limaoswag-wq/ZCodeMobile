import SwiftUI
import WebKit

/// 官方网页远控容器：直接加载 remote/v4 链接，界面原汁原味。
struct RemoteWebView: UIViewRepresentable {
    let url: URL
    @Binding var reloadToken: Int

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.webView = webView
        context.coordinator.lastURL = url
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastURL != url {
            context.coordinator.lastURL = url
            webView.load(URLRequest(url: url))
            return
        }
        if context.coordinator.lastReload != reloadToken {
            context.coordinator.lastReload = reloadToken
            webView.reload()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var webView: WKWebView?
        var lastURL: URL?
        var lastReload = 0

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            webView.scrollView.backgroundColor = .systemBackground
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            // 官方页面自带错误/重连 UI，这里不额外盖层。
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(.allow)
        }
    }
}
