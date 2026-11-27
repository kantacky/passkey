public import Foundation
public import Logging
public import WebAuthn

public struct AuthConfiguration: Sendable {
    public var rpID: String
    public var rpName: String
    public var origin: String
    public var challengeLifetime: TimeInterval
    public var emailVerificationLifetime: TimeInterval
    public var verifiedFlowLifetime: TimeInterval
    public var sessionIdleLifetime: TimeInterval
    public var sessionAbsoluteLifetime: TimeInterval
    public var recoverySessionLifetime: TimeInterval
    public var reauthenticationFreshness: TimeInterval
    public var recoveryRestriction: TimeInterval
    public var maximumSessionsPerUser: Int

    public init(
        rpID: String,
        rpName: String = "Passkey",
        origin: String,
        challengeLifetime: TimeInterval = 300,
        emailVerificationLifetime: TimeInterval = 600,
        verifiedFlowLifetime: TimeInterval = 900,
        sessionIdleLifetime: TimeInterval = 3600,
        sessionAbsoluteLifetime: TimeInterval = 24 * 3600,
        recoverySessionLifetime: TimeInterval = 900,
        reauthenticationFreshness: TimeInterval = 300,
        recoveryRestriction: TimeInterval = 24 * 3600,
        maximumSessionsPerUser: Int = 20
    ) {
        self.rpID = rpID
        self.rpName = rpName
        self.origin = origin
        self.challengeLifetime = challengeLifetime
        self.emailVerificationLifetime = emailVerificationLifetime
        self.verifiedFlowLifetime = verifiedFlowLifetime
        self.sessionIdleLifetime = sessionIdleLifetime
        self.sessionAbsoluteLifetime = sessionAbsoluteLifetime
        self.recoverySessionLifetime = recoverySessionLifetime
        self.reauthenticationFreshness = reauthenticationFreshness
        self.recoveryRestriction = recoveryRestriction
        self.maximumSessionsPerUser = maximumSessionsPerUser
    }
}

public struct AuthCore: Sendable {
    public let store: any AuthStore
    public let configuration: AuthConfiguration
    public let webAuthn: WebAuthnManager
    public let mailQueue: MailQueue
    public let aaguidCatalog: AAGUIDCatalog
    public let logger: Logger
    private let nowProvider: @Sendable () -> Date

    public init(
        store: any AuthStore,
        configuration: AuthConfiguration,
        mailQueue: MailQueue,
        aaguidCatalog: AAGUIDCatalog = .bundled(),
        logger: Logger = Logger(label: "passkey.core"),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.configuration = configuration
        self.webAuthn = WebAuthnManager(
            configuration: .init(
                relyingPartyID: configuration.rpID,
                relyingPartyName: configuration.rpName,
                relyingPartyOrigin: configuration.origin
            )
        )
        self.mailQueue = mailQueue
        self.aaguidCatalog = aaguidCatalog
        self.logger = logger
        self.nowProvider = now
    }

    public var now: Date { nowProvider() }

    public func tokenHash(_ token: String) -> Data {
        SecurityUtils.sha256(token)
    }

    public func makeSession(userID: UUID, kind: SessionKind, flowID: UUID? = nil, fromRecovery: Bool = false, deviceLabel: String, reauthenticated: Bool = true) -> IssuedSession {
        let current = now
        let token = SecurityUtils.randomToken()
        let lifetime = kind == .recovery ? configuration.recoverySessionLifetime : configuration.sessionAbsoluteLifetime
        let session = Session(
            id: SecurityUtils.uuidv7(at: current),
            userID: userID,
            tokenHash: tokenHash(token),
            kind: kind,
            flowID: flowID,
            fromRecovery: fromRecovery,
            deviceLabel: deviceLabel,
            reauthenticatedAt: reauthenticated ? current : nil,
            createdAt: current,
            lastSeenAt: current,
            expiresAt: current.addingTimeInterval(lifetime)
        )
        return IssuedSession(session: session, token: token)
    }

    public func authenticate(token: String, allowRecovery: Bool = false) async throws -> AuthenticatedContext {
        guard var session = try await store.session(tokenHash: tokenHash(token)) else {
            throw AuthError.unauthenticated
        }
        let current = now
        guard session.expiresAt > current, session.lastSeenAt.addingTimeInterval(configuration.sessionIdleLifetime) > current else {
            throw AuthError.unauthenticated
        }
        if session.kind == .recovery && !allowRecovery {
            throw AuthError.recoverySessionRestricted
        }
        guard let user = try await store.user(id: session.userID) else {
            throw AuthError.unauthenticated
        }
        if current.timeIntervalSince(session.lastSeenAt) >= 300 {
            try await store.touchSession(sessionID: session.id, at: current)
            session.lastSeenAt = current
        }
        return AuthenticatedContext(user: user, session: session)
    }

    public func requireReauthenticated(_ context: AuthenticatedContext) throws {
        guard context.session.kind == .normal else { throw AuthError.recoverySessionRestricted }
        guard let reauthenticatedAt = context.session.reauthenticatedAt,
              reauthenticatedAt.addingTimeInterval(configuration.reauthenticationFreshness) > now else {
            throw AuthError.reauthenticationRequired
        }
    }

    public func requireNotRecentlyRecovered(_ context: AuthenticatedContext) throws {
        guard context.session.fromRecovery,
              let recoveredAt = context.user.recoveredAt,
              recoveredAt.addingTimeInterval(configuration.recoveryRestriction) > now else { return }
        throw AuthError.recentlyRecovered
    }

    public func emailLogHash(_ email: String) -> String {
        SecurityUtils.sha256(SecurityUtils.normalizeEmail(email)).map { String(format: "%02x", $0) }.prefix(12).joined()
    }

    public func securityEvent(_ event: String, metadata: Logger.Metadata = [:]) {
        var merged: Logger.Metadata = ["event": "\(event)"]
        for (key, value) in metadata { merged[key] = value }
        logger.info("security_event", metadata: merged)
    }

    func validateClientData(_ bytes: [UInt8], expectedType: String) throws -> (challenge: Data, origin: String) {
        struct ClientData: Decodable {
            var type: String
            var challenge: String
            var origin: String
            var crossOrigin: Bool?
        }
        guard let decoded = try? JSONDecoder().decode(ClientData.self, from: Data(bytes)) else {
            throw AuthError.verificationFailed
        }
        guard decoded.type == expectedType else { throw AuthError.verificationFailed }
        guard decoded.origin == configuration.origin else { throw AuthError.originMismatch }
        guard decoded.crossOrigin != true else { throw AuthError.verificationFailed }
        guard let challenge = Data(pkBase64URL: decoded.challenge) else { throw AuthError.invalidChallenge }
        return (challenge, decoded.origin)
    }

    func consumeChallenge(_ challenge: Data) async throws -> WebAuthnChallenge {
        guard let stored = try await store.consumeChallenge(challenge), stored.expiresAt > now else {
            throw AuthError.invalidChallenge
        }
        return stored
    }

    func magicLink(flowID: UUID, token: String, client: ClientKind) -> String {
        let path = client == .ios ? "/app/verify" : "/verify"
        return "https://\(configuration.rpID)\(path)?flow=\(flowID.uuidString)#token=\(token)"
    }

    func verificationMail(email: String, purpose: VerificationPurpose, flowID: UUID, token: String, code: String, client: ClientKind) -> MailMessage {
        let action: String
        switch purpose {
        case .signup: action = "アカウント作成"
        case .recovery: action = "アカウント回復"
        case .emailChange: action = "メールアドレス変更"
        }
        let link = magicLink(flowID: flowID, token: token, client: client)
        return MailMessage(
            to: email,
            subject: "【\(code)】Passkey の\(action)確認コード",
            text: """
            確認コード: \(code)

            \(action)を続けるには、登録を始めた画面でこの 6 桁のコードを入力してください。
            同じ端末では次のリンクからも確認できます（10 分間有効、1 回限り）:
            \(link)

            このメールに心当たりがない場合は破棄してください。
            """
        )
    }

    func notificationMail(email: String, operation: String, deviceLabel: String, detail: String = "") -> MailMessage {
        MailMessage(
            to: email,
            subject: "Passkey アカウントの\(operation)",
            text: """
            Passkey アカウントで次の操作が行われました。

            操作: \(operation)
            日時: \(ISO8601DateFormatter().string(from: now))
            端末: \(deviceLabel)
            \(detail)

            心当たりがない場合は、速やかにアカウント回復を行い、不明なパスキーとセッションを失効させてください。
            """
        )
    }
}
