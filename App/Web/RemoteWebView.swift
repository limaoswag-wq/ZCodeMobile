import SwiftUI
import WebKit

/// 官方网页远控容器：直接加载 remote/v4 链接，界面原汁原味。
struct RemoteWebView: UIViewRepresentable {
    let url: URL
    @Binding var reloadToken: Int
    @Binding var recoverToken: Int

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
            return
        }
        if context.coordinator.lastRecover != recoverToken {
            context.coordinator.lastRecover = recoverToken
            // 回前台稍等片刻：先给页面自己重连的机会，仍在接管/报错页才强制刷新。
            context.coordinator.scheduleRecoverIfKicked()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var webView: WKWebView?
        var lastURL: URL?
        var lastReload = 0
        var lastRecover = 0

        /// 官方页面被踢后停在「已被其他设备接管」终态，不会自愈；检测到就整页刷新重连。
        func scheduleRecoverIfKicked() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, let webView = self.webView else { return }
                let js = """
                (() => {
                  const t = document.body ? document.body.innerText : '';
                  if (t.includes('已被其他设备接管') || t.includes('KICKED') || t.includes('连接已断开') || t.includes('二维码失效')) return 'kicked';
                  return 'ok';
                })()
                """
                webView.evaluateJavaScript(js) { [weak self] result, _ in
                    guard let self, (result as? String) == "kicked", let webView = self.webView else { return }
                    webView.reload()
                }
            }
        }

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
