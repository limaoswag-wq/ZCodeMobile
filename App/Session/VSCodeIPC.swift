import Foundation

enum IPCValue {
    case undefined
    case string(String)
    case data(Data)
    case array([IPCValue])
    case object(Any)
    case int(Int)

    var jsonObject: Any? {
        switch self {
        case .undefined: return nil
        case .string(let value): return value
        case .data(let value): return value
        case .array(let values): return values.map { $0.jsonObject ?? NSNull() }
        case .object(let value): return value
        case .int(let value): return value
        }
    }

    var dictionary: [String: Any]? { jsonObject as? [String: Any] }
    var stringValue: String? {
        switch self {
        case .string(let value): return value
        default: return jsonObject as? String
        }
    }
}

enum VSCodeIPC {
    static let promise = 100
    static let initialize = 200
    static let promiseSuccess = 201
    static let promiseError = 202
    static let promiseErrorObj = 203
    static let eventFire = 204

    static func encode(_ value: Any?) -> Data {
        let writer = BufferWriter()
        write(value, into: writer)
        return writer.data
    }

    static func decode(_ data: Data) throws -> (IPCValue, Data) {
        var reader = BufferReader(data)
        let value = try read(from: &reader)
        return (value, reader.remaining)
    }

    static func decodePair(_ data: Data) throws -> (IPCValue, IPCValue) {
        var reader = BufferReader(data)
        let first = try read(from: &reader)
        let second = try read(from: &reader)
        return (first, second)
    }

    private static func write(_ value: Any?, into writer: BufferWriter) {
        guard let value else {
            writer.writeByte(0)
            return
        }
        if let number = value as? Int {
            writer.writeByte(6)
            writeVLQ(number, into: writer)
            return
        }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let intValue = number.intValue
            if NSNumber(value: intValue) == number {
                writer.writeByte(6)
                writeVLQ(intValue, into: writer)
                return
            }
        }
        if value is NSNull {
            writer.writeByte(0)
            return
        }
        if let string = value as? String {
            let data = Data(string.utf8)
            writer.writeByte(1)
            writeVLQ(data.count, into: writer)
            writer.write(data)
            return
        }
        if let data = value as? Data {
            writer.writeByte(3)
            writeVLQ(data.count, into: writer)
            writer.write(data)
            return
        }
        if let array = value as? [Any] {
            writer.writeByte(4)
            writeVLQ(array.count, into: writer)
            for item in array { write(item, into: writer) }
            return
        }
        if let array = value as? NSArray {
            writer.writeByte(4)
            writeVLQ(array.count, into: writer)
            for item in array { write(item, into: writer) }
            return
        }
        let json = (try? JSONSerialization.data(withJSONObject: value, options: [])) ?? Data("{}".utf8)
        writer.writeByte(5)
        writeVLQ(json.count, into: writer)
        writer.write(json)
    }

    private static func read(from reader: inout BufferReader) throws -> IPCValue {
        let type = try reader.readByte()
        switch type {
        case 0:
            return .undefined
        case 1:
            let count = try readVLQ(from: &reader)
            return .string(String(data: try reader.read(count), encoding: .utf8) ?? "")
        case 2, 3:
            let count = try readVLQ(from: &reader)
            return .data(try reader.read(count))
        case 4:
            let count = try readVLQ(from: &reader)
            var items: [IPCValue] = []
            items.reserveCapacity(count)
            for _ in 0..<count { items.append(try read(from: &reader)) }
            return .array(items)
        case 5:
            let count = try readVLQ(from: &reader)
            let json = try reader.read(count)
            let object = try JSONSerialization.jsonObject(with: json, options: [.fragmentsAllowed])
            return .object(object)
        case 6:
            return .int(try readVLQ(from: &reader))
        default:
            throw NSError(domain: "VSCodeIPC", code: 1, userInfo: [NSLocalizedDescriptionKey: "未知 IPC 类型 \(type)"])
        }
    }

    private static func writeVLQ(_ value: Int, into writer: BufferWriter) {
        var value = UInt(bitPattern: value)
        if value == 0 {
            writer.writeByte(0)
            return
        }
        var bytes: [UInt8] = []
        while value != 0 {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        }
        writer.write(Data(bytes))
    }

    private static func readVLQ(from reader: inout BufferReader) throws -> Int {
        var result = 0
        var shift = 0
        while true {
            let byte = try reader.readByte()
            result |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 35 {
                throw NSError(domain: "VSCodeIPC", code: 2, userInfo: [NSLocalizedDescriptionKey: "VLQ 过长"])
            }
        }
    }
}

final class BufferWriter {
    private var chunks: [Data] = []
    var data: Data { chunks.reduce(into: Data()) { $0.append($1) } }
    func writeByte(_ value: UInt8) { chunks.append(Data([value])) }
    func write(_ data: Data) { chunks.append(data) }
}

struct BufferReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) { self.data = data }

    var remaining: Data {
        let start = data.startIndex + offset
        guard start < data.endIndex else { return Data() }
        return data.subdata(in: start..<data.endIndex)
    }

    mutating func readByte() throws -> UInt8 {
        guard offset < data.count else {
            throw NSError(domain: "VSCodeIPC", code: 3, userInfo: [NSLocalizedDescriptionKey: "IPC 数据不完整"])
        }
        let value = data[data.startIndex + offset]
        offset += 1
        return value
    }

    mutating func read(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else {
            throw NSError(domain: "VSCodeIPC", code: 3, userInfo: [NSLocalizedDescriptionKey: "IPC 数据不完整"])
        }
        let slice = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + count))
        offset += count
        return slice
    }
}

final class ChannelClient {
    private var sendRaw: (Data) -> Void
    private var nextId = 0
    private var pending: [Int: CheckedContinuation<IPCValue, Error>] = [:]
    private var initialized = false
    private var waiters: [Int: CheckedContinuation<Void, Error>] = [:]
    private var nextWaiter = 0
    /// 桌面端 EventFire（204）推送：订阅会话的实时帧从这里出来。
    var onEvent: ((IPCValue) -> Void)?

    init(sendRaw: @escaping (Data) -> Void) {
        self.sendRaw = sendRaw
    }

    func reset(sendRaw: @escaping (Data) -> Void) {
        failAll(NSError(domain: "VSCodeIPC", code: 4, userInfo: [NSLocalizedDescriptionKey: "工作区桥已重置"]))
        self.sendRaw = sendRaw
        nextId = 0
        initialized = false
    }

    func receive(_ data: Data) {
        guard let pair = try? VSCodeIPC.decodePair(data) else { return }
        let header = pair.0
        let payload = pair.1
        guard case .array(let items) = header, let first = items.first, case .int(let type) = first else { return }
        if type == VSCodeIPC.initialize {
            initialized = true
            let waiters = self.waiters
            self.waiters.removeAll()
            waiters.values.forEach { $0.resume() }
            return
        }
        guard items.count > 1, case .int(let id) = items[1] else { return }
        if type == VSCodeIPC.eventFire {
            onEvent?(payload)
            return
        }
        guard let continuation = pending.removeValue(forKey: id) else { return }
        switch type {
        case VSCodeIPC.promiseSuccess:
            continuation.resume(returning: payload)
        case VSCodeIPC.promiseError:
            let message = payload.dictionary?["message"] as? String ?? "桌面端返回错误"
            continuation.resume(throwing: NSError(domain: "VSCodeIPC", code: 5, userInfo: [NSLocalizedDescriptionKey: message]))
        default:
            continuation.resume(throwing: NSError(domain: "VSCodeIPC", code: 6, userInfo: [NSLocalizedDescriptionKey: "桌面端拒绝了这次调用"]))
        }
    }

    func call(channel: String, method: String, args: [Any] = []) async throws -> IPCValue {
        try await waitUntilInitialized()
        let id = nextId
        nextId += 1
        let header: [Any] = [VSCodeIPC.promise, id, channel, method]
        var packet = VSCodeIPC.encode(header)
        packet.append(VSCodeIPC.encode(args))
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            sendRaw(packet)
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self, let pending = self.pending.removeValue(forKey: id) else { return }
                pending.resume(throwing: NSError(domain: "VSCodeIPC", code: 7, userInfo: [NSLocalizedDescriptionKey: "桌面端没有回应"]))
            }
        }
    }

    private func waitUntilInitialized() async throws {
        if initialized { return }
        let waiterId = nextWaiter
        nextWaiter += 1
        try await withCheckedThrowingContinuation { continuation in
            waiters[waiterId] = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, let pending = self.waiters.removeValue(forKey: waiterId) else { return }
                pending.resume(throwing: NSError(domain: "VSCodeIPC", code: 8, userInfo: [NSLocalizedDescriptionKey: "工作区桥还没准备好"]))
            }
        }
    }

    func failAll(_ error: Error) {
        let pending = self.pending
        self.pending.removeAll()
        pending.values.forEach { $0.resume(throwing: error) }
        let waiters = self.waiters
        self.waiters.removeAll()
        waiters.values.forEach { $0.resume(throwing: error) }
        initialized = false
    }
}
