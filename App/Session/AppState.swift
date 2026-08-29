import Foundation
import UIKit
import Combine

/// 全局共享状态：唯一一条官方 relay 连接，前台聊天、后台通知共用。
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let settings = AppSettings()
    let relay = OfficialRelay()

    @Published private(set) var connection: ConnectionState = .idle
    @Published private(set) var tasks: [TaskSummary] = []
    @Published private(set) var activeTaskId: String?
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var providers: [ModelProviderInfo] = []
    @Published var toast: String?

    /// 当前选中的模型 / 思考等级（本机偏好，切换时下发 switchModelConfig）。
    @Published var selectedProviderId: String {
        didSet { UserDefaults.standard.set(selectedProviderId, forKey: "selProvider") }
    }
    @Published var selectedModelId: String {
        didSet { UserDefaults.standard.set(selectedModelId, forKey: "selModel") }
    }
    @Published var selectedThought: String {
        didSet { UserDefaults.standard.set(selectedThought, forKey: "selThought") }
    }

    private var lastStatus: [String: String] = [:]
    private var lastLoadedTaskId: String?
    private var pollTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    var activeTask: TaskSummary? { tasks.first { $0.id == activeTaskId } }
    var isTaskRunning: Bool { activeTask?.isRunning ?? false }
    var currentTaskEntries: [ChatEntry] { EntryBuilder.build(messages: messages) }

    var deviceName: String {
        if let link = relay.link, let name = link.deviceName, !name.isEmpty { return name }
        return relay.deviceName ?? "ZCode"
    }

    private init() {
        selectedProviderId = UserDefaults.standard.string(forKey: "selProvider") ?? "zai"
        selectedModelId = UserDefaults.standard.string(forKey: "selModel") ?? "GLM-5.3-Flash"
        selectedThought = UserDefaults.standard.string(forKey: "selThought") ?? "高"

        settings.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        relay.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .paired: self.connection = .online
            case .waiting: self.connection = .waiting
            case .failed(let message): self.connection = .offline(message)
            case .idle: self.connection = .idle
            case .connecting, .authenticating: self.connection = .connecting
            }
        }
        relay.onSnapshot = { [weak self] in
            self?.applyRelaySnapshot()
        }
        relay.onMessages = { [weak self] taskId, messages in
            guard let self, taskId == self.activeTaskId else { return }
            self.messages = messages
            self.lastLoadedTaskId = taskId
        }
        relay.onSendResult = { [weak self] ok, error in
            guard let self else { return }
            if let error, !ok { self.showToast(error) }
        }
        relay.onProviders = { [weak self] in
            guard let self else { return }
            self.providers = self.relay.providers
        }
    }

    func showToast(_ message: String) {
        toast = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.toast == message { self?.toast = nil }
        }
    }

    var hasLink: Bool {
        OfficialLinkParser.parse(settings.officialURL) != nil
    }

    func connectSavedLinkIfNeeded() {
        guard relay.state == .idle, let raw = settings.officialURL,
              let link = OfficialLinkParser.parse(raw)
        else { return }
        relay.connect(link)
    }

    func connect(from raw: String) {
        settings.officialURL = raw
        if let link = OfficialLinkParser.parse(raw) {
            relay.connect(link)
        }
    }

    func disconnect() {
        settings.officialURL = ""
        relay.disconnect()
        connection = .idle
        tasks = []
        messages = []
        activeTaskId = nil
    }

    func openTask(_ id: String) {
        activeTaskId = id
        messages = []
        relay.openTask(id)
        startPollingIfRunning()
    }

    func startNewChat() {
        activeTaskId = nil
        messages = []
        objectWillChange.send()
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let taskId = activeTaskId {
            relay.sendText(trimmed, taskId: taskId)
        } else {
            relay.startNewChat(firstInput: trimmed)
        }
        // 乐观刷新：稍后拉一次会话内容。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.refreshActiveMessages()
        }
        startPollingIfRunning()
    }

    func refreshActiveMessages() {
        guard let taskId = activeTaskId else { return }
        relay.loadMessages(for: taskId)
    }

    func switchModel(providerId: String, modelId: String, thought: String) {
        selectedProviderId = providerId
        selectedModelId = modelId
        selectedThought = thought
        relay.switchModel(providerId: providerId, modelId: modelId, thought: thought)
    }

    func fetchProviders() {
        relay.fetchProviders()
    }

    func refreshTasks() {
        relay.refreshWorkspaces()
    }

    // MARK: - 通知（前后台共用同一条连接）

    func startPollingIfRunning() {
        pollTimer?.invalidate()
        pollTimer = nil
        guard isTaskRunning else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.isTaskRunning else {
                    self.pollTimer?.invalidate()
                    self.pollTimer = nil
                    return
                }
                self.refreshActiveMessages()
                self.refreshTasks()
            }
        }
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func applyRelaySnapshot() {
        let previous = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        tasks = relay.tasks
        if activeTaskId == nil { activeTaskId = relay.activeTaskId }
        objectWillChange.send()
        diffNotifications(previous: previous)
        startPollingIfRunning()
    }

    private func diffNotifications(previous: [String: TaskSummary]) {
        let now = Date().timeIntervalSince1970 * 1000
        for task in tasks {
            guard let old = previous[task.id], old.status != task.status else { continue }
            let wasActive = old.isRunning
            guard wasActive, task.status == "completed" || task.status == "error" else { continue }
            let fresh = task.updatedAt > 0 && (now - Double(task.updatedAt)) < 90_000
            guard fresh else { continue }
            if task.status == "completed" {
                fire(title: "任务完成", body: task.title, taskId: task.id)
            } else {
                fire(title: "任务出错", body: task.title, taskId: task.id)
            }
        }
    }

    private func fire(title: String, body: String, taskId: String) {
        LocalNotify.fire(title: title, body: body, taskId: taskId)
        pushBark(title: title, body: body)
    }

    private func pushBark(title: String, body: String) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "barkEnabled") else { return }
        let raw = (defaults.string(forKey: "barkURL") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.lowercased().hasPrefix("http") else { return }
        var base = raw
        if base.hasSuffix("/") { base.removeLast() }
        let enc = { (s: String) -> String in
            s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
        }
        guard let url = URL(string: "\(base)/\(enc(title))/\(enc(body))?group=ZCode") else { return }
        URLSession.shared.dataTask(with: url) { _, _, _ in }.resume()
    }
}
