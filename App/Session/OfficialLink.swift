import Foundation
import CryptoKit

struct OfficialLink: Equatable {
    var origin: String
    var remotePath: String
    var deviceSid: String
    var passHash: String
    var timestamp: Int
    var deviceMid: String?
    var deviceName: String?
    var appVersion: String?
    var theme: String?

    var relayWebSocketURL: URL? {
        guard let url = URL(string: origin) else { return nil }
        var ws = URLComponents()
        ws.scheme = (url.scheme == "http") ? "ws" : "wss"
        ws.host = url.host
        ws.port = url.port
        ws.path = "/ws"
        if let deviceMid, !deviceMid.isEmpty {
            ws.queryItems = [URLQueryItem(name: "mid", value: deviceMid)]
        }
        return ws.url
    }

    var displayName: String {
        if let deviceName, !deviceName.isEmpty { return deviceName }
        return URL(string: origin)?.host ?? "ZCode"
    }
}

enum OfficialLinkParser {
    static func parse(_ raw: String) -> OfficialLink? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let items = comps.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let sid = value("sid"), !sid.isEmpty,
              let hash = value("hash"), !hash.isEmpty,
              let t = value("t"), let timestamp = Int(t)
        else { return nil }
        var origin = "https://zcode.z.ai"
        if let scheme = comps.scheme, let host = comps.host {
            origin = "\(scheme)://\(host)"
            if let port = comps.port { origin += ":\(port)" }
        }
        let path = comps.path.isEmpty ? "/remote/v4" : comps.path
        return OfficialLink(
            origin: origin,
            remotePath: path,
            deviceSid: sid,
            passHash: hash,
            timestamp: timestamp,
            deviceMid: value("mid"),
            deviceName: value("name"),
            appVersion: value("app_version"),
            theme: value("theme")
        )
    }
}

enum OfficialProof {
    static func hmacBase64URL(passHash: String, nonce: String, role: String, deviceSid: String) -> String {
        let message = "\(nonce)|\(role)|\(deviceSid)"
        let key = SymmetricKey(data: Data(passHash.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return Data(mac).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
