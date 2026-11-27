public import Core
public import Foundation

public actor InMemoryAuthStore: AuthStore {
    private var users: [UUID: User] = [:]
    private var passkeysByID: [Data: Passkey] = [:]
    private var challenges: [Data: WebAuthnChallenge] = [:]
    private var emailVerifications: [UUID: EmailVerification] = [:]
    private var sessionsByID: [UUID: Session] = [:]
    private var rateLimits: [String: Int] = [:]

    public init() {}

    public func user(id: UUID) throws -> User? { users[id] }

    public func user(email: String) throws -> User? {
        let normalized = SecurityUtils.normalizeEmail(email)
        return users.values.first { SecurityUtils.normalizeEmail($0.email) == normalized }
    }

    public func user(userHandle: Data) throws -> User? {
        users.values.first { $0.userHandle == userHandle }
    }

    public func passkey(credentialID: Data) throws -> Passkey? { passkeysByID[credentialID] }

    public func passkeys(userID: UUID) throws -> [Passkey] {
        passkeysByID.values.filter { $0.userID == userID }.sorted { $0.createdAt < $1.createdAt }
    }

    public func session(tokenHash: Data) throws -> Session? {
        sessionsByID.values.first { $0.tokenHash == tokenHash }
    }

    public func session(id: UUID) throws -> Session? { sessionsByID[id] }

    public func sessions(userID: UUID) throws -> [Session] {
        sessionsByID.values.filter { $0.userID == userID }.sorted { $0.createdAt < $1.createdAt }
    }

    public func emailVerification(id: UUID) throws -> EmailVerification? { emailVerifications[id] }

    public func emailVerification(secretHash: Data) throws -> EmailVerification? {
        emailVerifications.values.first { $0.secretHash == secretHash }
    }

    public func latestEmailVerificationCreatedAt(email: String, purpose: VerificationPurpose) throws -> Date? {
        let normalized = SecurityUtils.normalizeEmail(email)
        return emailVerifications.values
            .filter { SecurityUtils.normalizeEmail($0.email) == normalized && $0.purpose == purpose }
            .map(\.createdAt)
            .max()
    }

    public func invalidateActiveEmailVerifications(email: String, purpose: VerificationPurpose, at: Date) throws {
        let normalized = SecurityUtils.normalizeEmail(email)
        for (id, flow) in emailVerifications where SecurityUtils.normalizeEmail(flow.email) == normalized && flow.purpose == purpose && flow.consumedAt == nil && flow.invalidatedAt == nil {
            var copy = flow
            copy.invalidatedAt = at
            emailVerifications[id] = copy
        }
    }

    public func invalidateActiveEmailVerifications(email: String, at: Date) throws {
        let normalized = SecurityUtils.normalizeEmail(email)
        for (id, flow) in emailVerifications where SecurityUtils.normalizeEmail(flow.email) == normalized && flow.consumedAt == nil && flow.invalidatedAt == nil {
            var copy = flow
            copy.invalidatedAt = at
            emailVerifications[id] = copy
        }
    }

    public func createEmailVerification(_ verification: EmailVerification) throws {
        emailVerifications[verification.id] = verification
    }

    public func markEmailVerificationVerified(id: UUID, verifiedAt: Date, verifiedExpiresAt: Date) throws {
        guard var flow = emailVerifications[id], flow.consumedAt == nil, flow.invalidatedAt == nil else { return }
        flow.verifiedAt = verifiedAt
        flow.verifiedExpiresAt = verifiedExpiresAt
        emailVerifications[id] = flow
    }

    public func consumeFlowAndCreateRecoverySession(flowID: UUID, session: Session, consumedAt: Date) throws -> Bool {
        guard var flow = emailVerifications[flowID],
              flow.status(at: consumedAt) == .pending,
              sessionsByID.values.contains(where: { $0.tokenHash == session.tokenHash }) == false else { return false }
        flow.consumedAt = consumedAt
        emailVerifications[flowID] = flow
        sessionsByID[session.id] = session
        enforceSessionLimit(userID: session.userID, maximum: 20)
        return true
    }

    public func changeEmailConsumingFlow(flowID: UUID, userID: UUID, newEmail: String, sessionID: UUID, newTokenHash: Data, at: Date) throws -> EmailChangeStoreResult {
        guard var flow = emailVerifications[flowID], flow.status(at: at) == .pending else { return .flowUnavailable }
        guard var session = sessionsByID[sessionID], session.userID == userID else { return .sessionUnavailable }
        let normalized = SecurityUtils.normalizeEmail(newEmail)
        if users.values.contains(where: { $0.id != userID && SecurityUtils.normalizeEmail($0.email) == normalized }) {
            return .emailTaken
        }
        guard var user = users[userID] else { return .sessionUnavailable }
        user.email = normalized
        users[userID] = user
        flow.consumedAt = at
        emailVerifications[flowID] = flow
        session.tokenHash = newTokenHash
        sessionsByID[sessionID] = session
        for (id, other) in sessionsByID where other.userID == userID && id != sessionID {
            sessionsByID.removeValue(forKey: id)
        }
        return .success
    }

    public func insertChallenge(_ challenge: WebAuthnChallenge) throws {
        challenges[challenge.challenge] = challenge
    }

    public func consumeChallenge(_ challenge: Data) throws -> WebAuthnChallenge? {
        challenges.removeValue(forKey: challenge)
    }

    public func createSession(_ session: Session, maximumPerUser: Int) throws {
        sessionsByID[session.id] = session
        enforceSessionLimit(userID: session.userID, maximum: maximumPerUser)
    }

    public func rotateSessionToken(sessionID: UUID, newTokenHash: Data, reauthenticatedAt: Date?) throws -> Session? {
        guard var session = sessionsByID[sessionID] else { return nil }
        session.tokenHash = newTokenHash
        if let reauthenticatedAt { session.reauthenticatedAt = reauthenticatedAt }
        sessionsByID[sessionID] = session
        return session
    }

    public func touchSession(sessionID: UUID, at: Date) throws {
        guard var session = sessionsByID[sessionID] else { return }
        session.lastSeenAt = at
        sessionsByID[sessionID] = session
    }

    public func deleteSession(id: UUID) throws {
        sessionsByID.removeValue(forKey: id)
    }

    public func deleteSessions(userID: UUID, except sessionID: UUID?) throws {
        for (id, session) in sessionsByID where session.userID == userID && id != sessionID {
            sessionsByID.removeValue(forKey: id)
        }
    }

    public func createUserWithPasskeyAndSession(user: User, passkey: Passkey, session: Session, consumeFlowID: UUID, consumedAt: Date) throws -> StoreWriteResult {
        guard var flow = emailVerifications[consumeFlowID], flow.status(at: consumedAt) == .verified else { return .flowUnavailable }
        if users.values.contains(where: { SecurityUtils.normalizeEmail($0.email) == SecurityUtils.normalizeEmail(user.email) }) { return .emailTaken }
        if passkeysByID[passkey.id] != nil { return .credentialExists }
        users[user.id] = user
        passkeysByID[passkey.id] = passkey
        sessionsByID[session.id] = session
        flow.consumedAt = consumedAt
        emailVerifications[consumeFlowID] = flow
        enforceSessionLimit(userID: user.id, maximum: 20)
        return .success
    }

    public func addPasskey(_ passkey: Passkey) throws -> StoreWriteResult {
        guard passkeysByID[passkey.id] == nil else { return .credentialExists }
        passkeysByID[passkey.id] = passkey
        return .success
    }

    public func completeRecovery(passkey: Passkey, recoverySessionID: UUID, newSession: Session, recoveredAt: Date) throws -> StoreWriteResult {
        guard passkeysByID[passkey.id] == nil else { return .credentialExists }
        guard var user = users[passkey.userID], sessionsByID[recoverySessionID]?.userID == passkey.userID else { return .flowUnavailable }
        passkeysByID[passkey.id] = passkey
        user.recoveredAt = recoveredAt
        users[user.id] = user
        for (id, session) in sessionsByID where session.userID == user.id {
            sessionsByID.removeValue(forKey: id)
        }
        sessionsByID[newSession.id] = newSession
        return .success
    }

    public func updatePasskeyAuthentication(credentialID: Data, newSignCount: Int64, signCountAnomalyAt: Date?, backupState: Bool, lastUsedAt: Date) throws {
        guard var passkey = passkeysByID[credentialID] else { return }
        if newSignCount > passkey.signCount { passkey.signCount = newSignCount }
        if let signCountAnomalyAt { passkey.signCountAnomalyAt = signCountAnomalyAt }
        passkey.backupState = backupState
        passkey.uvInitialized = true
        passkey.lastUsedAt = lastUsedAt
        passkeysByID[credentialID] = passkey
    }

    public func renamePasskey(userID: UUID, credentialID: Data, name: String?) throws -> Passkey? {
        guard var passkey = passkeysByID[credentialID], passkey.userID == userID else { return nil }
        passkey.name = name
        passkeysByID[credentialID] = passkey
        return passkey
    }

    public func deletePasskeyIfNotLast(userID: UUID, credentialID: Data) throws -> PasskeyDeletionResult {
        guard let passkey = passkeysByID[credentialID], passkey.userID == userID else { return .notFound }
        let owned = passkeysByID.values.filter { $0.userID == userID }
        guard owned.count > 1 else { return .lastPasskey }
        passkeysByID.removeValue(forKey: credentialID)
        return .deleted(remainingCredentialIDs: passkeysByID.values.filter { $0.userID == userID }.map(\.id))
    }

    public func setRecoveredAt(userID: UUID, at: Date) throws {
        guard var user = users[userID] else { return }
        user.recoveredAt = at
        users[userID] = user
    }

    public func deleteUser(userID: UUID) throws {
        guard let user = users.removeValue(forKey: userID) else { return }
        passkeysByID = passkeysByID.filter { $0.value.userID != userID }
        sessionsByID = sessionsByID.filter { $0.value.userID != userID }
        challenges = challenges.filter { $0.value.userID != userID }
        let normalized = SecurityUtils.normalizeEmail(user.email)
        emailVerifications = emailVerifications.filter { SecurityUtils.normalizeEmail($0.value.email) != normalized }
    }

    public func incrementRateLimit(key: String, windowStart: Date) throws -> Int {
        let storageKey = "\(key)|\(Int(windowStart.timeIntervalSince1970))"
        let value = (rateLimits[storageKey] ?? 0) + 1
        rateLimits[storageKey] = value
        return value
    }

    public func cleanupExpired(now: Date, idleBefore: Date, rateLimitWindowBefore: Date) throws -> CleanupCounts {
        let oldChallengeCount = challenges.count
        challenges = challenges.filter { $0.value.expiresAt > now }
        let oldFlowCount = emailVerifications.count
        emailVerifications = emailVerifications.filter {
            let terminal = $0.value.consumedAt != nil || $0.value.invalidatedAt != nil
            let expired = ($0.value.verifiedExpiresAt ?? $0.value.expiresAt) <= now
            return !(terminal || expired)
        }
        let oldSessionCount = sessionsByID.count
        sessionsByID = sessionsByID.filter { $0.value.expiresAt > now && $0.value.lastSeenAt > idleBefore }
        let cutoff = Int(rateLimitWindowBefore.timeIntervalSince1970)
        let oldRateCount = rateLimits.count
        rateLimits = rateLimits.filter { entry in
            guard let timestamp = Int(entry.key.split(separator: "|").last ?? "") else { return true }
            return timestamp >= cutoff
        }
        return CleanupCounts(
            challenges: oldChallengeCount - challenges.count,
            emailVerifications: oldFlowCount - emailVerifications.count,
            sessions: oldSessionCount - sessionsByID.count,
            rateLimitCounters: oldRateCount - rateLimits.count
        )
    }

    private func enforceSessionLimit(userID: UUID, maximum: Int) {
        let owned = sessionsByID.values.filter { $0.userID == userID }.sorted { $0.lastSeenAt < $1.lastSeenAt }
        if owned.count > maximum {
            for session in owned.prefix(owned.count - maximum) {
                sessionsByID.removeValue(forKey: session.id)
            }
        }
    }
}
