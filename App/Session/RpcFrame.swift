import Foundation

struct BridgeIdentity {
    var bridgeSessionId: String
    var bridgeGeneration: Int?
    var recoveryId: String?
}

enum RpcFrame {
    static func encode(message: Data, identity: BridgeIdentity, seq: Int, messageSeq: Int) -> [String: Any] {
        var payload: [String: Any] = [
            "zcode_type": "rpc-frame",
            "bridgeSessionId": identity.bridgeSessionId,
            "seq": seq,
            "messageSeq": messageSeq,
            "fragmentIndex": 0,
            "fragmentCount": 1,
            "messageBytes": message.count,
            "checksum": [
                "algorithm": "crc32",
                "value": crc32Hex(message)
            ],
            "dataBase64": message.base64EncodedString()
        ]
        if let bridgeGeneration = identity.bridgeGeneration {
            payload["bridgeGeneration"] = bridgeGeneration
        }
        if let recoveryId = identity.recoveryId {
            payload["recoveryId"] = recoveryId
        }
        return payload
    }

    static func ack(identity: BridgeIdentity, messageSeq: Int) -> [String: Any] {
        var payload: [String: Any] = [
            "zcode_type": "rpc-frame-ack",
            "bridgeSessionId": identity.bridgeSessionId,
            "ackMessageSeq": messageSeq
        ]
        if let bridgeGeneration = identity.bridgeGeneration {
            payload["bridgeGeneration"] = bridgeGeneration
        }
        if let recoveryId = identity.recoveryId {
            payload["recoveryId"] = recoveryId
        }
        return payload
    }

    static func decodeMessage(_ payload: [String: Any]) -> (seq: Int, messageSeq: Int, data: Data)? {
        guard (payload["zcode_type"] as? String) == "rpc-frame",
              let base64 = payload["dataBase64"] as? String,
              let data = Data(base64Encoded: base64)
        else { return nil }
        let seq = intValue(payload["seq"])
        let messageSeq = intValue(payload["messageSeq"])
        return (seq, messageSeq, data)
    }

    static func crc32Hex(_ data: Data) -> String {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
            }
        }
        return String(format: "%08x", crc ^ 0xFFFFFFFF)
    }

    static func intValue(_ raw: Any?) -> Int {
        if let value = raw as? Int { return value }
        if let value = raw as? Double { return Int(value) }
        if let value = raw as? NSNumber { return value.intValue }
        return 0
    }
}
