public import Foundation

public enum ClientKind: String, Codable, Sendable, Equatable {
    case web
    case ios
}

public enum VerificationPurpose: String, Codable, Sendable, Equatable {
    case signup
    case recovery
    case emailChange = "email_change"
}

public enum ChallengePurpose: String, Codable, Sendable, Equatable {
    case signup
    case addPasskey = "add_passkey"
    case recovery
    case authentication
    case reauthentication
}

public enum SessionKind: String, Codable, Sendable, Equatable {
    case normal
    case recovery
}

public enum FlowStatus: String, Codable, Sendable, Equatable {
    case pending
    case verified
    case consumed
    case expired
}

public struct User: Sendable, Equatable {
    public var id: UUID
    public var userHandle: Data
    public var email: String
    public var createdAt: Date
    public var recoveredAt: Date?

    public init(id: UUID, userHandle: Data, email: String, createdAt: Date, recoveredAt: Date? = nil) {
        self.id = id
        self.userHandle = userHandle
        self.email = email
        self.createdAt = createdAt
        self.recoveredAt = recoveredAt
    }
}

public struct Passkey: Sendable, Equatable {
    public var id: Data
    public var userID: UUID
    public var publicKey: Data
    public var alg: Int
    public var signCount: Int64
    public var signCountAnomalyAt: Date?
    public var aaguid: UUID?
    public var transports: [String]
    public var uvInitialized: Bool
    public var backupEligible: Bool
    public var backupState: Bool
    public var name: String?
    public var createdAt: Date
    public var lastUsedAt: Date?

    public init(
        id: Data,
        userID: UUID,
        publicKey: Data,
        alg: Int,
        signCount: Int64,
        signCountAnomalyAt: Date? = nil,
        aaguid: UUID?,
        transports: [String],
        uvInitialized: Bool,
        backupEligible: Bool,
        backupState: Bool,
        name: String? = nil,
        createdAt: Date,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.userID = userID
        self.publicKey = publicKey
        self.alg = alg
        self.signCount = signCount
        self.signCountAnomalyAt = signCountAnomalyAt
        self.aaguid = aaguid
        self.transports = transports
        self.uvInitialized = uvInitialized
        self.backupEligible = backupEligible
        self.backupState = backupState
        self.name = name
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

public struct WebAuthnChallenge: Sendable, Equatable {
    public var id: UUID
    public var challenge: Data
    public var purpose: ChallengePurpose
    public var userID: UUID?
    public var sessionID: UUID?
    public var flowID: UUID?
    public var userHandle: Data?
    public var expiresAt: Date

    public init(
        id: UUID,
        challenge: Data,
        purpose: ChallengePurpose,
        userID: UUID? = nil,
        sessionID: UUID? = nil,
        flowID: UUID? = nil,
        userHandle: Data? = nil,
        expiresAt: Date
    ) {
        self.id = id
        self.challenge = challenge
        self.purpose = purpose
        self.userID = userID
        self.sessionID = sessionID
        self.flowID = flowID
        self.userHandle = userHandle
        self.expiresAt = expiresAt
    }
}

public struct EmailVerification: Sendable, Equatable {
    public var id: UUID
    public var email: String
    public var purpose: VerificationPurpose
    public var sessionID: UUID?
    public var client: ClientKind
    public var tokenHash: Data
    public var codeHash: Data
    public var secretHash: Data
    public var createdAt: Date
    public var verifiedAt: Date?
    public var verifiedExpiresAt: Date?
    public var consumedAt: Date?
    public var invalidatedAt: Date?
    public var expiresAt: Date

    public init(
        id: UUID,
        email: String,
        purpose: VerificationPurpose,
        sessionID: UUID?,
        client: ClientKind,
        tokenHash: Data,
        codeHash: Data,
        secretHash: Data,
        createdAt: Date,
        verifiedAt: Date? = nil,
        verifiedExpiresAt: Date? = nil,
        consumedAt: Date? = nil,
        invalidatedAt: Date? = nil,
        expiresAt: Date
    ) {
        self.id = id
        self.email = email
        self.purpose = purpose
        self.sessionID = sessionID
        self.client = client
        self.tokenHash = tokenHash
        self.codeHash = codeHash
        self.secretHash = secretHash
        self.createdAt = createdAt
        self.verifiedAt = verifiedAt
        self.verifiedExpiresAt = verifiedExpiresAt
        self.consumedAt = consumedAt
        self.invalidatedAt = invalidatedAt
        self.expiresAt = expiresAt
    }

    public func status(at now: Date) -> FlowStatus {
        if consumedAt != nil { return .consumed }
        if invalidatedAt != nil { return .expired }
        if verifiedAt != nil {
            guard let verifiedExpiresAt, verifiedExpiresAt > now else { return .expired }
            return .verified
        }
        return expiresAt > now ? .pending : .expired
    }
}

public struct Session: Sendable, Equatable {
    public var id: UUID
    public var userID: UUID
    public var tokenHash: Data
    public var kind: SessionKind
    public var flowID: UUID?
    public var fromRecovery: Bool
    public var deviceLabel: String
    public var reauthenticatedAt: Date?
    public var createdAt: Date
    public var lastSeenAt: Date
    public var expiresAt: Date

    public init(
        id: UUID,
        userID: UUID,
        tokenHash: Data,
        kind: SessionKind,
        flowID: UUID? = nil,
        fromRecovery: Bool = false,
        deviceLabel: String,
        reauthenticatedAt: Date?,
        createdAt: Date,
        lastSeenAt: Date,
        expiresAt: Date
    ) {
        self.id = id
        self.userID = userID
        self.tokenHash = tokenHash
        self.kind = kind
        self.flowID = flowID
        self.fromRecovery = fromRecovery
        self.deviceLabel = deviceLabel
        self.reauthenticatedAt = reauthenticatedAt
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.expiresAt = expiresAt
    }
}

public struct AuthenticatedContext: Sendable, Equatable {
    public var user: User
    public var session: Session

    public init(user: User, session: Session) {
        self.user = user
        self.session = session
    }
}

public struct IssuedSession: Sendable, Equatable {
    public var session: Session
    public var token: String

    public init(session: Session, token: String) {
        self.session = session
        self.token = token
    }
}

public struct CleanupCounts: Sendable, Equatable {
    public var challenges: Int
    public var emailVerifications: Int
    public var sessions: Int
    public var rateLimitCounters: Int

    public init(challenges: Int, emailVerifications: Int, sessions: Int, rateLimitCounters: Int) {
        self.challenges = challenges
        self.emailVerifications = emailVerifications
        self.sessions = sessions
        self.rateLimitCounters = rateLimitCounters
    }
}
