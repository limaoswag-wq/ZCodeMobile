import Foundation
import UIKit

/// 后台通知监控：App 退到后台时接管官方 relay 连接，
/// 轮询任务状态，运行中 → 完成/出错 时弹本地横幅并可选推 Bark。
final class MonitorController {
    static let shared = MonitorController()

    let relay = OfficialRelay()

    private var pollTimer: Timer?
    private var startToken = 0
    private var lastStatus: [String: String] = [:]

    private init() {
        relay.monitorOnly = true
        relay.onSnapshot = { [weak self] in
            self?.diffAndNotify()
        }
    }

    var isMonitoring: Bool { relay.state != .idle }

    /// 后台延迟启动：先给官方网页时间优雅断开自己的连接，避免把网页踢下线。
    func scheduleStart(after seconds: TimeInterval = 2.5) {
        startToken += 1
        let token = startToken
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, token == self.startToken else { return }
            self.start()
        }
    }

    func cancelScheduledStart() {
        startToken += 1
    }

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
        cancelScheduledStart()
        stopTimer()
        relay.disconnect()
        // lastStatus 保留：交接空档期完成的任务靠 updatedAt 判新鲜度，不漏报。
    }

    private func stopTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func diffAndNotify() {
        let tasks = relay.tasks
        defer {
            lastStatus = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.status) })
        }
        let now = Date().timeIntervalSince1970 * 1000
        for task in tasks {
            guard let old = lastStatus[task.id], old != task.status else { continue }
            let wasActive = old == "running" || old == "waiting"
            guard wasActive else { continue }
            guard task.status == "completed" || task.status == "error" else { continue }
            // 只报最近完成/出错的：过滤前台网页期间已看过、或基线过旧的变化。
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
