import Foundation

public indirect enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

extension JSONValue {
    static let passthroughMaximumBytes = 16 * 1_024
    static let passthroughMaximumDepth = 6
    static let passthroughMaximumProperties = 100
    static let passthroughMaximumKeyLength = 128

    func validatedPassthroughData() throws -> Data {
        guard case .object = self else {
            throw CalliopeiaSDKError.invalidRequest("passthrough must be a JSON object")
        }
        var propertyCount = 0
        try validate(depth: 1, propertyCount: &propertyCount)
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.passthroughMaximumBytes else {
            throw CalliopeiaSDKError.invalidRequest(
                "passthrough must be at most \(Self.passthroughMaximumBytes) UTF-8 bytes"
            )
        }
        return data
    }

    private func validate(depth: Int, propertyCount: inout Int) throws {
        guard depth <= Self.passthroughMaximumDepth else {
            throw CalliopeiaSDKError.invalidRequest(
                "passthrough must be at most \(Self.passthroughMaximumDepth) levels deep"
            )
        }
        switch self {
        case .number(let value):
            guard value.isFinite else {
                throw CalliopeiaSDKError.invalidRequest("passthrough numbers must be finite")
            }
        case .object(let value):
            for (key, child) in value {
                guard !key.isEmpty, key.count <= Self.passthroughMaximumKeyLength else {
                    throw CalliopeiaSDKError.invalidRequest(
                        "passthrough keys must be 1 to \(Self.passthroughMaximumKeyLength) characters"
                    )
                }
                guard !["__proto__", "prototype", "constructor"].contains(key) else {
                    throw CalliopeiaSDKError.invalidRequest("passthrough contains a forbidden key")
                }
                propertyCount += 1
                guard propertyCount <= Self.passthroughMaximumProperties else {
                    throw CalliopeiaSDKError.invalidRequest(
                        "passthrough must contain at most \(Self.passthroughMaximumProperties) properties"
                    )
                }
                try child.validate(depth: depth + 1, propertyCount: &propertyCount)
            }
        case .array(let value):
            for child in value {
                try child.validate(depth: depth + 1, propertyCount: &propertyCount)
            }
        case .string, .bool, .null:
            break
        }
    }
}
