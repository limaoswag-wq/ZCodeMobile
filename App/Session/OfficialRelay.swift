import Foundation

final class OfficialRelay: NSObject, URLSessionWebSocketDelegate {
    enum State: Equatable {
        case idle
        case connecting
        case authenticating
        case waiting
        case paired
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "未连接"
            case .connecting: return "正在连接"
            case .authenticating: return "正在校验"
            case .waiting: return "等待桌面端"
            case .paired: return "已连接"
            case .failed: return "连接失败"
            }
        }
    }

    struct WorkspaceInfo {
        var key: String
        var path: String?
        var identity: String?
        var kind: String
        var label: String?
        var remoteSessionId: String?
        var canBridge: Bool
    }

    private(set) var state: State = .idle
    /// 监控模式：只配对 + 拉任务列表做通知，不开工作区桥。
    var monitorOnly = false
    private(set) var link: OfficialLink?
    private(set) var workspaces: [WorkspaceInfo] = []
    private(set) var tasks: [TaskSummary] = []
    private(set) var activeWorkspaceKey: String?
    private(set) var activeTaskId: String?
    private(set) var deviceName: String?

    var onStateChange: ((State) -> Void)?
    var onSnapshot: (() -> Void)?
    var onMessages: ((String, [ChatMessage]) -> Void)?
    var onSendResult: ((Bool, String?) -> Void)?

    private var session: URLSession!
    private var socket: URLSessionWebSocketTask?
    private var heartbeat: Timer?
    private var requestCounter = 0
    private var pending: [String: (Bool, [String: Any]) -> Void] = [:]
    private var identity: BridgeIdentity?
    private var nextPhysicalSeq = 1
    private var nextMessageSeq = 1
    private let channels = ChannelClient { _ in }
    private var clientId: String
    private var helloReady = false
    private var openingBridge = false
    private var intentionallyClosed = false

    override init() {
        if let stored = UserDefaults.standard.string(forKey: "officialClientId") {
            clientId = stored
        } else {
            clientId = "client-\(UUID().uuidString.lowercased())"
            UserDefaults.standard.set(clientId, forKey: "officialClientId")
        }
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        channels.reset { [weak self] data in
            self?.sendRawMessage(data)
        }
    }

    var isPaired: Bool { state == .paired }

    func connect(_ link: OfficialLink) {
        disconnect()
        intentionallyClosed = false
        self.link = link
        deviceName = link.deviceName
        guard let url = link.relayWebSocketURL else {
            set(.failed("远控地址无效"))
            return
        }
        set(.connecting)
        let task = session.webSocketTask(with: url)
        socket = task
        task.resume()
        listen()
    }

    func disconnect() {
        intentionallyClosed = true
        heartbeat?.invalidate()
        heartbeat = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        pending.removeAll()
        identity = nil
        helloReady = false
        openingBridge = false
        channels.failAll(NSError(domain: "OfficialRelay", code: 1, userInfo: [NSLocalizedDescriptionKey: "已断开"]))
        if state != .idle { set(.idle) }
    }

    func openTask(_ taskId: String) {
        activeTaskId = taskId
        if let workspace = workspace(for: taskId) {
            activeWorkspaceKey = workspace.key
        }
        sendViewState()
        Task { await loadMessages(for: taskId) }
        onSnapshot?()
    }

    func sendText(_ text: String, taskId: String?) {
        Task { await sendTextAsync(text, taskId: taskId) }
    }

    /// 拉一次工作区和任务列表（监控模式轮询用）。
    func refreshWorkspaces() {
        requestCounter += 1
        sendPayload([
            "zcode_type": "workspace-list-request",
            "requestId": "workspaces-\(requestCounter)"
        ])
    }

    func stopCurrentTask() {
        Task { await sendAgentCommand("abort", payload: [:], sessionId: activeTaskId) }
    }

    func newTask() {
        Task { await createSessionAndNotify() }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol proto: String?) {
        guard let link else { return }
        set(.authenticating)
        sendJSON([
            "type": "auth_init",
            "role": "terminal",
            "device_sid": link.deviceSid,
            "meta": [
                "platform": "ios",
                "version": "1.0.0",
                "name": "ZCode Mobile"
            ],
            "client_ts": nowMs()
        ])
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        if !intentionallyClosed, state == .paired || state == .waiting {
            set(.failed("桌面端断开了远控连接"))
        }
    }

    private func listen() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                DispatchQueue.main.async {
                    if !self.intentionallyClosed, self.socket != nil {
                        self.set(.failed("远控连接中断"))
                    }
                }
            case .success(let message):
                self.handle(message)
                self.listen()
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let string): data = Data(string.utf8)
        case .data(let raw): data = raw
        @unknown default: return
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { return }
        DispatchQueue.main.async { self.handleJSON(type: type, json: json) }
    }

    private func handleJSON(type: String, json: [String: Any]) {
        switch type {
        case "auth_challenge":
            guard let nonce = json["nonce"] as? String, let link else { return }
            sendJSON([
                "type": "auth_response",
                "device_sid": link.deviceSid,
                "proof": OfficialProof.hmacBase64URL(
                    passHash: link.passHash,
                    nonce: nonce,
                    role: "terminal",
                    deviceSid: link.deviceSid
                ),
                "client_ts": nowMs()
            ])
        case "auth_ack", "pair_status_ack":
            applyPairStatus(json["pair_status"] as? String)
        case "data":
            if let payload = json["payload"] as? [String: Any] {
                handlePayload(payload)
            }
        case "error":
            let code = json["code"] as? String ?? ""
            let message = json["message"] as? String ?? code
            if code == "KICKED" {
                set(.failed("这个链接已被其他页面占用，关掉旧页面后重新扫码"))
            } else if code == "DEVICE_OFFLINE" {
                set(.waiting)
            } else {
                set(.failed(message.isEmpty ? "远控连接失败" : message))
            }
        default:
            break
        }
    }

    private func applyPairStatus(_ status: String?) {
        if status == "waiting" {
            set(.waiting)
            startHeartbeat()
        } else if status == "matched" {
            let alreadyPaired = state == .paired
            set(.paired)
            startHeartbeat()
            if !alreadyPaired {
                requestBootstrap()
            }
        }
    }

    private func handlePayload(_ payload: [String: Any]) {
        let kind = payload["zcode_type"] as? String
        if kind == "rpc-frame" {
            if let frame = RpcFrame.decodeMessage(payload) {
                if let identity {
                    sendPayload(RpcFrame.ack(identity: identity, messageSeq: frame.messageSeq))
                }
                channels.receive(frame.data)
            }
            return
        }
        if kind == "rpc-frame-ack" { return }

        if let requestId = payload["requestId"] as? String, let callback = pending.removeValue(forKey: requestId) {
            callback(payload["success"] as? Bool ?? true, payload)
            return
        }

        switch kind {
        case "workspace-list-updated":
            applyWorkspaceList(payload["result"] as? [String: Any] ?? [:])
        case "workspace-bridge-ready":
            if let bridge = payload["bridge"] as? [String: Any] {
                applyBridgeReady(bridge)
            }
        case "workspace-bridge-error":
            openingBridge = false
            onSendResult?(false, payload["error"] as? String ?? "无法打开工作区")
        default:
            break
        }
    }

    private func applyBootstrap(_ result: [String: Any]) {
        applyWorkspaceList(result)
        if let view = result["initialViewState"] as? [String: Any] {
            if let key = view["activeWorkspaceKey"] as? String { activeWorkspaceKey = key }
            if let taskId = view["activeTaskId"] as? String { activeTaskId = taskId }
        }
        if let view = result["mobileViewState"] as? [String: Any] {
            if let key = view["activeWorkspaceKey"] as? String { activeWorkspaceKey = key }
            if let taskId = view["activeTaskId"] as? String { activeTaskId = taskId }
        }
        if activeTaskId == nil { activeTaskId = tasks.first?.id }
        if activeWorkspaceKey == nil { activeWorkspaceKey = workspaces.first?.key }
        onSnapshot?()
        if !monitorOnly {
            openWorkspaceBridgeIfNeeded()
        }
    }

    private func applyWorkspaceList(_ result: [String: Any]) {
        workspaces = Self.parseWorkspaces(result["workspaces"] as? [[String: Any]] ?? [])
        tasks = Self.parseTasks(result["tasks"] as? [[String: Any]] ?? [])
        if let key = result["activeWorkspaceKey"] as? String { activeWorkspaceKey = key }
        if let taskId = result["activeTaskId"] as? String { activeTaskId = taskId }
        onSnapshot?()
    }

    private func applyBridgeReady(_ bridge: [String: Any]) {
        openingBridge = false
        var next = BridgeIdentity(
            bridgeSessionId: bridge["bridgeSessionId"] as? String ?? UUID().uuidString,
            bridgeGeneration: RpcFrame.intValue(bridge["bridgeGeneration"]),
            recoveryId: bridge["recoveryId"] as? String
        )
        if next.bridgeGeneration == 0 { next.bridgeGeneration = nil }
        identity = next
        nextPhysicalSeq = 1
        nextMessageSeq = 1
        helloReady = false
        channels.reset { [weak self] data in
            self?.sendRawMessage(data)
        }
        if let workspaceKey = bridge["workspaceKey"] as? String {
            activeWorkspaceKey = workspaceKey
        }
        if let taskId = bridge["initialTaskId"] as? String {
            activeTaskId = taskId
        }
        onSnapshot?()
        Task { await prepareConversation() }
    }

    private func requestBootstrap() {
        request("bootstrap-request", extra: [:]) { [weak self] success, payload in
            guard let self, success else { return }
            self.applyBootstrap(payload["result"] as? [String: Any] ?? [:])
        }
    }

    private func openWorkspaceBridgeIfNeeded() {
        guard state == .paired, identity == nil, !openingBridge else { return }
        guard let workspace = selectedWorkspace() else { return }
        openingBridge = true
        var extra: [String: Any] = [
            "bridgeSessionId": UUID().uuidString.lowercased(),
            "bridgeGeneration": 1,
            "workspaceKey": workspace.key
        ]
        if let taskId = activeTaskId { extra["taskId"] = taskId }
        request("workspace-bridge-open", extra: extra) { [weak self] _, payload in
            guard let self else { return }
            if (payload["zcode_type"] as? String) == "workspace-bridge-ready",
               let bridge = payload["bridge"] as? [String: Any] {
                self.applyBridgeReady(bridge)
            } else if (payload["zcode_type"] as? String) == "workspace-bridge-error" {
                self.openingBridge = false
                self.onSendResult?(false, payload["error"] as? String ?? "无法打开工作区")
            }
        }
    }

    private func prepareConversation() async {
        do {
            _ = try await channels.call(channel: "zcode-agent", method: "initialize", args: [workspaceArgs()])
            _ = try await channels.call(channel: "zcode-agent", method: "helloConversationV4")
            _ = try await channels.call(channel: "zcode-agent", method: "initializeConversationV4", args: [[
                "kind": "clientHello",
                "protocolVersion": 3,
                "clientId": clientId,
                "clientKind": "web",
                "appVersion": "1.0.0",
                "capabilities": ["workspaceHookReviewUi": true]
            ]])
            helloReady = true
            if let taskId = activeTaskId {
                await loadMessages(for: taskId)
            }
        } catch {
            DispatchQueue.main.async { self.onSendResult?(false, error.localizedDescription) }
        }
    }

    private func loadMessages(for taskId: String) async {
        guard helloReady else { return }
        do {
            var args = workspaceArgs()
            args["sessionId"] = taskId
            args["limit"] = 80
            let result = try await channels.call(channel: "zcode-agent", method: "conversationRowsRangeV4", args: [args])
            let messages = Self.parseMessages(result.jsonObject)
            DispatchQueue.main.async { self.onMessages?(taskId, messages) }
        } catch {
            // 历史消息走 conversationRowsRange，没订阅时桌面端会拒；配对和发消息不受影响。
        }
    }

    private func sendTextAsync(_ text: String, taskId: String?) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            if !helloReady { await prepareConversation() }
            var sessionId = taskId ?? activeTaskId
            if sessionId == nil {
                sessionId = try await createSession()
                activeTaskId = sessionId
            }
            guard let sessionId else { throw simpleError("还没有可发送的任务") }
            var args = workspaceArgs()
            args["envelope"] = [
                "commandId": UUID().uuidString.lowercased(),
                "clientId": clientId,
                "sessionId": sessionId,
                "type": "sendText",
                "payload": ["text": trimmed],
                "issuedAt": nowMs()
            ]
            let result = try await channels.call(channel: "zcode-agent", method: "sendConversationCommandV4", args: [args])
            let status = result.dictionary?["status"] as? String
            DispatchQueue.main.async {
                if status == "accepted" || status == "duplicate" {
                    self.activeTaskId = sessionId
                    self.onSendResult?(true, nil)
                    Task { await self.loadMessages(for: sessionId) }
                } else {
                    let reason = result.dictionary?["reasonCode"] as? String ?? "发送失败"
                    self.onSendResult?(false, reason)
                }
            }
        } catch {
            DispatchQueue.main.async { self.onSendResult?(false, error.localizedDescription) }
        }
    }

    private func createSessionAndNotify() async {
        do {
            if !helloReady { await prepareConversation() }
            let sessionId = try await createSession()
            DispatchQueue.main.async {
                self.activeTaskId = sessionId
                self.onSnapshot?()
            }
        } catch {
            DispatchQueue.main.async { self.onSendResult?(false, error.localizedDescription) }
        }
    }

    private func createSession() async throws -> String {
        var args = workspaceArgs()
        var payload: [String: Any] = [:]
        if let workspace = selectedWorkspace() {
            if let path = workspace.path {
                payload["workspaceId"] = path
                payload["workspacePath"] = path
            }
            if let identity = workspace.identity { payload["workspaceIdentity"] = identity }
        }
        args["envelope"] = [
            "commandId": UUID().uuidString.lowercased(),
            "clientId": clientId,
            "type": "createSession",
            "payload": payload,
            "issuedAt": nowMs()
        ]
        let result = try await channels.call(channel: "zcode-agent", method: "sendConversationCommandV4", args: [args])
        if let nested = result.dictionary?["result"] as? [String: Any],
           let sessionId = nested["sessionId"] as? String {
            return sessionId
        }
        throw simpleError("桌面端没有返回新任务")
    }

    @discardableResult
    private func sendAgentCommand(_ type: String, payload: [String: Any], sessionId: String?) async -> Bool {
        guard let sessionId else { return false }
        do {
            var args = workspaceArgs()
            args["envelope"] = [
                "commandId": UUID().uuidString.lowercased(),
                "clientId": clientId,
                "sessionId": sessionId,
                "type": type,
                "payload": payload,
                "issuedAt": nowMs()
            ]
            _ = try await channels.call(channel: "zcode-agent", method: "sendConversationCommandV4", args: [args])
            return true
        } catch {
            return false
        }
    }

    private func sendViewState() {
        var view: [String: Any] = ["updatedAt": nowMs()]
        if let activeWorkspaceKey { view["activeWorkspaceKey"] = activeWorkspaceKey }
        if let activeTaskId { view["activeTaskId"] = activeTaskId }
        sendPayload([
            "zcode_type": "mobile-view-state-update",
            "viewState": view,
            "deviceInfo": [
                "platform": "ios",
                "appVersion": "1.0.0",
                "name": "ZCode Mobile"
            ]
        ])
    }

    private func sendRawMessage(_ data: Data) {
        guard let identity, state == .paired else { return }
        let payload = RpcFrame.encode(
            message: data,
            identity: identity,
            seq: nextPhysicalSeq,
            messageSeq: nextMessageSeq
        )
        nextPhysicalSeq += 1
        nextMessageSeq += 1
        sendPayload(payload)
    }

    private func request(_ type: String, extra: [String: Any], handler: @escaping (Bool, [String: Any]) -> Void) {
        requestCounter += 1
        let requestId = "\(type)-\(requestCounter)-\(UUID().uuidString.prefix(8))"
        pending[requestId] = handler
        var payload: [String: Any] = extra
        payload["zcode_type"] = type
        payload["requestId"] = requestId
        sendPayload(payload)
    }

    private func sendPayload(_ payload: [String: Any]) {
        sendJSON([
            "type": "data",
            "payload": payload,
            "client_ts": nowMs()
        ])
    }

    private func sendJSON(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8)
        else { return }
        let send = { [weak self] in
            self?.socket?.send(.string(string)) { _ in }
        }
        if Thread.isMainThread {
            send()
        } else {
            DispatchQueue.main.async { send() }
        }
    }

    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self, let link = self.link else { return }
            self.sendJSON([
                "type": "pair_status_query",
                "device_sid": link.deviceSid,
                "client_ts": self.nowMs()
            ])
        }
        if let heartbeat { RunLoop.main.add(heartbeat, forMode: .common) }
    }

    private func set(_ next: State) {
        state = next
        onStateChange?(next)
        onSnapshot?()
    }

    private func selectedWorkspace() -> WorkspaceInfo? {
        if let activeWorkspaceKey, let match = workspaces.first(where: { $0.key == activeWorkspaceKey }) {
            return match
        }
        return workspaces.first
    }

    private func workspace(for taskId: String) -> WorkspaceInfo? {
        guard let task = tasks.first(where: { $0.id == taskId }) else { return selectedWorkspace() }
        if let path = task.workspacePath {
            return workspaces.first(where: { $0.path == path || $0.key == path }) ?? selectedWorkspace()
        }
        return selectedWorkspace()
    }

    private func workspaceArgs() -> [String: Any] {
        var args: [String: Any] = ["clientMode": "web"]
        if let workspace = selectedWorkspace() {
            if let path = workspace.path {
                args["workspacePath"] = path
                args["workspaceId"] = path
            }
            if let identity = workspace.identity { args["workspaceIdentity"] = identity }
            if let remote = workspace.remoteSessionId { args["remoteSessionId"] = remote }
        }
        return args
    }

    private func nowMs() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    private func simpleError(_ message: String) -> NSError {
        NSError(domain: "OfficialRelay", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func parseWorkspaces(_ raw: [[String: Any]]) -> [WorkspaceInfo] {
        raw.compactMap { item in
            let path = item["workspacePath"] as? String
            let identity = (item["workspaceIdentity"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = (identity?.isEmpty == false ? identity : path) ?? ""
            guard !key.isEmpty else { return nil }
            let kind = item["kind"] as? String ?? "local"
            let remoteId = item["remoteSessionId"] as? String
            return WorkspaceInfo(
                key: key,
                path: path,
                identity: identity,
                kind: kind,
                label: item["label"] as? String,
                remoteSessionId: remoteId,
                canBridge: kind != "remote" || ((identity?.isEmpty == false) && !(remoteId ?? "").isEmpty)
            )
        }
    }

    private static func parseTasks(_ raw: [[String: Any]]) -> [TaskSummary] {
        raw.compactMap { item in
            guard let id = item["taskId"] as? String else { return nil }
            return TaskSummary(
                id: id,
                title: item["title"] as? String ?? "未命名任务",
                status: item["displayStatus"] as? String ?? "idle",
                mode: nil,
                model: item["provider"] as? String,
                workspacePath: item["workspacePath"] as? String,
                updatedAt: RpcFrame.intValue(item["updatedAt"]),
                createdAt: RpcFrame.intValue(item["createdAt"])
            )
        }
    }

    static func parseMessages(_ raw: Any?) -> [ChatMessage] {
        let rows: [[String: Any]]
        if let dict = raw as? [String: Any] {
            rows = (dict["rows"] as? [[String: Any]])
                ?? ((dict["rows"] as? [String: Any])?["window"] as? [[String: Any]])
                ?? []
        } else if let array = raw as? [[String: Any]] {
            rows = array
        } else {
            rows = []
        }
        var messages: [ChatMessage] = []
        for row in rows {
            let kind = row["kind"] as? String ?? ""
            let text = (row["text"] as? String)
                ?? (row["inputText"] as? String)
                ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = (row["entityId"] as? String) ?? "row-\(RpcFrame.intValue(row["rowId"]))"
            if kind == "userInput" || kind == "user" {
                guard !trimmed.isEmpty else { continue }
                messages.append(ChatMessage(
                    id: id,
                    role: "user",
                    createdAt: RpcFrame.intValue(row["createdAt"]),
                    blocks: [ChatBlock(id: "\(id)-text", kind: "text", text: trimmed)]
                ))
            } else if kind == "assistantText" || kind == "assistant" {
                guard !trimmed.isEmpty else { continue }
                messages.append(ChatMessage(
                    id: id,
                    role: "assistant",
                    createdAt: RpcFrame.intValue(row["createdAt"]),
                    blocks: [ChatBlock(id: "\(id)-text", kind: "text", text: trimmed)]
                ))
            } else if kind == "reasoning" {
                guard !trimmed.isEmpty else { continue }
                messages.append(ChatMessage(
                    id: id,
                    role: "assistant",
                    createdAt: RpcFrame.intValue(row["createdAt"]),
                    blocks: [ChatBlock(id: "\(id)-reason", kind: "reasoning", text: trimmed)]
                ))
            } else if kind == "toolCall" {
                messages.append(ChatMessage(
                    id: id,
                    role: "assistant",
                    createdAt: RpcFrame.intValue(row["createdAt"]),
                    blocks: [ChatBlock(
                        id: "\(id)-tool",
                        kind: "tool",
                        text: trimmed,
                        tool: row["toolName"] as? String ?? row["name"] as? String,
                        status: row["status"] as? String
                    )]
                ))
            }
        }
        return messages
    }
}
