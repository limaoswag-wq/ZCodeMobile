import Foundation

struct BridgeHealth: Codable {
    var ok: Bool
    var desktopOnline: Bool
    var version: String
    var workspace: String?
    var lanAddresses: [String]
}

struct TaskSummary: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var status: String
    var mode: String?
    var model: String?
    var workspacePath: String?
    var pinned: Bool
    var updatedAt: Int
    var createdAt: Int
    var modelId: String?
    var thoughtLevel: String?

    var isRunning: Bool { status == "running" || status == "waiting" }
    var statusLabel: String {
        switch status {
        case "running": return "运行中"
        case "waiting": return "等待中"
        case "completed": return "已完成"
        case "error": return "出错"
        case "idle": return "空闲"
        default: return status
        }
    }
}

/// 思考档位：value 是发给桌面端的原值，zh 是界面中文。
struct ModelLevel: Hashable {
    var value: String
    var zh: String

    static func zhLabel(for value: String) -> String {
        switch value {
        case "low": return "低"
        case "medium": return "中"
        case "high": return "高"
        case "xhigh": return "极高"
        case "max": return "最高"
        case "enabled": return "开"
        case "off": return "关"
        default: return value
        }
    }
}

struct ChatBlock: Codable, Identifiable, Hashable {
    var id: String
    var kind: String
    var text: String
    var tool: String?
    var status: String?
    var path: String?

    init(id: String, kind: String, text: String, tool: String? = nil, status: String? = nil, path: String? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.tool = tool
        self.status = status
        self.path = path
    }
}

struct ChatMessage: Codable, Identifiable, Hashable {
    var id: String
    var role: String
    var kind: String
    var createdAt: Int
    var blocks: [ChatBlock]

    var isUser: Bool { role == "user" }
    var markdown: String {
        blocks.filter { $0.kind == "text" }.map(\.text).joined(separator: "\n\n")
    }
}

/// 时间线里的一条过程记录（思考 / 技能 / 终端 / 读取 / 编辑）。
struct WorkItem: Identifiable, Hashable {
    enum Kind: String {
        case thinking
        case skill
        case terminal
        case read
        case edit
        case text
    }

    var id: String
    var kind: Kind
    var title: String
    var detail: String
    var createdAt: Int

    /// 这类行默认折叠、点开看详情。
    var collapsible: Bool {
        switch kind {
        case .thinking, .terminal, .read, .edit: return true
        default: return false
        }
    }
}

/// 审查面板里的一条文件改动。
struct FileChangeInfo: Identifiable, Hashable {
    var id: String { path }
    var path: String
    var status: String
    var additions: Int
    var deletions: Int
    var content: String?
}

/// 聊天页的一条展示内容：用户气泡 / 已工作折叠块 / 正文。
struct ChatEntry: Identifiable, Hashable {
    enum Kind: Hashable {
        case user(text: String, time: Int)
        case work(id: String, items: [WorkItem], startMs: Int, endMs: Int, running: Bool)
        case body(id: String, markdown: String, time: Int)
    }

    var id: String
    var kind: Kind
}

struct Snapshot: Codable {
    var revision: Int
    var health: BridgeHealth
    var tasks: [TaskSummary]
    var currentTaskId: String?
    var messages: [ChatMessage]
    var running: Bool
    var lastEvent: String?
}

struct SendResponse: Codable {
    var ok: Bool
    var taskId: String?
    var error: String?
}

enum ConnectionState: Equatable {
    case idle
    case connecting
    case waiting
    case online
    case offline(String)

    var label: String {
        switch self {
        case .idle: return "未连接"
        case .connecting: return "连接中"
        case .waiting: return "等待桌面端"
        case .online: return "已连接"
        case .offline: return "离线"
        }
    }

    var isConnected: Bool {
        if case .online = self { return true }
        return false
    }
}

/// 模型供应商（model-provider 通道 getAllCached 的精简结构）。
struct ModelProviderInfo: Identifiable, Hashable {
    struct ModelInfo: Identifiable, Hashable {
        var id: String
        var name: String
        var levels: [ModelLevel]
        var vision: Bool
    }

    var id: String
    var name: String
    var models: [ModelInfo]
}

enum ThoughtLevel: String, CaseIterable, Identifiable {
    case low = "低"
    case medium = "中"
    case high = "高"
    case xhigh = "极高"

    var id: String { rawValue }
}

enum EntryBuilder {
    /// 把按时间排序的会话行分组成：用户气泡 / 已工作折叠块（每轮一个）/ 正文。
    /// 一轮 = 一次用户输入之后的所有助手行；思考/技能/终端/读取/中间解说全部进
    /// 这轮唯一的「已工作」，最后一批没跟工具的文本是这轮的正文。
    static func build(messages: [ChatMessage]) -> [ChatEntry] {
        var entries: [ChatEntry] = []
        var items: [WorkItem] = []
        var turnStart = 0
        var turnEnd = 0
        var pending: [(id: String, text: String)] = []

        // 输出当前轮唯一的已工作块；不动 pending。
        func emitTurn() {
            guard !items.isEmpty else { return }
            let id = "work-\(items.first!.id)"
            entries.append(ChatEntry(id: id, kind: .work(
                id: id,
                items: items,
                startMs: turnStart,
                endMs: turnEnd,
                running: false
            )))
            items.removeAll()
        }

        // 中间解说并入当前轮时间线。
        func foldPendingIntoTurn() {
            for p in pending {
                items.append(WorkItem(
                    id: "\(p.id)-mid",
                    kind: .text,
                    title: "",
                    detail: p.text,
                    createdAt: turnEnd
                ))
            }
            pending.removeAll()
        }

        for message in messages {
            if message.isUser {
                // 上一轮结束：先出这轮唯一的已工作，再出正文，最后才是新用户气泡。
                emitTurn()
                if !pending.isEmpty {
                    let joined = pending.map(\.text).joined(separator: "\n\n")
                    let bodyId = "body-\(pending.first!.id)"
                    entries.append(ChatEntry(id: bodyId, kind: .body(
                        id: bodyId,
                        markdown: joined,
                        time: turnEnd
                    )))
                    pending.removeAll()
                }
                let text = message.blocks.first?.text ?? message.markdown
                entries.append(ChatEntry(
                    id: message.id,
                    kind: .user(text: text, time: message.createdAt)
                ))
                continue
            }
            for block in message.blocks {
                switch block.kind {
                case "reasoning":
                    foldPendingIntoTurn()
                    if items.isEmpty { turnStart = message.createdAt }
                    turnEnd = message.createdAt
                    items.append(WorkItem(
                        id: block.id,
                        kind: .thinking,
                        title: "思考 · 持续了几秒",
                        detail: block.text,
                        createdAt: message.createdAt
                    ))
                case "tool":
                    foldPendingIntoTurn()
                    if items.isEmpty { turnStart = message.createdAt }
                    turnEnd = message.createdAt
                    let name = (block.tool ?? "").lowercased()
                    let kind: WorkItem.Kind
                    let title: String
                    if let path = block.path {
                        let base = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? path
                        if name.contains("read") {
                            kind = .read; title = "读取 \(base)"
                        } else {
                            kind = .edit; title = "编辑 \(base)"
                        }
                    } else if name.contains("skill") {
                        kind = .skill; title = "技能 \(block.text)"
                    } else {
                        kind = .terminal; title = block.text
                    }
                    items.append(WorkItem(
                        id: block.id,
                        kind: kind,
                        title: title,
                        detail: block.text,
                        createdAt: message.createdAt
                    ))
                case "text":
                    let trimmed = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    pending.append((block.id, block.text))
                default:
                    break
                }
            }
        }
        // 会话收尾：最后一轮的已工作和正文。
        emitTurn()
        if !pending.isEmpty {
            let joined = pending.map(\.text).joined(separator: "\n\n")
            let bodyId = "body-\(pending.first!.id)"
            entries.append(ChatEntry(id: bodyId, kind: .body(
                id: bodyId,
                markdown: joined,
                time: turnEnd
            )))
        }
        return entries
    }
}
