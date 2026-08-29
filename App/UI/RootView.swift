import SwiftUI
import UIKit

struct RootView: View {
    @ObservedObject var settings: AppSettings
    @State private var showSettings = false
    @State private var showScanner = false
    @State private var reloadToken = 0

    private var activeLink: OfficialLink? {
        OfficialLinkParser.parse(settings.officialURL)
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            if let link = activeLink, let url = URL(string: settings.officialURL) {
                RemoteWebView(url: url, reloadToken: $reloadToken)
                floatingControls(link: link)
            } else {
                ConnectView(
                    settings: settings,
                    onScan: { showScanner = true },
                    onAlbum: { showScanner = true }
                )
            }
        }
        .sheet(isPresented: $showScanner) {
            QRScannerHost(
                onScan: { value in
                    showScanner = false
                    connect(from: value)
                },
                onCancel: { showScanner = false }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(settings: settings, onReload: {
                reloadToken += 1
            })
        }
    }

    /// 网页右上角旁的小齿轮，用来打开设置；不遮官方控件主区域。
    private func floatingControls(link: OfficialLink) -> some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(.thinMaterial, in: Circle())
                }
                .padding(.trailing, 66)
                .padding(.top, 2)
            }
            Spacer()
        }
    }

    private func connect(from raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let link = OfficialLinkParser.parse(trimmed) else {
            ConnectPasteError.shared.message = "这不是 ZCode 远控链接，请扫描电脑端二维码或粘贴完整链接。"
            return
        }
        settings.officialURL = trimmed
        MonitorController.shared.stop()
    }
}

enum ConnectPasteError {
    static let shared = PasteErrorBox()
}

final class PasteErrorBox: ObservableObject {
    @Published var message: String?
}

struct ConnectView: View {
    @ObservedObject var settings: AppSettings
    var onScan: () -> Void
    var onAlbum: () -> Void
    @State private var paste = ""
    @StateObject private var errorBox = ConnectPasteError.shared

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Image(systemName: "terminal.fill")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Color.white)
                .frame(width: 72, height: 72)
                .background(Color(.label), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text("ZCode 远程控制")
                .font(.system(size: 22, weight: .semibold))
                .padding(.top, 18)
            Text("扫描电脑端「移动端远程控制」二维码，或粘贴复制的链接。连接后就是官方原版界面；退到后台会自动监控任务并发通知。")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, 32)
            Spacer(minLength: 12)

            VStack(spacing: 12) {
                Button(action: onScan) {
                    Label("扫描二维码连接", systemImage: "qrcode.viewfinder")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                Button(action: onAlbum) {
                    Label("从相册识别", systemImage: "photo.on.rectangle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                            errorBox.message = nil
                            settings.officialURL = trimmed
                        } else {
                            errorBox.message = "这不是 ZCode 远控链接，请检查后重试。"
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                if let message = errorBox.message, !message.isEmpty {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 24)
            Text("任务完成或出错时会弹系统通知；Bark 推送可在设置里打开。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 16)
        }
        .onAppear {
            paste = settings.officialURL
        }
    }
}

struct SettingsSheet: View {
    @ObservedObject var settings: AppSettings
    var onReload: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var link: OfficialLink? { OfficialLinkParser.parse(settings.officialURL) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("设备", value: link?.deviceName ?? "未知")
                    LabeledContent("地址", value: String((settings.officialURL as NSString).prefix(48)) + "…")
                        .font(.footnote)
                    Button {
                        onReload()
                        dismiss()
                    } label: {
                        Label("刷新网页", systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive) {
                        settings.officialURL = ""
                        MonitorController.shared.stop()
                        dismiss()
                    } label: {
                        Label("断开连接，重新扫码", systemImage: "link.badge.plus")
                    }
                } header: {
                    Text("连接")
                } footer: {
                    Text("前台由官方网页保持连接；退到后台后由 App 接管监控，回前台网页自动重连。")
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
                    Text("任务完成/出错默认弹 App 通知；打开 Bark 后会同时推送到你的 iPhone Bark。")
                }

                Section {
                    Toggle("后台保活（静音播放）", isOn: $settings.keepAlive)
                } header: {
                    Text("后台")
                } footer: {
                    Text("退到后台时静音播放保持进程存活，通知才可靠。锁屏后若不弹通知，回 app 检查这个开关。")
                }

                Section {
                    LabeledContent("版本", value: "1.1.0")
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
