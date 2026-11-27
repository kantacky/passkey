public import Foundation

public struct AuthError: Error, Sendable, Equatable {
    public var statusCode: Int
    public var code: String
    public var message: String
    public var retryAfter: Int?

    public init(statusCode: Int, code: String, message: String, retryAfter: Int? = nil) {
        self.statusCode = statusCode
        self.code = code
        self.message = message
        self.retryAfter = retryAfter
    }

    public static func invalidRequest(_ message: String = "入力が正しくありません") -> Self {
        Self(statusCode: 400, code: "invalid_request", message: message)
    }
    public static let invalidChallenge = Self(statusCode: 400, code: "invalid_challenge", message: "チャレンジが無効です")
    public static let invalidCode = Self(statusCode: 400, code: "invalid_code", message: "コードが正しくありません")
    public static let verificationFailed = Self(statusCode: 400, code: "verification_failed", message: "パスキーの検証に失敗しました")
    public static let unauthenticated = Self(statusCode: 401, code: "unauthenticated", message: "サインインが必要です")
    public static let unknownCredential = Self(statusCode: 401, code: "unknown_credential", message: "このパスキーは使えません")
    public static let originMismatch = Self(statusCode: 403, code: "origin_mismatch", message: "Origin が一致しません")
    public static let deviceMismatch = Self(statusCode: 403, code: "device_mismatch", message: "登録を始めた画面でコードを入力してください")
    public static let reauthenticationRequired = Self(statusCode: 403, code: "reauthentication_required", message: "再認証が必要です")
    public static let recoverySessionRestricted = Self(statusCode: 403, code: "recovery_session_restricted", message: "回復セッションではこの操作はできません")
    public static let recentlyRecovered = Self(statusCode: 403, code: "recently_recovered", message: "回復後 24 時間はこの操作を実行できません")
    public static let notFound = Self(statusCode: 404, code: "not_found", message: "見つかりません")
    public static let lastPasskey = Self(statusCode: 409, code: "last_passkey", message: "最後のパスキーは削除できません")
    public static let credentialExists = Self(statusCode: 409, code: "credential_exists", message: "このパスキーは登録済みです")
    public static let emailTaken = Self(statusCode: 409, code: "email_taken", message: "このメールアドレスは既に使われています")
    public static let flowExpired = Self(statusCode: 410, code: "flow_expired", message: "時間切れです")
    public static let rateLimited = Self(statusCode: 429, code: "rate_limited", message: "しばらくしてから再試行してください")
}
