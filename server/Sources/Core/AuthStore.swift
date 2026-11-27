public import Foundation

public enum StoreWriteResult: Sendable, Equatable {
    case success
    case emailTaken
    case credentialExists
    case flowUnavailable
}

public enum EmailChangeStoreResult: Sendable, Equatable {
    case success
    case emailTaken
    case flowUnavailable
    case sessionUnavailable
}

public enum PasskeyDeletionResult: Sendable, Equatable {
    case deleted(remainingCredentialIDs: [Data])
    case notFound
    case lastPasskey
}

public protocol AuthStore: Sendable {
    func user(id: UUID) async throws -> User?
    func user(email: String) async throws -> User?
    func user(userHandle: Data) async throws -> User?
    func passkey(credentialID: Data) async throws -> Passkey?
    func passkeys(userID: UUID) async throws -> [Passkey]
    func session(tokenHash: Data) async throws -> Session?
    func session(id: UUID) async throws -> Session?
    func sessions(userID: UUID) async throws -> [Session]
    func emailVerification(id: UUID) async throws -> EmailVerification?
    func emailVerification(secretHash: Data) async throws -> EmailVerification?
    func latestEmailVerificationCreatedAt(email: String, purpose: VerificationPurpose) async throws -> Date?

    func invalidateActiveEmailVerifications(email: String, purpose: VerificationPurpose, at: Date) async throws
    func invalidateActiveEmailVerifications(email: String, at: Date) async throws
    func createEmailVerification(_ verification: EmailVerification) async throws
    func markEmailVerificationVerified(id: UUID, verifiedAt: Date, verifiedExpiresAt: Date) async throws
    func consumeFlowAndCreateRecoverySession(flowID: UUID, session: Session, consumedAt: Date) async throws -> Bool
    func changeEmailConsumingFlow(flowID: UUID, userID: UUID, newEmail: String, sessionID: UUID, newTokenHash: Data, at: Date) async throws -> EmailChangeStoreResult

    func insertChallenge(_ challenge: WebAuthnChallenge) async throws
    func consumeChallenge(_ challenge: Data) async throws -> WebAuthnChallenge?

    func createSession(_ session: Session, maximumPerUser: Int) async throws
    func rotateSessionToken(sessionID: UUID, newTokenHash: Data, reauthenticatedAt: Date?) async throws -> Session?
    func touchSession(sessionID: UUID, at: Date) async throws
    func deleteSession(id: UUID) async throws
    func deleteSessions(userID: UUID, except sessionID: UUID?) async throws

    func createUserWithPasskeyAndSession(user: User, passkey: Passkey, session: Session, consumeFlowID: UUID, consumedAt: Date) async throws -> StoreWriteResult
    func addPasskey(_ passkey: Passkey) async throws -> StoreWriteResult
    func completeRecovery(passkey: Passkey, recoverySessionID: UUID, newSession: Session, recoveredAt: Date) async throws -> StoreWriteResult
    func updatePasskeyAuthentication(credentialID: Data, newSignCount: Int64, signCountAnomalyAt: Date?, backupState: Bool, lastUsedAt: Date) async throws
    func renamePasskey(userID: UUID, credentialID: Data, name: String?) async throws -> Passkey?
    func deletePasskeyIfNotLast(userID: UUID, credentialID: Data) async throws -> PasskeyDeletionResult

    func setRecoveredAt(userID: UUID, at: Date) async throws
    func deleteUser(userID: UUID) async throws

    func incrementRateLimit(key: String, windowStart: Date) async throws -> Int
    func cleanupExpired(now: Date, idleBefore: Date, rateLimitWindowBefore: Date) async throws -> CleanupCounts
}
