import Crypto
public import Foundation

public enum SecurityUtils {
    public static func randomBytes(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) })
    }

    public static func randomToken(byteCount: Int = 32) -> String {
        randomBytes(count: byteCount).pkBase64URLEncodedString()
    }

    public static func randomCode() -> String {
        var generator = SystemRandomNumberGenerator()
        let value = Int.random(in: 0...999_999, using: &generator)
        return String(format: "%06d", value)
    }

    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    public static func sha256(_ string: String) -> Data {
        sha256(Data(string.utf8))
    }

    public static func normalizeEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func normalizeClientIP(_ ip: String) -> String {
        let value = ip.lowercased()
        guard value.contains(":"), !value.contains(".") else { return value }

        let groups: [String]
        if value.contains("::") {
            let parts = value.components(separatedBy: "::")
            guard parts.count <= 2 else { return value }
            let head = parts[0].isEmpty ? [] : parts[0].components(separatedBy: ":")
            let tail = parts.count == 2 && !parts[1].isEmpty ? parts[1].components(separatedBy: ":") : []
            let missing = 8 - head.count - tail.count
            guard missing >= 0 else { return value }
            groups = head + Array(repeating: "0", count: missing) + tail
        } else {
            groups = value.components(separatedBy: ":")
        }
        guard groups.count == 8 else { return value }
        let normalized = groups.map { group in
            let trimmed = group.drop(while: { $0 == "0" })
            return trimmed.isEmpty ? "0" : String(trimmed)
        }
        return normalized.prefix(4).joined(separator: ":") + "::/64"
    }

    public static func hourWindowStart(for date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 3600) * 3600)
    }


    public static func uuidv7(at date: Date = Date()) -> UUID {
        let milliseconds = UInt64(date.timeIntervalSince1970 * 1000) & 0xffff_ffff_ffff
        var random = [UInt8](randomBytes(count: 10))
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<6 {
            bytes[index] = UInt8((milliseconds >> UInt64((5 - index) * 8)) & 0xff)
        }
        bytes[6] = 0x70 | (random[0] & 0x0f)
        bytes[7] = random[1]
        bytes[8] = 0x80 | (random[2] & 0x3f)
        for index in 0..<7 { bytes[9 + index] = random[3 + index] }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    public static func deviceLabel(userAgent: String?, client: ClientKind) -> String {
        guard let userAgent, !userAgent.isEmpty else { return client == .ios ? "iOS アプリ" : "不明なブラウザ" }
        if client == .ios || userAgent.hasPrefix("Passkey-iOS/") { return String(userAgent.prefix(160)) }
        let browser: String
        if userAgent.contains("Edg/") { browser = "Edge" }
        else if userAgent.contains("Chrome/") { browser = "Chrome" }
        else if userAgent.contains("Firefox/") { browser = "Firefox" }
        else if userAgent.contains("Safari/") { browser = "Safari" }
        else { browser = "ブラウザ" }
        let os: String
        if userAgent.contains("iPhone") || userAgent.contains("iPad") { os = "iOS" }
        else if userAgent.contains("Mac OS X") { os = "macOS" }
        else if userAgent.contains("Windows") { os = "Windows" }
        else if userAgent.contains("Android") { os = "Android" }
        else if userAgent.contains("Linux") { os = "Linux" }
        else { os = "不明な OS" }
        return "\(browser) (\(os))"
    }
}

extension Data {
    public func pkBase64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public init?(pkBase64URL string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        self.init(base64Encoded: base64)
    }
}
