import Foundation
import Combine

final class BridgeClient: ObservableObject {
    @Published var settings: AppSettings
    @Published var connection: ConnectionState = .idle
    @Published var snapshot = Snapshot(
        revision: 0,
        health: BridgeHealth(ok: false, desktopOnline: false, version: "", workspace: nil, lanAddresses: []),
        tasks: [],
        currentTaskId: nil,
        messages: [],
        running: false,
        lastEvent: nil
    )
    @Published var composerText = ""
    @Published var sending = false
    @Published var errorText: String?
    @Published var pasteDraft = ""
    @Published var deviceTitle = "ZCode"

    private var timer: Timer?
    private var lastRevision = -1
    private var notifiedCompletions = Set<String>()
    private let session: URLSession
    let notifyDelegate = NotificationDelegate()
    let relay = OfficialRelay()
    private var settingsObserver: AnyCancellable?
    private var usingOfficial = false

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)
        settingsObserver = settings.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        notifyDelegate.onOpenTask = { [weak self] taskId in
            Task { await self?.openTask(taskId) }
        }
        pasteDraft = settings.officialURL
        bindRelay()
    }

    var currentTask: TaskSummary? {
        snapshot.tasks.first { $0.id == snapshot.currentTaskId }
    }

    var isOfficialConnected: Bool { usingOfficial && relay.isPaired }

    func start() {
        LocalNotify.request()
        if settings.keepAlive { SilentAudio.shared.start() }
        if let link = OfficialLinkParser.parse(settings.officialURL) {
            connectOfficial(link)
        } else {
            pollNow()
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            self?.pollNow()
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        relay.disconnect()
        SilentAudio.shared.stop()
    }

    func pollNow() {
        if usingOfficial { return }
        Task { await poll() }
    }

    func connectFromScan(_ raw: String) {
        connectFromText(raw)
    }

    func connectFromText(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        pasteDraft = trimmed
        guard let link = OfficialLinkParser.parse(trimmed) else {
            errorText = "这不是 ZCode 远控链接。请扫描电脑上的二维码，或粘贴复制出来的地址。"
            return
        }
        settings.officialURL = trimmed
        connectOfficial(link)
    }

    func disconnectOfficial() {
        usingOfficial = false
        relay.disconnect()
        connection = .idle
        snapshot.health.ok = false
        snapshot.health.desktopOnline = false
        snapshot.tasks = []
        snapshot.messages = []
        snapshot.currentTaskId = nil
        errorText = nil
    }

    @MainActor
    func sendCurrent() async {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        defer { sending = false }
        if usingOfficial {
            let optimistic = ChatMessage(
                id: "local-\(UUID().uuidString)",
                role: "user",
                createdAt: Int(Date().timeIntervalSince1970 * 1000),
                blocks: [ChatBlock(id: "local-text", kind: "text", text: text)]
            )
            snapshot.messages.append(optimistic)
            snapshot.running = true
            composerText = ""
            relay.sendText(text, taskId: snapshot.currentTaskId)
            return
        }
        do {
            var body: [String: Any] = ["text": text]
            if let taskId = snapshot.currentTaskId { body["taskId"] = taskId }
            let response: SendResponse = try await post("/v1/send", body: body)
            if response.ok {
                composerText = ""
                await poll()
            } else {
                errorText = response.error ?? "发送失败"
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    func newTask() async {
        if usingOfficial {
            relay.newTask()
            return
        }
        do {
            let response: SendResponse = try await post("/v1/command", body: ["name": "new"])
            if !response.ok { errorText = response.error }
            await poll()
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    func stopTask() async {
        if usingOfficial {
            relay.stopCurrentTask()
            snapshot.running = false
            return
        }
        do {
            var body: [String: Any] = ["name": "stop"]
            if let taskId = snapshot.currentTaskId { body["taskId"] = taskId }
            let _: SendResponse = try await post("/v1/command", body: body)
            await poll()
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    func openTask(_ id: String) async {
        if usingOfficial {
            relay.openTask(id)
            snapshot.currentTaskId = id
            snapshot.messages = []
            return
        }
        do {
            let _: SendResponse = try await post("/v1/command", body: ["name": "open", "taskId": id])
            await poll()
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    func runCommand(_ name: String, value: String? = nil) async {
        if usingOfficial { return }
        var body: [String: Any] = ["name": name]
        if let value { body["value"] = value }
        if let taskId = snapshot.currentTaskId { body["taskId"] = taskId }
        do {
            let _: SendResponse = try await post("/v1/command", body: body)
            await poll()
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    func syncBark() async {
        let body: [String: Any] = [
            "enabled": settings.barkEnabled,
            "url": settings.barkURL
        ]
        do {
            let _: SendResponse = try await post("/v1/settings", body: body)
        } catch {
            if !usingOfficial { errorText = error.localizedDescription }
        }
    }

    private func connectOfficial(_ link: OfficialLink) {
        usingOfficial = true
        deviceTitle = link.displayName
        connection = .connecting
        errorText = nil
        snapshot.messages = []
        snapshot.tasks = []
        snapshot.health.workspace = link.deviceName
        relay.connect(link)
    }

    private func bindRelay() {
        relay.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .idle:
                self.connection = .idle
            case .connecting, .authenticating:
                self.connection = .connecting
            case .waiting:
                self.connection = .waiting
            case .paired:
                self.connection = .online
                self.errorText = nil
            case .failed(let message):
                self.connection = .offline(message)
                self.errorText = message
            }
        }
        relay.onSnapshot = { [weak self] in
            self?.applyOfficialSnapshot()
        }
        relay.onMessages = { [weak self] taskId, messages in
            guard let self else { return }
            if self.snapshot.currentTaskId == nil || self.snapshot.currentTaskId == taskId {
                self.snapshot.currentTaskId = taskId
                self.snapshot.messages = messages
            }
        }
        relay.onSendResult = { [weak self] ok, error in
            guard let self else { return }
            if ok {
                self.errorText = nil
            } else {
                self.errorText = error
                self.snapshot.running = false
            }
        }
    }

    private func applyOfficialSnapshot() {
        let previous = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0) })
        snapshot.tasks = relay.tasks
        snapshot.currentTaskId = relay.activeTaskId ?? snapshot.currentTaskId
        snapshot.health.ok = relay.isPaired
        snapshot.health.desktopOnline = relay.isPaired
        snapshot.health.workspace = relay.selectedWorkspaceLabel
        snapshot.running = snapshot.tasks.contains { $0.id == snapshot.currentTaskId && $0.isRunning }
        snapshot.revision += 1
        deviceTitle = relay.deviceName ?? deviceTitle
        for task in snapshot.tasks {
            let wasRunning = previous[task.id]?.isRunning ?? false
            if wasRunning && !task.isRunning && !notifiedCompletions.contains(task.id + task.status) {
                notifiedCompletions.insert(task.id + task.status)
                let title = task.status == "error" ? "任务出错" : "任务完成"
                LocalNotify.fire(title: title, body: task.title, taskId: task.id)
            }
        }
    }

    @MainActor
    private func poll() async {
        guard settings.baseURL != nil else {
            if connection == .idle || connection == .connecting {
                connection = .idle
            }
            return
        }
        if connection == .idle { connection = .connecting }
        do {
            let next: Snapshot = try await get("/v1/snapshot?since=\(lastRevision)")
            apply(next)
            if !usingOfficial {
                connection = .online
                errorText = nil
            }
        } catch {
            if !usingOfficial {
                connection = .offline(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func apply(_ next: Snapshot) {
        let previous = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0) })
        snapshot = next
        lastRevision = next.revision
        for task in next.tasks {
            let wasRunning = previous[task.id]?.isRunning ?? false
            if wasRunning && !task.isRunning && !notifiedCompletions.contains(task.id + task.status) {
                notifiedCompletions.insert(task.id + task.status)
                let title = task.status == "error" ? "任务出错" : "任务完成"
                LocalNotify.fire(title: title, body: task.title, taskId: task.id)
            }
        }
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var request = try makeRequest(path)
        request.httpMethod = "GET"
        return try await decode(request)
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        var request = try makeRequest(path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        return try await decode(request)
    }

    private func makeRequest(_ path: String) throws -> URLRequest {
        guard let base = settings.baseURL, let url = URL(string: path, relativeTo: base) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        if !settings.token.isEmpty {
            request.setValue(settings.token, forHTTPHeaderField: "x-zcode-mobile-token")
        }
        return request
    }

    private func decode<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let text = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "ZCodeBridge", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: text])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

extension OfficialRelay {
    var selectedWorkspaceLabel: String? {
        if let key = activeWorkspaceKey {
            if let match = workspaces.first(where: { $0.key == key }) {
                return match.label ?? match.path ?? match.key
            }
            return key
        }
        return workspaces.first?.label ?? workspaces.first?.path
    }
}
