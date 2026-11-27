public import Foundation

indirect enum MiniCBORValue: Sendable, Equatable {
    case unsigned(UInt64)
    case negative(UInt64)
    case bytes(Data)
    case text(String)
    case array([MiniCBORValue])
    case map([MiniCBORValue: MiniCBORValue])
    case simple(UInt8)
    case boolean(Bool)
    case null

    var integerValue: Int64? {
        switch self {
        case .unsigned(let value): return Int64(value)
        case .negative(let value): return -1 - Int64(value)
        default: return nil
        }
    }
}

extension MiniCBORValue: Hashable {}

struct MiniCBORParser {
    enum ParseError: Error {
        case truncated
        case unsupported
        case invalidUTF8
        case tooDeep
    }

    private let bytes: [UInt8]
    private var offset = 0

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func parse() throws -> MiniCBORValue {
        let value = try parseValue(depth: 0)
        guard offset == bytes.count else { throw ParseError.unsupported }
        return value
    }

    private mutating func parseValue(depth: Int) throws -> MiniCBORValue {
        guard depth < 32 else { throw ParseError.tooDeep }
        let initial = try readByte()
        let major = initial >> 5
        let additional = initial & 0x1f
        switch major {
        case 0: return .unsigned(try readLength(additional))
        case 1: return .negative(try readLength(additional))
        case 2:
            let length = Int(try readLength(additional))
            return .bytes(Data(try readBytes(count: length)))
        case 3:
            let length = Int(try readLength(additional))
            let raw = try readBytes(count: length)
            guard let string = String(data: Data(raw), encoding: .utf8) else { throw ParseError.invalidUTF8 }
            return .text(string)
        case 4:
            let count = Int(try readLength(additional))
            return .array(try (0..<count).map { _ in try parseValue(depth: depth + 1) })
        case 5:
            let count = Int(try readLength(additional))
            var map: [MiniCBORValue: MiniCBORValue] = [:]
            for _ in 0..<count {
                let key = try parseValue(depth: depth + 1)
                let value = try parseValue(depth: depth + 1)
                map[key] = value
            }
            return .map(map)
        case 6:
            _ = try readLength(additional)
            return try parseValue(depth: depth + 1)
        case 7:
            switch additional {
            case 20: return .boolean(false)
            case 21: return .boolean(true)
            case 22: return .null
            case 23: return .simple(23)
            case 24: return .simple(try readByte())
            default: throw ParseError.unsupported
            }
        default: throw ParseError.unsupported
        }
    }

    private mutating func readByte() throws -> UInt8 {
        guard offset < bytes.count else { throw ParseError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    private mutating func readBytes(count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= bytes.count else { throw ParseError.truncated }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    private mutating func readLength(_ additional: UInt8) throws -> UInt64 {
        switch additional {
        case 0...23: return UInt64(additional)
        case 24: return UInt64(try readByte())
        case 25:
            let raw = try readBytes(count: 2)
            return raw.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        case 26:
            let raw = try readBytes(count: 4)
            return raw.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        case 27:
            let raw = try readBytes(count: 8)
            return raw.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        default: throw ParseError.unsupported
        }
    }
}

enum WebAuthnBinaryInspector {
    struct AttestationMetadata {
        var backupEligible: Bool
        var backupState: Bool
        var userVerified: Bool
    }

    static func coseAlgorithm(publicKey: Data) -> Int? {
        guard var parser = Optional(MiniCBORParser(data: publicKey)), let root = try? parser.parse(), case .map(let map) = root else { return nil }
        for (key, value) in map where key.integerValue == 3 {
            return value.integerValue.map(Int.init)
        }
        return nil
    }

    static func attestationMetadata(attestationObject: Data) -> AttestationMetadata? {
        var parser = MiniCBORParser(data: attestationObject)
        guard let root = try? parser.parse(), case .map(let map) = root else { return nil }
        var format: String?
        var authData: Data?
        for (key, value) in map {
            guard case .text(let name) = key else { continue }
            if name == "fmt", case .text(let valueText) = value { format = valueText }
            if name == "authData", case .bytes(let bytes) = value { authData = bytes }
        }
        guard format == "none", let authData, authData.count >= 37 else { return nil }
        let flags = authData[authData.startIndex + 32]
        return AttestationMetadata(
            backupEligible: (flags & (1 << 3)) != 0,
            backupState: (flags & (1 << 4)) != 0,
            userVerified: (flags & (1 << 2)) != 0
        )
    }
}
