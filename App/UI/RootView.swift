import SwiftUI
import UIKit

struct RootView: View {
    @ObservedObject var app: AppState
    @State private var showSettings = false
    @State private var showScanner = false
    @State private var showSidebar = false
    @State private var showModelMenu = false
    @State private var showAttach = false

    var body: some View {
        ZStack {
            ZTheme.canvas.ignoresSafeArea()
            if app.hasLink {
                ChatHost(
                    app: app,
                    onOpenSidebar: { showSidebar = true },
                    onBack: {
                        app.startNewChat()
                    },
                    onOpenModelMenu: {
                        app.fetchProviders()
                        showModelMenu = true
                    },
                    onNewChat: {
                        app.startNewChat()
                    },
                    onOpenAttach: { showAttach = true }
                )
                .ignoresSafeArea(.keyboard, edges: .bottom)
            } else {
                ConnectView(app: app, onScan: { showScanner = true })
            }

            if let toast = app.toast, !toast.isEmpty {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.75), in: Capsule())
                        .padding(.bottom, 110)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            if showModelMenu {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { showModelMenu = false }
                ModelPopover(app: app, onDismiss: { showModelMenu = false })
                    .frame(width: 268)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, 56)
                    .padding(.top, 58)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.16), value: showModelMenu)
        .overlay {
            if showSidebar, app.hasLink {
                SideBarDim(showSidebar: $showSidebar)
                SidebarDrawer(
                    app: app,
                    isShown: $showSidebar,
                    onScan: { showScanner = true },
                    onSettings: { showSettings = true }
                )
            }
        }
        .animation(.easeOut(duration: 0.22), value: showSidebar)
        .sheet(isPresented: $showScanner) {
            QRScannerHost(
                onScan: { value in
                    showScanner = false
                    app.connect(from: value.trimmingCharacters(in: .whitespacesAndNewlines))
                },
                onCancel: { showScanner = false }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(app: app)
        }
        .sheet(isPresented: $showAttach) {
            AttachSheet()
        }
        .onChange(of: showModelMenu) { shown in
            if shown { app.fetchProviders() }
        }
    }
}

private struct SideBarDim: View {
    @Binding var showSidebar: Bool

    var body: some View {
        Color.black.opacity(0.38)
            .ignoresSafeArea()
            .onTapGesture { showSidebar = false }
            .transition(.opacity)
    }
}

// MARK: - 连接页（冷色极简）

struct ConnectView: View {
    @ObservedObject var app: AppState
    var onScan: () -> Void
    @State private var paste = ""
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            Text("Z")
                .font(.system(size: 34, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 76, height: 76)
                .background(ZTheme.ink, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            Text("ZCode 远程控制")
                .font(.system(size: 21, weight: .bold))
                .padding(.top, 20)
            Text("扫描电脑端「移动端远程控制」二维码，或粘贴复制的链接。连接后就是原生界面，任务完成会弹通知。")
                .font(.system(size: 13.5))
                .foregroundStyle(ZTheme.inkSoft)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, 34)
            Spacer(minLength: 10)

            VStack(spacing: 12) {
                Button(action: onScan) {
                    Label("扫描二维码连接", systemImage: "qrcode.viewfinder")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(ZTheme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                HStack(spacing: 10) {
                    TextField("https://zcode.z.ai/remote/v4?sid=…", text: $paste)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 13, design: .monospaced))
                    Button("连接") {
                        let trimmed = paste.trimmingCharacters(in: .whitespacesAndNewlines)
                        if OfficialLinkParser.parse(trimmed) != nil {
                            errorText = nil
                            app.connect(from: trimmed)
                        } else {
                            errorText = "这不是 ZCode 远控链接，请检查后重试。"
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                if let errorText, !errorText.isEmpty {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(ZTheme.danger)
                }
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 16)
            Text("Bark 推送可在连接后的设置里打开。")
                .font(.caption2)
                .foregroundStyle(ZTheme.inkFaint)
                .padding(.bottom, 18)
        }
        .onAppear { paste = app.settings.officialURL }
    }
}

// MARK: - 聊天宿主

struct ChatHost: UIViewControllerRepresentable {
    @ObservedObject var app: AppState
    var onOpenSidebar: () -> Void
    var onBack: () -> Void
    var onOpenModelMenu: () -> Void
    var onNewChat: () -> Void
    var onOpenAttach: () -> Void

    func makeUIViewController(context: Context) -> ChatViewController {
        let controller = ChatViewController()
        controller.app = app
        controller.onOpenSidebar = onOpenSidebar
        controller.onBack = onBack
        controller.onOpenModelMenu = onOpenModelMenu
        controller.onNewChat = onNewChat
        controller.onOpenAttach = onOpenAttach
        context.coordinator.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: ChatViewController, context: Context) {
        controller.app = app
        controller.onOpenSidebar = onOpenSidebar
        controller.onBack = onBack
        controller.onOpenModelMenu = onOpenModelMenu
        controller.onNewChat = onNewChat
        controller.onOpenAttach = onOpenAttach
        controller.reloadFromApp()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var controller: ChatViewController?
    }
}

// MARK: - 侧边栏

struct SidebarDrawer: View {
    @ObservedObject var app: AppState
    @Binding var isShown: Bool
    var onScan: () -> Void
    var onSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            drawer
                .frame(width: 300)
                .background(ZTheme.canvas)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 26, topTrailingRadius: 26))
                .shadow(color: .black.opacity(0.18), radius: 24, x: 6, y: 0)
            Spacer(minLength: 0)
        }
        .transition(.move(edge: .leading))
    }

    private var pinned: [TaskSummary] { app.tasks.filter(\.pinned) }
    private var history: [TaskSummary] { app.tasks.filter { !$0.pinned } }

    private var drawer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("R")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(ZTheme.accent, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.deviceName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(ZTheme.ink)
                    HStack(spacing: 5) {
                        Circle().fill(app.connection.isConnected ? ZTheme.ok : ZTheme.danger).frame(width: 7, height: 7)
                        Text(app.connection.label)
                            .font(.system(size: 11.5))
                            .foregroundStyle(ZTheme.inkSoft)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 14)

            Button {
                app.startNewChat()
                isShown = false
            } label: {
                Label("新对话", systemImage: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ZTheme.accent)
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .background(ZTheme.accentWeak, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .padding(.horizontal, 14)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if !pinned.isEmpty {
                        sectionTitle("已置顶")
                        ForEach(pinned) { task in
                            taskRow(task)
                        }
                    }
                    sectionTitle("历史会话")
                    if history.isEmpty {
                        Text(app.connection.isConnected ? "还没有任务" : "连接后再看任务")
                            .font(.system(size: 12.5))
                            .foregroundStyle(ZTheme.inkFaint)
                            .padding(.horizontal, 16)
                            .padding(.top, 6)
                    }
                    ForEach(history) { task in
                        taskRow(task)
                    }
                }
                .padding(.top, 4)
            }

            HStack(spacing: 10) {
                drawerButton("扫码连接", symbol: "qrcode.viewfinder") {
                    isShown = false
                    app.disconnect()
                    onScan()
                }
                drawerButton("设置", symbol: "gearshape") {
                    isShown = false
                    onSettings()
                }
            }
            .padding(14)
        }
        .padding(.top, 44)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(ZTheme.inkFaint)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    private func taskRow(_ task: TaskSummary) -> some View {
        let badge = ZTheme.statusBadge(task.status)
        return Button {
            app.openTask(task.id)
            isShown = false
        } label: {
            HStack(spacing: 8) {
                Text(task.title.isEmpty ? "未命名任务" : task.title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(ZTheme.ink)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if !task.title.isEmpty {
                    Text(TimeFormat.relative(task.updatedAt))
                        .font(.system(size: 11))
                        .foregroundStyle(ZTheme.inkFaint)
                }
                Text(badge.text)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(badge.fg)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(badge.bg, in: Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(task.id == app.activeTaskId ? ZTheme.surface : .clear,
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .padding(.horizontal, 8)
    }

    private func drawerButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ZTheme.ink)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(ZTheme.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
    }
}

// MARK: - 附件面板

struct AttachSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Capsule()
                .fill(ZTheme.line)
                .frame(width: 40, height: 5)
                .padding(.top, 10)
            HStack(spacing: 12) {
                attachCell("拍照", symbol: "camera")
                attachCell("照片", symbol: "photo")
                attachCell("文件", symbol: "doc")
            }
            Text("附件上传将在下个版本支持，当前版本先出文字对话。")
                .font(.caption)
                .foregroundStyle(ZTheme.inkFaint)
            Spacer()
        }
        .padding(.horizontal, 16)
        .presentationDetents([.height(240)])
    }

    private func attachCell(_ title: String, symbol: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(ZTheme.ink)
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(ZTheme.ink)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(ZTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .opacity(0.55)
    }
}

// MARK: - 设置

struct SettingsSheet: View {
    @ObservedObject var app: AppState
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    init(app: AppState) {
        self.app = app
        self.settings = app.settings
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("设备", value: app.deviceName)
                    LabeledContent("状态", value: app.connection.label)
                    Button(role: .destructive) {
                        app.disconnect()
                        dismiss()
                    } label: {
                        Label("断开连接，重新扫码", systemImage: "link.badge.plus")
                    }
                } header: {
                    Text("连接")
                }

                Section {
                    Toggle("Bark 推送", isOn: $settings.barkEnabled)
                    if settings.barkEnabled {
                        TextField("https://api.day.app/你的Key", text: $settings.barkURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("通知")
                } footer: {
                    Text("任务完成/出错弹 App 通知；打开 Bark 会同时推送到手机 Bark。")
                }

                Section {
                    Toggle("后台保活（静音播放）", isOn: $settings.keepAlive)
                } header: {
                    Text("后台")
                } footer: {
                    Text("退到后台时静音播放保持通知可靠。")
                }

                Section {
                    LabeledContent("版本", value: "1.2.0")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - 模型弹层（设计稿⑤：锚在模型胶囊下方的浮层卡片）

struct ModelPopover: View {
    @ObservedObject var app: AppState
    var onDismiss: () -> Void
    @State private var thoughtExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(app.providers.enumerated()), id: \.element.id) { index, provider in
                        if index > 0 {
                            Rectangle().fill(ZTheme.line).frame(height: 0.7)
                                .padding(.horizontal, 14)
                        }
                        ForEach(provider.models) { model in
                            row(
                                primary: model.name,
                                selected: provider.id == app.selectedProviderId &&
                                    (model.id == app.selectedModelId || model.name == app.selectedModelId)
                            ) {
                                app.switchModel(providerId: provider.id, modelId: model.id, thought: app.selectedThought)
                                onDismiss()
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 300)

            Rectangle().fill(ZTheme.line).frame(height: 0.7)

            Button {
                withAnimation(.easeOut(duration: 0.16)) { thoughtExpanded.toggle() }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("思考等级")
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(ZTheme.ink)
                        Text(app.selectedThought)
                            .font(.system(size: 11.5))
                            .foregroundStyle(ZTheme.inkSoft)
                    }
                    Spacer()
                    Image(systemName: thoughtExpanded ? "chevron.up" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ZTheme.inkFaint)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if thoughtExpanded {
                VStack(spacing: 0) {
                    ForEach(["低", "中", "高", "极高"], id: \.self) { level in
                        Button {
                            if let provider = app.providers.first(where: { $0.id == app.selectedProviderId }) {
                                app.switchModel(providerId: provider.id, modelId: app.selectedModelId, thought: level)
                            }
                            onDismiss()
                        } label: {
                            HStack {
                                Text(level)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(ZTheme.ink)
                                Spacer()
                                if level == app.selectedThought {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(ZTheme.accent)
                                }
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 40)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 6)
            }
        }
        .background(ZTheme.canvas, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ZTheme.line, lineWidth: 0.7)
        )
        .shadow(color: .black.opacity(0.14), radius: 22, y: 8)
        .onAppear { autoResolveProvider() }
    }

    private func autoResolveProvider() {
        guard !app.providers.isEmpty else { return }
        if app.providers.contains(where: { $0.id == app.selectedProviderId }) { return }
        let containing = app.providers.filter { p in
            p.models.contains { $0.id == app.selectedModelId || $0.name == app.selectedModelId }
        }
        let picked = containing.first { $0.id.lowercased().contains("zai") } ?? containing.first
        if let picked { app.selectedProviderId = picked.id }
    }

    private func row(primary: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(primary)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(ZTheme.ink)
                    .lineLimit(1)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ZTheme.accent)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension Notification.Name {
    static let zcodeOpenSettings = Notification.Name("zcode.openSettings")
}
