import SwiftUI
import UIKit

struct RootView: View {
    @ObservedObject var client: BridgeClient
    @State private var showSettings = false
    @State private var showTasks = false
    @State private var showScanner = false
    @State private var showPaste = false

    var body: some View {
        ZStack {
            ZTheme.canvas.ignoresSafeArea()
            ZTheme.wash.ignoresSafeArea()
            ChatHost(
                client: client,
                onSettings: { showSettings = true },
                onTasks: { showTasks = true },
                onScan: { showScanner = true },
                onPaste: { showPaste = true }
            )
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(client: client)
        }
        .sheet(isPresented: $showTasks) {
            TaskListView(client: client)
        }
        .sheet(isPresented: $showScanner) {
            QRScannerHost(
                onScan: { value in
                    showScanner = false
                    client.connectFromScan(value)
                },
                onCancel: { showScanner = false }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showPaste) {
            PasteLinkView(client: client)
        }
    }
}

struct ChatHost: UIViewControllerRepresentable {
    @ObservedObject var client: BridgeClient
    var onSettings: () -> Void
    var onTasks: () -> Void
    var onScan: () -> Void
    var onPaste: () -> Void

    func makeUIViewController(context: Context) -> ChatViewController {
        let controller = ChatViewController()
        controller.client = client
        controller.onOpenSettings = onSettings
        controller.onOpenTasks = onTasks
        controller.onScan = onScan
        controller.onPaste = onPaste
        context.coordinator.controller = controller
        return controller
    }

    func updateUIViewController(_ uiViewController: ChatViewController, context: Context) {
        uiViewController.client = client
        uiViewController.onOpenSettings = onSettings
        uiViewController.onOpenTasks = onTasks
        uiViewController.onScan = onScan
        uiViewController.onPaste = onPaste
        uiViewController.reloadFromClient()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var controller: ChatViewController?
    }
}

struct PasteLinkView: View {
    @ObservedObject var client: BridgeClient
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        NavigationView {
            ZStack {
                ZTheme.canvas.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 16) {
                    Text("粘贴电脑 ZCode 复制出来的远控地址，例如 https://zcode.z.ai/remote/v4?sid=...")
                        .font(.system(size: 14))
                        .foregroundStyle(ZTheme.inkSoft)
                    TextEditor(text: $draft)
                        .font(.system(size: 14, design: .monospaced))
                        .padding(12)
                        .frame(minHeight: 140)
                        .background(ZTheme.cream)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    if let error = client.errorText, !error.isEmpty {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    PillButton(title: "连接", systemName: "link") {
                        client.connectFromText(draft)
                        if OfficialLinkParser.parse(draft) != nil {
                            dismiss()
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("粘贴远控地址")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                if draft.isEmpty { draft = client.pasteDraft }
            }
        }
    }
}

struct TaskListView: View {
    @ObservedObject var client: BridgeClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ZStack {
                ZTheme.canvas.ignoresSafeArea()
                if client.snapshot.tasks.isEmpty {
                    VStack(spacing: 10) {
                        Text(client.connection.isConnected ? "这个窗口还没有任务" : "连接后再看任务")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(ZTheme.ink)
                        Text("先扫描电脑上的远控二维码。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(client.snapshot.tasks) { task in
                                Button {
                                    Task {
                                        await client.openTask(task.id)
                                        dismiss()
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        Circle()
                                            .fill(task.isRunning ? ZTheme.accent : Color.secondary.opacity(0.35))
                                            .frame(width: 10, height: 10)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(task.title.isEmpty ? "未命名任务" : task.title)
                                                .font(.system(size: 16, weight: .semibold))
                                                .foregroundStyle(ZTheme.ink)
                                                .lineLimit(2)
                                            Text("\(task.statusLabel) · \(task.mode ?? "build")")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if task.id == client.snapshot.currentTaskId {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(ZTheme.accent)
                                        }
                                    }
                                    .padding(16)
                                    .background(ZTheme.cream)
                                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                                            .stroke(Color.white.opacity(0.5), lineWidth: 0.7)
                                    )
                                }
                                .buttonStyle(PressScaleStyle())
                            }
                        }
                        .padding(18)
                    }
                }
            }
            .navigationTitle("任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await client.newTask() }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(ZTheme.accent)
                    }
                    .disabled(!client.connection.isConnected)
                }
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var client: BridgeClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack {
                        Circle()
                            .fill(client.connection.isConnected ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(client.connection.label)
                        Spacer()
                        Text(client.snapshot.health.workspace ?? client.deviceTitle)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if client.isOfficialConnected {
                        Button("断开远控", role: .destructive) {
                            client.disconnectOfficial()
                        }
                    }
                } header: {
                    Text("状态")
                }

                Section {
                    Text("扫描电脑 ZCode「移动端远程控制」里的二维码，或把复制的地址粘贴到这里。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $client.pasteDraft)
                        .frame(minHeight: 88)
                        .font(.system(size: 13, design: .monospaced))
                    Button("用这个地址连接") {
                        client.connectFromText(client.pasteDraft)
                    }
                } header: {
                    Text("官方远控")
                } footer: {
                    Text("连上的是当前桌面窗口，不是把网页嵌进 App。同一时间只能有一个手机端占用这个二维码。")
                }

                Section {
                    TextField("电脑 IP 或主机名", text: $client.settings.host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                    TextField("端口", text: $client.settings.port)
                        .keyboardType(.numberPad)
                    SecureField("配对令牌", text: $client.settings.token)
                    Button("连接局域网桥") { client.pollNow() }
                } header: {
                    Text("电脑桥接（可选）")
                } footer: {
                    Text("扫码连不上发消息时，可以再开电脑上的 bridge/zcode_bridge.py，用局域网同步聊天记录。")
                }

                Section {
                    Toggle("App 横幅通知", isOn: .constant(true))
                        .disabled(true)
                        .foregroundStyle(.secondary)
                    Toggle("Bark 远程推送", isOn: $client.settings.barkEnabled)
                        .onChange(of: client.settings.barkEnabled) { _ in
                            Task { await client.syncBark() }
                        }
                    if client.settings.barkEnabled {
                        TextField("Bark URL", text: $client.settings.barkURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .onChange(of: client.settings.barkURL) { _ in
                                Task { await client.syncBark() }
                            }
                    }
                    Toggle("后台保活（静音播放）", isOn: $client.settings.keepAlive)
                        .onChange(of: client.settings.keepAlive) { value in
                            if value { SilentAudio.shared.start() } else { SilentAudio.shared.stop() }
                        }
                } header: {
                    Text("通知")
                } footer: {
                    Text("任务完成时默认用系统横幅。Bark 关掉就只走 App 自己的通知；打开后电脑还会再推一条到 Bark。")
                }

                Section {
                    Toggle("显示思考过程", isOn: $client.settings.showReasoning)
                    Button("停止当前任务") {
                        Task { await client.stopTask() }
                    }
                    Button("新建任务") {
                        Task { await client.newTask() }
                    }
                } header: {
                    Text("会话")
                }

                if let error = client.errorText, !error.isEmpty {
                    Section("最近错误") {
                        Text(error).foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
