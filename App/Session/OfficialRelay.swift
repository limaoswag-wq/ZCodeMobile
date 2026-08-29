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
    private(set) var fileChangesContext: (revision: Int, logEpoch: Int, rowId: Int, entityId: String)?

    var onStateChange: ((State) -> Void)?
    var onSnapshot: (() -> Void)?
    var onMessages: ((String, [ChatMessage]) -> Void)?
    var onSendResult: ((Bool, String?) -> Void)?
    var onProviders: (() -> Void)?
    var onFileChanges: (([FileChangeInfo]) -> Void)?

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
    /// 当前打开会话的实时行存储（rowId → row），由订阅增量维护。
    private var liveRows: [Int: [String: Any]] = [:]
    private var liveSessionId: String?
    private var subscribedSessionIds: Set<String> = []
    private var subscribedWorkspace = false
    /// 新建会话时写进 config 的模型选择（provider/model + 思考 variants 原值），由 AppState 维护。
    var sessionDefaults: (provider: String, model: String, thought: String) = ("", "", "")

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
        channels.onEvent = { [weak self] value in
            self?.handleEvent(value)
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

    /// 新对话：先 createSession（sessionId 显式 null + config），拿到 id 后再发首条。
    func startNewChat(firstInput: String) {
        Task { await createSessionThenSend(firstInput) }
    }

    private func createSessionThenSend(_ text: String) async {
        do {
            if !helloReady { try await prepareConversation() }
            // createSession 的 payload 是 strict 校验：workspaceId + config，绝不能带别的键。
            var payload: [String: Any] = [:]
            if let workspace = selectedWorkspace() {
                payload["workspaceId"] = workspace.key
            }
            let d = sessionDefaults
            if !d.provider.isEmpty, !d.model.isEmpty {
                payload["config"] = [
                    "mode": "yolo",
                    "provider": d.provider,
                    "model": d.model,
                    "thought": d.thought,
                    "followupMode": "queue"
                ]
            }
            var args = workspaceArgs()
            args["envelope"] = [
                "commandId": UUID().uuidString.lowercased(),
                "clientId": clientId,
                "sessionId": NSNull(),
                "type": "createSession",
                "payload": payload,
                "issuedAt": nowMs()
            ]
            let result = try await channels.call(channel: "zcode-agent", method: "sendConversationCommandV4", args: [args])
            writeDebug("createSession", ["raw": result.jsonObject ?? NSNull()])
            var newId: String?
            if let nested = result.dictionary?["result"] as? [String: Any],
               let sessionId = nested["sessionId"] as? String {
                newId = sessionId
            }
            guard let newId else {
                let status = result.dictionary?["status"] as? String ?? "?"
                let reason = result.dictionary?["reasonCode"] as? String ?? "-"
                DispatchQueue.main.async { self.onSendResult?(false, "新建失败 status=\(status) reason=\(reason)") }
                return
            }
            DispatchQueue.main.async {
                self.activeTaskId = newId
                self.liveRows.removeAll()
                self.liveSessionId = newId
                self.subscribeConversation(sessionId: newId)
                self.onSnapshot?()
            }
            // 新会话建好后，首条消息对它 sendText。
            await sendTextAsync(text, taskId: newId)
        } catch {
            DispatchQueue.main.async { self.onSendResult?(false, error.localizedDescription) }
        }
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
        subscribedWorkspace = false
        subscribedSessionIds.removeAll()
        channels.reset { [weak self] data in
            self?.sendRawMessage(data)
        }
        channels.onEvent = { [weak self] value in
            self?.handleEvent(value)
        }
        if let workspaceKey = bridge["workspaceKey"] as? String {
            activeWorkspaceKey = workspaceKey
        }
        if let taskId = bridge["initialTaskId"] as? String {
            activeTaskId = taskId
        }
        onSnapshot?()
        Task { [weak self] in
            _ = try? await self?.prepareConversation()
        }
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
        await subscribeWorkspaceFeeds()
        if let taskId = activeTaskId {
            subscribeConversation(sessionId: taskId)
            await loadMessagesAsync(for: taskId)
        }
    }

    /// 全局实时源：任务索引 + 任务状态（通知也靠它，不再轮询）。
    private func subscribeWorkspaceFeeds() async {
        guard !subscribedWorkspace, let workspace = selectedWorkspace(),
              let path = workspace.path
        else { return }
        do {
            _ = try await channels.call(channel: "zcode-agent", method: "subscribeSessionsIndexV4", args: [[
                "workspacePath": path,
                "runtimePolicy": "existing-only"
            ]])
            _ = try await channels.call(channel: "window-controller", method: "subscribeControllerV4", args: [[
                "topic": "controller/tasks-index",
                "visibility": "foreground"
            ]])
            subscribedWorkspace = true
        } catch {
            writeDebug("subscribe-workspace-error", ["error": error.localizedDescription])
        }
    }

    /// 每个打开的会话订阅一次，之后行增量实时推过来。
    private func subscribeConversation(sessionId: String) {
        guard !subscribedSessionIds.contains(sessionId) else { return }
        subscribedSessionIds.insert(sessionId)
        Task { [weak self] in
            guard let self else { return }
            do {
                var args = self.workspaceArgs()
                args["sessionId"] = sessionId
                _ = try await self.channels.call(channel: "zcode-agent", method: "subscribeConversationV4", args: [args])
            } catch {
                self.writeDebug("subscribe-error", ["sessionId": sessionId, "error": error.localizedDescription])
            }
        }
    }

    /// 协议调试落盘：Documents/relay_debug.json，最多留 40 条，方便远程排查字段。
    func writeDebug(_ label: String, _ object: Any) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let dir = docs else { return }
        let url = dir.appendingPathComponent("relay_debug.json")
        var existing: [[String: Any]] = []
        if let data = try? Data(contentsOf: url),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            existing = arr
        }
        existing.append(["ts": nowMs(), "label": label, "data": object])
        if existing.count > 40 { existing = Array(existing.suffix(40)) }
        if let out = try? JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: url)
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
            let raw = result.jsonObject as? [String: Any]
            let rows = (raw?["rows"] as? [[String: Any]])
                ?? ((raw?["rows"] as? [String: Any])?["window"] as? [[String: Any]])
                ?? []
            // 订阅先挂上，再种基线行；之后的增量走事件。
            liveSessionId = taskId
            liveRows = Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                let rid = RpcFrame.intValue(row["rowId"])
                return rid > 0 ? (rid, row) : nil
            })
            subscribeConversation(sessionId: taskId)
            captureFileChangesContext(raw)
            let messages = Self.parseMessages(rows)
            writeDebug("rowsRange", ["taskId": taskId, "count": rows.count])
            DispatchQueue.main.async { self.onMessages?(taskId, messages) }
        } catch {
            writeDebug("rowsRange-error", ["taskId": taskId, "error": error.localizedDescription])
            // 未订阅时桌面端会拒；配对、任务列表、发送不受影响。
        }
    }

    /// 审查面板：从 rowsRange 结果里记下 revision/logEpoch 和最后一条用户行，
    /// 之后用它们去问 fileChanges。
    private func captureFileChangesContext(_ raw: Any?) {
        guard let dict = raw as? [String: Any] else { return }
        let revision = RpcFrame.intValue(dict["revision"] ?? dict["atRevision"])
        let logEpoch = RpcFrame.intValue(dict["logEpoch"] ?? dict["atLogEpoch"])
        let rows = (dict["rows"] as? [[String: Any]])
            ?? ((dict["rows"] as? [String: Any])?["window"] as? [[String: Any]])
            ?? []
        for row in rows.reversed() {
            if (row["kind"] as? String)?.lowercased().hasPrefix("user") == true {
                fileChangesContext = (
                    revision,
                    logEpoch,
                    RpcFrame.intValue(row["rowId"]),
                    (row["entityId"] as? String) ?? ""
                )
                return
            }
        }
    }

    /// 拉当前会话的文件改动（审查面板数据）。
    func fetchFileChanges(for taskId: String) {
        guard let ctx = fileChangesContext, ctx.revision > 0 else { return }
        Task {
            do {
                var args = workspaceArgs()
                args["sessionId"] = taskId
                args["target"] = ["rowId": ctx.rowId, "entityId": ctx.entityId]
                args["baseRevision"] = ctx.revision
                args["baseLogEpoch"] = ctx.logEpoch
                let result = try await channels.call(channel: "zcode-agent", method: "conversationFileChangesV4", args: [args])
                writeDebug("fileChanges", ["raw": result.jsonObject ?? NSNull()])
                let files = Self.parseFileChanges(result.jsonObject)
                DispatchQueue.main.async { self.onFileChanges?(files) }
            } catch {
                writeDebug("fileChanges-error", ["error": error.localizedDescription])
            }
        }
    }

    /// 行的 input 对象里取终端命令。
    private static func command(from input: [String: Any]?) -> String? {
        input?["command"] as? String
    }

    static func parseFileChanges(_ raw: Any?) -> [FileChangeInfo] {
        // 响应结构未知，做多位置防御解析；原始返回已落调试文件。
        var candidates: [[String: Any]] = []
        if let dict = raw as? [String: Any] {
            for key in ["files", "changes", "fileChanges", "items"] {
                if let arr = dict[key] as? [[String: Any]] { candidates = arr; break }
            }
            if candidates.isEmpty, let result = dict["result"] as? [String: Any] {
                for key in ["files", "changes", "fileChanges", "items"] {
                    if let arr = result[key] as? [[String: Any]] { candidates = arr; break }
                }
            }
        } else if let arr = raw as? [[String: Any]] {
            candidates = arr
        }
        return candidates.compactMap { item in
            guard let path = (item["path"] as? String) ?? (item["file_path"] as? String) else { return nil }
            let additions = RpcFrame.intValue(item["additions"] ?? item["added"])
            let deletions = RpcFrame.intValue(item["deletions"] ?? item["removed"])
            let status = (item["status"] as? String)
                ?? (item["change"] as? String)
                ?? (item["type"] as? String)
                ?? "M"
            // diff 内容字段名未最终核实，多候选解析；原始返回已落调试文件。
            var content: String?
            for key in ["patch", "diff", "content", "text"] {
                if let s = item[key] as? String, !s.isEmpty { content = s; break }
            }
            if content == nil, let hunks = item["hunks"] as? [[String: Any]] {
                content = hunks.compactMap { $0["content"] as? String ?? $0["lines"] as? String }.joined(separator: "\n")
            }
            return FileChangeInfo(path: path, status: status, additions: additions, deletions: deletions, content: content)
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
            if status != "accepted" && status != "duplicate" {
                writeDebug("sendText-rejected", ["raw": result.jsonObject ?? NSNull()])
            }
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

    // MARK: - 实时事件路由

    private func handleEvent(_ value: IPCValue) {
        guard let dict = value.dictionary else { return }
        let topic = dict["topic"] as? String ?? ""
        let frame = dict["frame"] as? [String: Any]
        let payload = (frame?["payload"] as? [String: Any]) ?? (dict["payload"] as? [String: Any])
        guard let deltas = payload?["deltas"] as? [[String: Any]] else { return }
        if topic.hasPrefix("conversation/") {
            let sid = String(topic.dropFirst("conversation/".count))
            guard sid == liveSessionId else { return }
            applyConversationDeltas(deltas)
        } else if topic == "controller/tasks-index" {
            applyTaskDeltas(deltas)
        }
    }

    private func applyConversationDeltas(_ deltas: [[String: Any]]) {
        for d in deltas {
            let op = d["op"] as? String ?? ""
            switch op {
            case "row.upserted", "row.appended":
                if let row = d["row"] as? [String: Any] {
                    liveRows[RpcFrame.intValue(row["rowId"])] = row
                }
            case "row.removed":
                if let from = d["fromRowId"] {
                    let f = RpcFrame.intValue(from)
                    liveRows = liveRows.filter { $0.key < f }
                }
            case "row.delta":
                let rowId = RpcFrame.intValue(d["rowId"])
                guard var row = liveRows[rowId], let append = d["append"] as? String else { continue }
                let path = d["path"] as? String ?? "text"
                switch path {
                case "text":
                    row["text"] = ((row["text"] as? String) ?? "") + append
                case "inputText":
                    row["inputText"] = ((row["inputText"] as? String) ?? "") + append
                default:
                    break
                }
                liveRows[rowId] = row
            default:
                break
            }
        }
        rebuildLiveMessages()
    }

    private func rebuildLiveMessages() {
        guard let sid = liveSessionId else { return }
        let rows = liveRows.keys.sorted().compactMap { liveRows[$0] }
        let messages = Self.parseMessages(rows)
        onMessages?(sid, messages)
    }

    /// 任务实时状态：跑增量更新任务列表（通知靠这里，不再轮询）。
    private func applyTaskDeltas(_ deltas: [[String: Any]]) {
        var updated = tasks
        var changed = false
        for d in deltas {
            guard (d["op"] as? String) == "task.upserted",
                  let task = d["task"] as? [String: Any],
                  let meta = task["meta"] as? [String: Any],
                  let id = meta["taskId"] as? String
            else { continue }
            let membership = task["membership"] as? [String: Any] ?? [:]
            let status = (task["liveStatus"] as? String) ?? (meta["status"] as? String) ?? "idle"
            var summary = TaskSummary(
                id: id,
                title: meta["title"] as? String ?? "未命名任务",
                status: status,
                mode: meta["mode"] as? String,
                model: meta["model"] as? String,
                workspacePath: meta["workspacePath"] as? String,
                pinned: (membership["pinned"] as? Bool) ?? false,
                updatedAt: RpcFrame.intValue(meta["updatedAt"]),
                createdAt: RpcFrame.intValue(meta["createdAt"]),
                modelId: nil,
                thoughtLevel: meta["thoughtLevel"] as? String
            )
            if let full = meta["model"] as? String, let slash = full.lastIndex(of: "/") {
                summary.modelId = String(full[full.index(after: slash)...])
            }
            if let idx = updated.firstIndex(where: { $0.id == id }) {
                updated[idx] = summary
            } else {
                updated.insert(summary, at: 0)
            }
            changed = true
        }
        if changed {
            updated.sort { $0.updatedAt > $1.updatedAt }
            tasks = updated
            onSnapshot?()
        }
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
            if let vis = row["visibility"] as? String, vis != "visible" { continue }
            let kind = row["kind"] as? String ?? ""
            let input = row["input"] as? [String: Any]
            let text = (row["text"] as? String)
                ?? (row["thinking"] as? String)
                ?? (row["content"] as? String)
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
                guard !trimmed.isEmpty else { continue }
                let toolName = (row["toolName"] as? String) ?? (row["name"] as? String) ?? ""
                var filePath = input?["file_path"] as? String
                var content = input?["content"] as? String
                if let ns = input?["new_string"] as? String { content = (content ?? "") + ns }
                if filePath == nil, let data = trimmed.data(using: .utf8),
                   let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    filePath = obj["file_path"] as? String
                    if content == nil {
                        if let c = obj["content"] as? String { content = c }
                        if let c = obj["new_string"] as? String { content = (content ?? "") + c }
                    }
                }
                var detail = content ?? (input?["command"] as? String) ?? trimmed
                if detail.count > 6000 {
                    detail = String(detail.prefix(6000)) + "\n…"
                }
                messages.append(ChatMessage(
                    id: id, role: "assistant", kind: kind, createdAt: createdAt,
                    blocks: [ChatBlock(
                        id: "\(id)-tool",
                        kind: "tool",
                        text: detail,
                        tool: toolName,
                        status: row["status"] as? String,
                        path: filePath
                    )]
                ))
            }
        }
        return messages
    }

    static func parseProviders(_ raw: Any?) -> [ModelProviderInfo] {
        // 响应第一层就是供应商数组（getAllCached）。
        let array: [Any]
        if let value = raw as? [Any] {
            array = value
        } else if let dict = raw as? [String: Any], let inner = dict["result"] as? [Any] {
            array = inner
        } else {
            array = []
        }
        let rank = ["low": 0, "medium": 1, "high": 2, "xhigh": 3, "max": 4, "enabled": 0, "off": 1]
        return array.compactMap { item -> ModelProviderInfo? in
            guard let dict = item as? [String: Any], let id = dict["id"] as? String else { return nil }
            let enabled = dict["enabled"] as? Bool
            let reason = dict["systemDisabledReason"] as? String
            let apiKey = (dict["apiKey"] as? String) ?? ""
            let visible: Bool
            if let enabled { visible = enabled } else { visible = (reason == nil && !apiKey.isEmpty) }
            guard visible else { return nil }
            let modelsRaw = (dict["models"] as? [[String: Any]]) ?? []
            let models = modelsRaw.compactMap { m -> ModelProviderInfo.ModelInfo? in
                guard let mid = m["id"] as? String else { return nil }
                var levels: [ModelLevel] = []
                if let reasoning = m["reasoning"] as? [String: Any] {
                    var values: [String] = []
                    if let arr = reasoning["levels"] as? [[String: Any]] {
                        values = arr.compactMap { $0["value"] as? String }
                    } else if let dictLevels = reasoning["levels"] as? [String: Any] {
                        values = dictLevels.keys.sorted { (rank[$0] ?? 99) < (rank[$1] ?? 99) }
                    } else if let variants = reasoning["variants"] as? [String] {
                        values = variants
                    }
                    levels = values.map { ModelLevel(value: $0, zh: ModelLevel.zhLabel(for: $0)) }
                }
                let vision = ((m["modalities"] as? [String: Any])?["input"] as? [String])?.contains("image") ?? false
                let label = (m["name"] as? String) ?? (m["label"] as? String) ?? mid
                return ModelProviderInfo.ModelInfo(id: mid, name: label, levels: levels, vision: vision)
            }
            let name = (dict["name"] as? String) ?? id
            return ModelProviderInfo(id: id, name: name, models: models)
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
