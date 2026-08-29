import Foundation
import UIKit

/// 后台通知监控：App 退到后台时接管官方 relay 连接，
/// 轮询任务状态，运行中 → 完成/出错 时弹本地横幅并可选推 Bark。
final class MonitorController {
    static let shared = MonitorController()

    let relay = OfficialRelay()

    private var pollTimer: Timer?
    private var lastStatus: [String: String] = [:]
    private var sawFirstSnapshot = false

    private init() {
        relay.monitorOnly = true
        relay.onSnapshot = { [weak self] in
            self?.diffAndNotify()
        }
    }

    var isMonitoring: Bool { relay.state != .idle }

    func start() {
        guard let raw = UserDefaults.standard.string(forKey: "officialURL"),
              let link = OfficialLinkParser.parse(raw)
        else { return }
        stopTimer()
        relay.monitorOnly = true
        relay.connect(link)
        // 配对成功后 relay 会自动 bootstrap 拉一次任务，之后定时刷新。
        let timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.relay.isPaired {
                self.relay.refreshWorkspaces()
            }
        }
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        stopTimer()
        relay.disconnect()
        sawFirstSnapshot = false
    }

    private func stopTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func diffAndNotify() {
        let tasks = relay.tasks
        defer {
            lastStatus = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.status) })
            sawFirstSnapshot = true
        }
        // 第一次快照只建基线，不通知，避免刚退后台就轰炸。
        guard sawFirstSnapshot else { return }
        for task in tasks {
            guard let old = lastStatus[task.id], old != task.status else { continue }
            let wasActive = old == "running" || old == "waiting"
            guard wasActive else { continue }
            if task.status == "completed" {
                fire(title: "任务完成", body: task.title, taskId: task.id)
            } else if task.status == "error" {
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
