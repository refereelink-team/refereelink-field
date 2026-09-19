import Foundation

nonisolated enum FieldWire {
    static let schemaVersion = "1.0"

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    static func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        let data = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }
}

nonisolated struct FieldTelemetryItem: Codable {
    let type: String
    let payload: AnyCodable

    init<T: Encodable>(type: String, payload: T) throws {
        self.type = type
        self.payload = try AnyCodable(FieldWire.jsonObject(payload))
    }

    func object() -> [String: Any] {
        var object: [String: Any] = ["type": type]
        if let fields = payload.value as? [String: Any] {
            object.merge(fields) { _, new in new }
        } else {
            object["payload"] = payload.value
        }
        return object
    }
}

nonisolated struct FieldTelemetryBatch: Codable {
    let type: String
    let schemaVersion: String
    let sessionId: UUID
    let streamEpoch: Int
    let clientSequence: Int
    let items: [FieldTelemetryItem]
}

nonisolated struct FieldHelloAck: Decodable {
    let type: String
    let schemaVersion: String
    let sessionId: UUID
    let serverSequence: Int?
    let maxBatchItems: Int?
    let clockProbeIntervalS: Int?
}

nonisolated struct FieldTelemetryAck: Decodable {
    let type: String
    let clientSequence: Int?
    let missingSequences: [Int]?
    let gapCount: Int?
}

nonisolated struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) throws {
        guard JSONSerialization.isValidJSONObject(["value": value]) else {
            throw FieldTransportError.invalidMessage
        }
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = NSNull(); return }
        if let value = try? container.decode(Bool.self) { self.value = value; return }
        if let value = try? container.decode(Int.self) { self.value = value; return }
        if let value = try? container.decode(Double.self) { self.value = value; return }
        if let value = try? container.decode(String.self) { self.value = value; return }
        if let value = try? container.decode([AnyCodable].self) {
            self.value = value.map(\.value)
            return
        }
        if let value = try? container.decode([String: AnyCodable].self) {
            self.value = value.mapValues(\.value)
            return
        }
        throw FieldTransportError.invalidMessage
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull: try container.encodeNil()
        case let value as Bool: try container.encode(value)
        case let value as Int: try container.encode(value)
        case let value as Double: try container.encode(value)
        case let value as String: try container.encode(value)
        case let value as [Any]: try container.encode(value.map { try? AnyCodable($0) }.compactMap { $0 })
        case let value as [String: Any]:
            try container.encode(value.compactMapValues { try? AnyCodable($0) })
        default: throw FieldTransportError.invalidMessage
        }
    }
}
