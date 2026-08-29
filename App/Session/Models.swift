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

struct ChatBlock: Codable, Identifiable, Hashable {
    var id: String
    var kind: String
    var text: String
    var tool: String?
    var status: String?

    init(id: String, kind: String, text: String, tool: String? = nil, status: String? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.tool = tool
        self.status = status
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

/// 时间线里的一条过程记录（思考 / 技能 / 终端 / 读取）。
struct WorkItem: Identifiable, Hashable {
    enum Kind: String {
        case thinking
        case skill
        case terminal
        case read
        case text
    }

    var id: String
    var kind: Kind
    var title: String
    var detail: String
    var createdAt: Int
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
    /// 把按时间排序的会话行分组成：用户气泡 / 已工作折叠块 / 正文。
    /// 过程内容（思考、技能、终端、读取、中间解说）全部进「已工作」；
    /// 一轮里最后一次工具/思考之后的文本才是正文。
    static func build(messages: [ChatMessage]) -> [ChatEntry] {
        var entries: [ChatEntry] = []
        var items: [WorkItem] = []
        var workStart = 0
        var workEnd = 0
        var pending: [(id: String, text: String)] = []

        func flushWork(includePending: Bool) {
            if includePending {
                for p in pending {
                    items.append(WorkItem(
                        id: "\(p.id)-mid",
                        kind: .text,
                        title: "",
                        detail: p.text,
                        createdAt: workEnd
                    ))
                }
            }
            pending.removeAll()
            guard !items.isEmpty else { return }
            let id = "work-\(items.first!.id)"
            entries.append(ChatEntry(id: id, kind: .work(
                id: id,
                items: items,
                startMs: workStart,
                endMs: workEnd,
                running: false
            )))
            items.removeAll()
        }

        for message in messages {
            if message.isUser {
                flushWork(includePending: true)
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
                    if !pending.isEmpty { flushWork(includePending: true) }
                    if items.isEmpty { workStart = message.createdAt }
                    workEnd = message.createdAt
                    items.append(WorkItem(
                        id: block.id,
                        kind: .thinking,
                        title: "思考 · 持续了几秒",
                        detail: block.text,
                        createdAt: message.createdAt
                    ))
                case "tool":
                    if !pending.isEmpty { flushWork(includePending: true) }
                    if items.isEmpty { workStart = message.createdAt }
                    workEnd = message.createdAt
                    let name = block.tool ?? ""
                    let kind: WorkItem.Kind
                    let title: String
                    if name.lowercased().contains("skill") {
                        kind = .skill; title = "技能 \(block.text)"
                    } else if name.lowercased().contains("read") {
                        kind = .read; title = "读取 \(block.text)"
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
        // 收尾：最后一批没跟工具的文本就是正文。
        flushWork(includePending: false)
        if !pending.isEmpty {
            let joined = pending.map(\.text).joined(separator: "\n\n")
            let bodyId = "body-\(pending.first!.id)"
            entries.append(ChatEntry(id: bodyId, kind: .body(
                id: bodyId,
                markdown: joined,
                time: workEnd
            )))
        }
        return entries
    }
}
