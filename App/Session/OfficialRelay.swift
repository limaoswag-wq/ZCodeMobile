import Foundation

/// rpc-frame 接收侧多片组装：官方对超过 1MB 的消息会分片发送。
final class RpcFrameAssembler {
    private struct Partial {
        var parts: [Int: Data]
        var fragmentCount: Int
        var messageBytes: Int
        var checksum: String
    }

    private var partials: [Int: Partial] = [:]

    func accept(_ payload: [String: Any]) -> Data? {
        guard let b64 = payload["dataBase64"] as? String, let data = Data(base64Encoded: b64) else { return nil }
        let seq = RpcFrame.intValue(payload["messageSeq"])
        let index = RpcFrame.intValue(payload["fragmentIndex"])
        let count = RpcFrame.intValue(payload["fragmentCount"])
        let total = RpcFrame.intValue(payload["messageBytes"])
        guard count > 0 else { return nil }
        if count == 1 || total <= data.count {
            partials.removeValue(forKey: seq)
            return data
        }
        var partial = partials[seq] ?? Partial(
            parts: [:],
            fragmentCount: count,
            messageBytes: total,
            checksum: (payload["checksum"] as? [String: Any])?["value"] as? String ?? ""
        )
        partial.parts[index] = data
        partials[seq] = partial

        let received = partial.parts.values.reduce(0) { $0 + $1.count }
        let allFragments = partial.parts.count >= count
        guard allFragments || received >= total else { return nil }
        var assembled = Data()
        assembled.reserveCapacity(total)
        for i in 0..<count {
            guard let part = partial.parts[i] else {
                partials.removeValue(forKey: seq)
                return nil
            }
            assembled.append(part)
        }
        partials.removeValue(forKey: seq)
        if partial.checksum.isEmpty || RpcFrame.crc32Hex(assembled) == partial.checksum {
            return assembled
        }
        return nil
    }

    func reset() { partials.removeAll() }
}

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
    private(set) var link: OfficialLink?
    private(set) var workspaces: [WorkspaceInfo] = []
    private(set) var tasks: [TaskSummary] = []
    private(set) var activeWorkspaceKey: String?
    private(set) var activeTaskId: String?
    private(set) var deviceName: String?
    private(set) var providers: [ModelProviderInfo] = []

    var onStateChange: ((State) -> Void)?
    var onSnapshot: (() -> Void)?
    var onMessages: ((String, [ChatMessage]) -> Void)?
    var onSendResult: ((Bool, String?) -> Void)?
    var onProviders: (() -> Void)?

    private var session: URLSession!
    private var socket: URLSessionWebSocketTask?
    private var heartbeat: Timer?
    private var requestCounter = 0
    private var pending: [String: (Bool, [String: Any]) -> Void] = [:]
    private var identity: BridgeIdentity?
    private var nextPhysicalSeq = 1
    private var nextMessageSeq = 1
    private let assembler = RpcFrameAssembler()
    private let channels = ChannelClient { _ in }
    private var clientId: String
    private var helloReady = false
    private var openingBridge = false
    private var intentionallyClosed = false
    private var ackedSeqs: Set<Int> = []

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

    // MARK: - 连接生命周期

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

    // MARK: - 对外动作

    func openTask(_ taskId: String) {
        activeTaskId = taskId
        if let workspace = workspace(for: taskId) {
            activeWorkspaceKey = workspace.key
        }
        sendViewState()
        Task { await loadMessages(for: taskId) }
        onSnapshot?()
    }

    func refreshTasks() {
        refreshWorkspaces()
    }

    func sendText(_ text: String, taskId: String?) {
        Task { await sendTextAsync(text, taskId: taskId) }
    }

    /// 停止当前任务：下发 abort 会话命令。
    func stopTask(_ taskId: String?) {
        Task {
            guard let sessionId = taskId ?? activeTaskId else { return }
            do {
                if !helloReady { try await prepareConversation() }
                var args = workspaceArgs()
                args["envelope"] = [
                    "commandId": UUID().uuidString.lowercased(),
                    "clientId": clientId,
                    "sessionId": sessionId,
                    "type": "abort",
                    "payload": [String: Any](),
                    "issuedAt": nowMs()
                ]
                _ = try await channels.call(channel: "zcode-agent", method: "sendConversationCommandV4", args: [args])
                DispatchQueue.main.async { self.onSendResult?(true, nil) }
            } catch {
                DispatchQueue.main.async { self.onSendResult?(false, error.localizedDescription) }
            }
        }
    }

    /// 新对话：用 firstInput 直接建会话。
    func startNewChat(firstInput: String) {
        Task { await createSessionWithFirstInput(firstInput) }
    }

    /// 切模型 / 思考等级：一条 switchModelConfig 会话命令。
    func switchModel(providerId: String, modelId: String, thought: String) {
        Task {
            guard let sessionId = activeTaskId else {
                DispatchQueue.main.async { self.onSendResult?(false, "先打开一个对话再切换模型") }
                return
            }
            do {
                if !helloReady { try await prepareConversation() }
                var args = workspaceArgs()
                args["envelope"] = [
                    "commandId": UUID().uuidString.lowercased(),
                    "clientId": clientId,
                    "sessionId": sessionId,
                    "type": "switchModelConfig",
                    "payload": ["provider": providerId, "model": modelId, "thought": thought],
                    "issuedAt": nowMs()
                ]
                _ = try await channels.call(channel: "zcode-agent", method: "sendConversationCommandV4", args: [args])
                DispatchQueue.main.async { self.onSendResult?(true, nil) }
            } catch {
                DispatchQueue.main.async { self.onSendResult?(false, error.localizedDescription) }
            }
        }
    }

    /// 拉模型供应商列表（model-provider 通道）。
    func fetchProviders() {
        Task {
            do {
                if !helloReady { try await prepareConversation() }
                let result = try await channels.call(channel: "model-provider", method: "getAllCached")
                let list = Self.parseProviders(result.jsonObject)
                DispatchQueue.main.async {
                    self.providers = list
                    self.onProviders?()
                }
            } catch {
                // 列表拉不到时菜单显示空态，不影响其他功能。
            }
        }
    }

    // MARK: - WebSocketDelegate

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

    // MARK: - 收包

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
            let messageSeq = RpcFrame.intValue(payload["messageSeq"])
            if !ackedSeqs.contains(messageSeq) {
                ackedSeqs.insert(messageSeq)
                if ackedSeqs.count > 512 { ackedSeqs.removeFirst() }
                if let identity {
                    sendPayload(RpcFrame.ack(identity: identity, messageSeq: messageSeq))
                }
            }
            if let data = assembler.accept(payload) {
                channels.receive(data)
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

    // MARK: - 任务列表 / 桥

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
        openWorkspaceBridgeIfNeeded()
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
        ackedSeqs.removeAll()
        assembler.reset()
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

    // MARK: - 会话桥调用

    private func prepareConversation() async throws {
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
    }

    func loadMessages(for taskId: String) {
        Task { await loadMessagesAsync(for: taskId) }
    }

    private func loadMessagesAsync(for taskId: String) async {
        guard helloReady else { return }
        do {
            var args = workspaceArgs()
            args["sessionId"] = taskId
            args["limit"] = 120
            let result = try await channels.call(channel: "zcode-agent", method: "conversationRowsRangeV4", args: [args])
            let messages = Self.parseMessages(result.jsonObject)
            DispatchQueue.main.async { self.onMessages?(taskId, messages) }
        } catch {
            // 未订阅时桌面端会拒；配对、任务列表、发送不受影响。
        }
    }

    private func sendTextAsync(_ text: String, taskId: String?) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            if !helloReady { try await prepareConversation() }
            guard let sessionId = taskId ?? activeTaskId else {
                throw simpleError("还没有可发送的对话")
            }
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
                    self.onSendResult?(true, nil)
                    self.loadMessages(for: sessionId)
                } else {
                    let reason = result.dictionary?["reasonCode"] as? String ?? "发送失败"
                    self.onSendResult?(false, reason)
                }
            }
        } catch {
            DispatchQueue.main.async { self.onSendResult?(false, error.localizedDescription) }
        }
    }

    private func createSessionWithFirstInput(_ text: String) async {
        do {
            if !helloReady { try await prepareConversation() }
            var payload: [String: Any] = [:]
            if let workspace = selectedWorkspace() {
                if let path = workspace.path {
                    payload["workspaceId"] = path
                    payload["workspacePath"] = path
                }
                if let identity = workspace.identity { payload["workspaceIdentity"] = identity }
            }
            payload["firstInput"] = ["text": text]
            var args = workspaceArgs()
            args["envelope"] = [
                "commandId": UUID().uuidString.lowercased(),
                "clientId": clientId,
                "type": "createSession",
                "payload": payload,
                "issuedAt": nowMs()
            ]
            let result = try await channels.call(channel: "zcode-agent", method: "sendConversationCommandV4", args: [args])
            var newId: String?
            if let nested = result.dictionary?["result"] as? [String: Any],
               let sessionId = nested["sessionId"] as? String {
                newId = sessionId
            }
            DispatchQueue.main.async {
                if let newId {
                    self.activeTaskId = newId
                    self.onSendResult?(true, nil)
                    self.onSnapshot?()
                    self.loadMessages(for: newId)
                } else {
                    self.onSendResult?(false, "桌面端没有返回新对话")
                }
            }
        } catch {
            DispatchQueue.main.async { self.onSendResult?(false, error.localizedDescription) }
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

    /// 拉一次工作区和任务列表。
    func refreshWorkspaces() {
        requestCounter += 1
        sendPayload([
            "zcode_type": "workspace-list-request",
            "requestId": "workspaces-\(requestCounter)"
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
        if Thread.isMainThread { send() } else { DispatchQueue.main.async { send() } }
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

    // MARK: - 辅助

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
                pinned: (item["pinned"] as? Bool) ?? false,
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
            let createdAt = RpcFrame.intValue(row["createdAt"])
            if kind == "userInput" || kind == "user" {
                guard !trimmed.isEmpty else { continue }
                messages.append(ChatMessage(
                    id: id, role: "user", kind: kind, createdAt: createdAt,
                    blocks: [ChatBlock(id: "\(id)-text", kind: "text", text: trimmed)]
                ))
            } else if kind == "assistantText" || kind == "assistant" {
                guard !trimmed.isEmpty else { continue }
                messages.append(ChatMessage(
                    id: id, role: "assistant", kind: kind, createdAt: createdAt,
                    blocks: [ChatBlock(id: "\(id)-text", kind: "text", text: text)]
                ))
            } else if kind == "reasoning" {
                guard !trimmed.isEmpty else { continue }
                messages.append(ChatMessage(
                    id: id, role: "assistant", kind: kind, createdAt: createdAt,
                    blocks: [ChatBlock(id: "\(id)-reason", kind: "reasoning", text: trimmed)]
                ))
            } else if kind == "toolCall" {
                messages.append(ChatMessage(
                    id: id, role: "assistant", kind: kind, createdAt: createdAt,
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

    static func parseProviders(_ raw: Any?) -> [ModelProviderInfo] {
        let array: [Any]
        if let value = raw as? [Any] {
            array = value
        } else if let dict = raw as? [String: Any], let inner = dict["result"] as? [Any] {
            array = inner
        } else {
            array = []
        }
        return array.compactMap { item -> ModelProviderInfo? in
            guard let dict = item as? [String: Any], let id = dict["id"] as? String else { return nil }
            let models = ((dict["models"] as? [[String: Any]]) ?? []).compactMap { model -> ModelProviderInfo.ModelInfo? in
                guard let modelId = model["id"] as? String else { return nil }
                return ModelProviderInfo.ModelInfo(id: modelId, name: (model["name"] as? String) ?? modelId)
            }
            return ModelProviderInfo(id: id, name: (dict["name"] as? String) ?? id, models: models)
        }
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
