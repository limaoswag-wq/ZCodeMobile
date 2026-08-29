import Foundation
import Combine

final class AppSettings: ObservableObject {
    @Published var host: String {
        didSet { UserDefaults.standard.set(host, forKey: "host") }
    }
    @Published var port: String {
        didSet { UserDefaults.standard.set(port, forKey: "port") }
    }
    @Published var token: String {
        didSet { UserDefaults.standard.set(token, forKey: "token") }
    }
    @Published var barkEnabled: Bool {
        didSet { UserDefaults.standard.set(barkEnabled, forKey: "barkEnabled") }
    }
    @Published var barkURL: String {
        didSet { UserDefaults.standard.set(barkURL, forKey: "barkURL") }
    }
    @Published var keepAlive: Bool {
        didSet { UserDefaults.standard.set(keepAlive, forKey: "keepAlive") }
    }
    @Published var showReasoning: Bool {
        didSet { UserDefaults.standard.set(showReasoning, forKey: "showReasoning") }
    }
    @Published var officialURL: String {
        didSet { UserDefaults.standard.set(officialURL, forKey: "officialURL") }
    }

    var baseURL: URL? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, let portValue = Int(trimmedPort), portValue > 0 else { return nil }
        return URL(string: "http://\(trimmedHost):\(portValue)")
    }

    init() {
        host = UserDefaults.standard.string(forKey: "host") ?? ""
        port = UserDefaults.standard.string(forKey: "port") ?? "18765"
        token = UserDefaults.standard.string(forKey: "token") ?? ""
        barkEnabled = UserDefaults.standard.bool(forKey: "barkEnabled")
        barkURL = UserDefaults.standard.string(forKey: "barkURL") ?? ""
        keepAlive = UserDefaults.standard.object(forKey: "keepAlive") as? Bool ?? true
        showReasoning = UserDefaults.standard.bool(forKey: "showReasoning")
        officialURL = UserDefaults.standard.string(forKey: "officialURL") ?? ""
    }
}
