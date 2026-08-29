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
    var updatedAt: Int
    var createdAt: Int

    var isRunning: Bool { status == "running" || status == "waiting" }
    var statusLabel: String {
        switch status {
        case "running": return "进行中"
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
    var createdAt: Int
    var blocks: [ChatBlock]

    var isUser: Bool { role == "user" }
    var markdown: String {
        blocks.filter { $0.kind == "text" }.map(\.text).joined(separator: "\n\n")
    }
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
