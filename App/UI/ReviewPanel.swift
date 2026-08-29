import SwiftUI
import WebKit

/// 侧边栏审查/打开页签：原生骨架 + 本地 HTML 渲染 diff/文件内容。
struct ReviewPanelDrawer: View {
    @ObservedObject var app: AppState
    @Binding var isShown: Bool

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            drawer
                .frame(width: 340)
                .background(Color(.systemBackground))
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 22, bottomTrailingRadius: 0, topTrailingRadius: 0))
                .shadow(color: .black.opacity(0.2), radius: 24, x: -6, y: 0)
        }
        .transition(.move(edge: .trailing))
    }

    private var drawer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    isShown = false
                } label: {
                    Label("收起侧边面板", systemImage: "chevron.right")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(ZTheme.inkSoft)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(app.panelTabs) { tab in
                        tabButton(tab)
                    }
                    Button {
                        app.showToast("新增标签（演示）")
                    } label: {
                        Text("＋")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(ZTheme.inkSoft)
                            .frame(width: 28, height: 28)
                            .background(ZTheme.chip, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.bottom, 8)

            if let tab = app.activePanelTab {
                ReviewCodeView(file: tab.file, mode: tab.mode)
            } else {
                Spacer()
                Text("没有打开的标签页")
                    .font(.footnote)
                    .foregroundStyle(ZTheme.inkFaint)
                Spacer()
            }
        }
        .padding(.top, 40)
    }

    private func tabButton(_ tab: AppState.PanelTab) -> some View {
        let name = tab.file.path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? tab.file.path
        let active = tab.id == app.activePanelTabId
        return Button {
            app.activePanelTabId = tab.id
        } label: {
            HStack(spacing: 5) {
                Text(name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 84, alignment: .leading)
                if tab.mode == "diff" {
                    Text("Diff")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(ZTheme.accent)
                }
                Button {
                    app.closePanelTab(tab.id)
                } label: {
                    Text("✕")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ZTheme.inkSoft)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(active ? ZTheme.accentWeak : ZTheme.chip,
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(active ? ZTheme.accent.opacity(0.4) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("关闭") { app.closePanelTab(tab.id) }
        }
    }
}

/// 内容区：本地生成 HTML，WKWebView 渲染（语法高亮模板随 App 内置）。
struct ReviewCodeView: UIViewRepresentable {
    let file: FileChangeInfo
    let mode: String

    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.isOpaque = false
        wv.backgroundColor = .systemBackground
        wv.scrollView.backgroundColor = .systemBackground
        return wv
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let html = DiffHTML.build(file: file, mode: mode)
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastHTML = ""
    }
}

enum DiffHTML {
    static func zh(_ status: String) -> String {
        status.hasPrefix("A") ? "新增" : status.hasPrefix("D") ? "删除" : "修改"
    }

    static func build(file: FileChangeInfo, mode: String) -> String {
        let dark = UITraitCollection.current.userInterfaceStyle == .dark
        let bg = dark ? "#111214" : "#ffffff"
        let ink = dark ? "#f2f3f5" : "#171719"
        let soft = dark ? "#8a8f98" : "#8a8f98"
        let line = dark ? "#2a2b30" : "#f0f0f2"
        let addBg = dark ? "#12271c" : "#e9f8ef"
        let addFg = dark ? "#7ee0a8" : "#157347"
        let delBg = dark ? "#2d1518" : "#fdeef0"
        let delFg = dark ? "#ff9aa1" : "#b3252e"
        let crumbs = file.path.split(whereSeparator: { $0 == "\\" || $0 == "/" })
        let crumb = crumbs.dropLast().joined(separator: " › ")
        let name = crumbs.last.map(String.init) ?? file.path
        let isDiff = mode == "diff"
        let body: String
        if isDiff {
            let lines = (file.content ?? "")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .prefix(200)
            if file.content?.isEmpty == false {
                body = lines.enumerated().map { index, line in
                    let cls: String
                    if line.hasPrefix("+") { cls = "add" }
                    else if line.hasPrefix("-") { cls = "del" }
                    else { cls = "ctx" }
                    let color = cls == "add" ? addFg : cls == "del" ? delFg : ink
                    let dlCls = cls == "ctx" ? "" : " " + cls
                    let bgStyle = cls == "add" ? " style=\"background:\(addBg)\"" : cls == "del" ? " style=\"background:\(delBg)\"" : ""
                    let n1 = "\(index + 1)"
                    let n2 = "\(index + 1)"
                    return "<div class=\"dl\(dlCls)\"\(bgStyle)><span class=\"n\">\(n1)</span><span class=\"n\">\(n2)</span><span class=\"c\" style=\"color:\(color)\">\(DiffHTML.escape(String(line)))</span></div>"
                }.joined()
            } else {
                body = "<div class=\"empty\">diff 内容暂未从桌面端取到（原始返回已记录到调试文件）。</div>"
            }
        } else {
            let lines = (file.content ?? "")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .prefix(200)
            if file.content?.isEmpty == false {
                body = lines.enumerated().map { index, line in
                    "<div class=\"dl\"><span class=\"n\">\(index + 1)</span><span class=\"c\" style=\"color:\(ink)\">\(DiffHTML.escape(String(line)))</span></div>"
                }.joined()
            } else {
                body = "<div class=\"empty\">文件内容暂未取到。可在电脑端打开该文件查看。</div>"
            }
        }
        let statAdd = file.additions > 0 ? "<span style=\"color:#22a06b;font-weight:600\">+\(file.additions)</span> " : ""
        let statDel = file.deletions > 0 ? "<span style=\"color:#e5484d;font-weight:600\">-\(file.deletions)</span>" : ""
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          body{background:\(bg);color:\(ink);font-family:-apple-system,"PingFang SC",system-ui,sans-serif;margin:0;padding:12px 0 30px}
          .crumb{font-size:11px;color:\(soft);padding:0 14px 6px}
          .crumb b{color:\(ink);font-weight:600}
          .actions{display:flex;gap:8px;padding:0 14px 10px}
          .actions span{border:1px solid \(line);border-radius:9px;padding:5px 10px;font-size:11.5px;font-weight:600;color:\(ink)}
          .actions .dis{color:#{GRAY}}
          .code{font-family:ui-monospace,Consolas,monospace;font-size:10.5px;line-height:2;border-top:1px solid \(line);padding-top:6px}
          .dl{display:flex}
          .dl .n{flex:0 0 26px;text-align:right;padding-right:7px;color:\(soft);opacity:.75;user-select:none}
          .dl .n2{flex:0 0 26px;text-align:right;padding-right:8px;color:\(soft);opacity:.75;border-right:1px solid \(line);margin-right:8px;user-select:none}
          .dl .c{flex:1;padding-right:10px;white-space:pre;word-break:break-all}
          .empty{padding:20px 14px;font-size:12.5px;color:\(soft)}
        </style></head><body>
        <div class="crumb">\(crumb) › <b>\(name)</b> &nbsp;\(statAdd)\(statDel) &nbsp;<span style="color:\(soft)">\(zh(file.status))</span></div>
        <div class="actions"><span>查看源码</span><span>更多</span><span class="dis">在编辑器中打开</span></div>
        <div class="code">\(body)</div>
        </body></html>
        """.replacingOccurrences(of: "#{GRAY}", with: soft)
    }

    /// 最小 HTML 转义。
    fileprivate static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
