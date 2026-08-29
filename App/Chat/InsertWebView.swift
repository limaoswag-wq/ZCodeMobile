import UIKit
import WebKit

final class InsertWebView: UIView, WKScriptMessageHandler, WKNavigationDelegate {
    var onHeightChange: ((CGFloat) -> Void)?

    private var webView: WKWebView!
    private var lastHTML = ""
    private var heightConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let controller = WKUserContentController()
        controller.add(self, name: "zcodeBridge")
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        heightConstraint = webView.heightAnchor.constraint(equalToConstant: 160)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightConstraint!
        ])
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    func render(code: String, language: String, dark: Bool) {
        let html = Self.html(code: code, language: language, dark: dark)
        guard html != lastHTML else { return }
        lastHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let height = body["height"] as? CGFloat else { return }
        let clamped = min(max(height, 80), 520)
        heightConstraint?.constant = clamped
        onHeightChange?(clamped)
    }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "zcodeBridge")
    }

    private static func html(code: String, language: String, dark: Bool) -> String {
        let escaped = code
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let bg = dark ? "#1f1914" : "#f3e8d8"
        let fg = dark ? "#f4eadc" : "#6b3d24"
        if language.lowercased() == "mermaid" {
            return """
            <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
            <style>body{margin:8px;background:\(bg);color:\(fg);font:14px -apple-system;}</style>
            <script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
            </head><body>
            <div class="mermaid">\(code.replacingOccurrences(of: "<", with: "&lt;"))</div>
            <script>
            mermaid.initialize({startOnLoad:true, theme:'\(dark ? "dark" : "neutral")'});
            function report(){const h=Math.ceil(document.body.scrollHeight);
              window.webkit.messageHandlers.zcodeBridge.postMessage({height:h});}
            setTimeout(report, 400); setTimeout(report, 1200);
            </script></body></html>
            """
        }
        return """
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        body{margin:0;background:\(bg);color:\(fg);}
        pre{margin:0;padding:12px;overflow:auto;font:12.5px ui-monospace, Menlo, monospace;line-height:1.45;}
        </style></head><body><pre>\(escaped)</pre>
        <script>
        function report(){const h=Math.ceil(document.body.scrollHeight);
          window.webkit.messageHandlers.zcodeBridge.postMessage({height:h});}
        report(); setTimeout(report, 200);
        </script></body></html>
        """
    }
}

final class WebCell: UITableViewCell {
    static let id = "web"
    let insert = InsertWebView()
    var onHeightChange: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        insert.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(insert)
        NSLayoutConstraint.activate([
            insert.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            insert.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            insert.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            insert.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6)
        ])
        insert.onHeightChange = { [weak self] _ in self?.onHeightChange?() }
    }

    required init?(coder: NSCoder) { nil }

    func configure(code: String, language: String, trait: UITraitCollection) {
        insert.render(code: code, language: language, dark: trait.userInterfaceStyle == .dark)
    }
}
