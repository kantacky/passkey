public import Core
public import Foundation
import Logging
public import PostgresNIO

public struct PostgresAuthStore: AuthStore {
    private let client: PostgresClient
    private let logger: Logger

    public init(client: PostgresClient, logger: Logger = Logger(label: "passkey.persistence")) {
        self.client = client
        self.logger = logger
    }

    private func rows(_ query: PostgresQuery) async throws -> [PostgresRow] {
        try await client.query(query, logger: logger).collect()
    }

    public func user(id: UUID) async throws -> User? {
        let result = try await rows("SELECT id, user_handle, email, created_at, recovered_at FROM users WHERE id = \(id)")
        guard let row = result.first else { return nil }
        let values = try row.decode((UUID, Data, String, Date, Date?).self)
        return User(id: values.0, userHandle: values.1, email: values.2, createdAt: values.3, recoveredAt: values.4)
    }

    public func user(email: String) async throws -> User? {
        let normalized = SecurityUtils.normalizeEmail(email)
        let result = try await rows("SELECT id, user_handle, email, created_at, recovered_at FROM users WHERE email = \(normalized)")
        guard let row = result.first else { return nil }
        let values = try row.decode((UUID, Data, String, Date, Date?).self)
        return User(id: values.0, userHandle: values.1, email: values.2, createdAt: values.3, recoveredAt: values.4)
    }

    public func user(userHandle: Data) async throws -> User? {
        let result = try await rows("SELECT id, user_handle, email, created_at, recovered_at FROM users WHERE user_handle = \(userHandle)")
        guard let row = result.first else { return nil }
        let values = try row.decode((UUID, Data, String, Date, Date?).self)
        return User(id: values.0, userHandle: values.1, email: values.2, createdAt: values.3, recoveredAt: values.4)
    }

    public func passkey(credentialID: Data) async throws -> Passkey? {
        let result = try await rows("""
            SELECT id, user_id, public_key, alg, sign_count, sign_count_anomaly_at, aaguid, transports,
                   uv_initialized, backup_eligible, backup_state, name, created_at, last_used_at
            FROM passkeys WHERE id = \(credentialID)
            """)
        guard let row = result.first else { return nil }
        return try decodePasskey(row)
    }

    public func passkeys(userID: UUID) async throws -> [Passkey] {
        let result = try await rows("""
            SELECT id, user_id, public_key, alg, sign_count, sign_count_anomaly_at, aaguid, transports,
                   uv_initialized, backup_eligible, backup_state, name, created_at, last_used_at
            FROM passkeys WHERE user_id = \(userID) ORDER BY created_at
            """)
        return try result.map(decodePasskey)
    }

    public func session(tokenHash: Data) async throws -> Session? {
        let result = try await rows("""
            SELECT id, user_id, token_hash, kind, flow_id, from_recovery, device_label,
                   reauthenticated_at, created_at, last_seen_at, expires_at
            FROM sessions WHERE token_hash = \(tokenHash)
            """)
        guard let row = result.first else { return nil }
        return try decodeSession(row)
    }

    public func session(id: UUID) async throws -> Session? {
        let result = try await rows("""
            SELECT id, user_id, token_hash, kind, flow_id, from_recovery, device_label,
                   reauthenticated_at, created_at, last_seen_at, expires_at
            FROM sessions WHERE id = \(id)
            """)
        guard let row = result.first else { return nil }
        return try decodeSession(row)
    }

    public func sessions(userID: UUID) async throws -> [Session] {
        let result = try await rows("""
            SELECT id, user_id, token_hash, kind, flow_id, from_recovery, device_label,
                   reauthenticated_at, created_at, last_seen_at, expires_at
            FROM sessions WHERE user_id = \(userID) ORDER BY created_at
            """)
        return try result.map(decodeSession)
    }

    public func emailVerification(id: UUID) async throws -> EmailVerification? {
        let result = try await rows("""
            SELECT id, email, purpose, session_id, client, token_hash, code_hash, secret_hash,
                   created_at, verified_at, verified_expires_at, consumed_at, invalidated_at, expires_at
            FROM email_verifications WHERE id = \(id)
            """)
        guard let row = result.first else { return nil }
        return try decodeEmailVerification(row)
    }

    public func emailVerification(secretHash: Data) async throws -> EmailVerification? {
        let result = try await rows("""
            SELECT id, email, purpose, session_id, client, token_hash, code_hash, secret_hash,
                   created_at, verified_at, verified_expires_at, consumed_at, invalidated_at, expires_at
            FROM email_verifications WHERE secret_hash = \(secretHash)
            """)
        guard let row = result.first else { return nil }
        return try decodeEmailVerification(row)
    }

    public func latestEmailVerificationCreatedAt(email: String, purpose: VerificationPurpose) async throws -> Date? {
        let normalized = SecurityUtils.normalizeEmail(email)
        let result = try await rows("""
            SELECT max(created_at) FROM email_verifications
            WHERE email = \(normalized) AND purpose = \(purpose.rawValue)
            """)
        guard let row = result.first else { return nil }
        return try row.decode(Date?.self)
    }

    public func invalidateActiveEmailVerifications(email: String, purpose: VerificationPurpose, at: Date) async throws {
        let normalized = SecurityUtils.normalizeEmail(email)
        _ = try await rows("""
            UPDATE email_verifications SET invalidated_at = \(at)
            WHERE email = \(normalized) AND purpose = \(purpose.rawValue)
              AND consumed_at IS NULL AND invalidated_at IS NULL
            """)
    }

    public func invalidateActiveEmailVerifications(email: String, at: Date) async throws {
        let normalized = SecurityUtils.normalizeEmail(email)
        _ = try await rows("""
            UPDATE email_verifications SET invalidated_at = \(at)
            WHERE email = \(normalized) AND consumed_at IS NULL AND invalidated_at IS NULL
            """)
    }

    public func createEmailVerification(_ verification: EmailVerification) async throws {
        _ = try await rows("""
            INSERT INTO email_verifications (
                id, email, purpose, session_id, client, token_hash, code_hash, secret_hash,
                created_at, verified_at, verified_expires_at, consumed_at, invalidated_at, expires_at
            ) VALUES (
                \(verification.id), \(verification.email), \(verification.purpose.rawValue), \(verification.sessionID),
                \(verification.client.rawValue), \(verification.tokenHash), \(verification.codeHash), \(verification.secretHash),
                \(verification.createdAt), \(verification.verifiedAt), \(verification.verifiedExpiresAt),
                \(verification.consumedAt), \(verification.invalidatedAt), \(verification.expiresAt)
            )
            """)
    }

    public func markEmailVerificationVerified(id: UUID, verifiedAt: Date, verifiedExpiresAt: Date) async throws {
        _ = try await rows("""
            UPDATE email_verifications
            SET verified_at = \(verifiedAt), verified_expires_at = \(verifiedExpiresAt)
            WHERE id = \(id) AND consumed_at IS NULL AND invalidated_at IS NULL
            """)
    }

    public func insertChallenge(_ challenge: WebAuthnChallenge) async throws {
        _ = try await rows("""
            INSERT INTO webauthn_challenges (id, challenge, purpose, user_id, session_id, flow_id, user_handle, expires_at)
            VALUES (\(challenge.id), \(challenge.challenge), \(challenge.purpose.rawValue), \(challenge.userID),
                    \(challenge.sessionID), \(challenge.flowID), \(challenge.userHandle), \(challenge.expiresAt))
            """)
    }

    public func consumeChallenge(_ challenge: Data) async throws -> WebAuthnChallenge? {
        let result = try await rows("""
            DELETE FROM webauthn_challenges
            WHERE challenge = \(challenge) AND expires_at > now()
            RETURNING id, challenge, purpose, user_id, session_id, flow_id, user_handle, expires_at
            """)
        guard let row = result.first else { return nil }
        return try decodeChallenge(row)
    }

    public func createSession(_ session: Session, maximumPerUser: Int) async throws {
        try await client.withTransaction(logger: logger) { connection in
            try await insertSession(session, on: connection)
            let stale = try await connection.query("""
                SELECT id FROM sessions WHERE user_id = \(session.userID)
                ORDER BY last_seen_at DESC OFFSET \(maximumPerUser)
                """, logger: logger).collect()
            for row in stale {
                let id = try row.decode(UUID.self)
                _ = try await connection.query("DELETE FROM sessions WHERE id = \(id)", logger: logger).collect()
            }
        }
    }

    public func rotateSessionToken(sessionID: UUID, newTokenHash: Data, reauthenticatedAt: Date?) async throws -> Session? {
        let result = try await rows("""
            UPDATE sessions SET token_hash = \(newTokenHash), reauthenticated_at = COALESCE(\(reauthenticatedAt), reauthenticated_at)
            WHERE id = \(sessionID)
            RETURNING id, user_id, token_hash, kind, flow_id, from_recovery, device_label,
                      reauthenticated_at, created_at, last_seen_at, expires_at
            """)
        guard let row = result.first else { return nil }
        return try decodeSession(row)
    }

    public func touchSession(sessionID: UUID, at: Date) async throws {
        _ = try await rows("UPDATE sessions SET last_seen_at = \(at) WHERE id = \(sessionID)")
    }

    public func deleteSession(id: UUID) async throws {
        _ = try await rows("DELETE FROM sessions WHERE id = \(id)")
    }

    public func deleteSessions(userID: UUID, except sessionID: UUID?) async throws {
        _ = try await rows("DELETE FROM sessions WHERE user_id = \(userID) AND id IS DISTINCT FROM \(sessionID)")
    }

    public func addPasskey(_ passkey: Passkey) async throws -> StoreWriteResult {
        do {
            try await insertPasskey(passkey, on: nil)
            return .success
        } catch {
            if isUniqueViolation(error) { return .credentialExists }
            throw error
        }
    }

    public func updatePasskeyAuthentication(credentialID: Data, newSignCount: Int64, signCountAnomalyAt: Date?, backupState: Bool, lastUsedAt: Date) async throws {
        _ = try await rows("""
            UPDATE passkeys
            SET sign_count = GREATEST(sign_count, \(newSignCount)),
                sign_count_anomaly_at = COALESCE(\(signCountAnomalyAt), sign_count_anomaly_at),
                backup_state = \(backupState),
                uv_initialized = true,
                last_used_at = \(lastUsedAt)
            WHERE id = \(credentialID)
            """)
    }

    public func renamePasskey(userID: UUID, credentialID: Data, name: String?) async throws -> Passkey? {
        let result = try await rows("""
            UPDATE passkeys SET name = \(name)
            WHERE id = \(credentialID) AND user_id = \(userID)
            RETURNING id, user_id, public_key, alg, sign_count, sign_count_anomaly_at, aaguid, transports,
                      uv_initialized, backup_eligible, backup_state, name, created_at, last_used_at
            """)
        guard let row = result.first else { return nil }
        return try decodePasskey(row)
    }

    public func deletePasskeyIfNotLast(userID: UUID, credentialID: Data) async throws -> PasskeyDeletionResult {
        try await client.withTransaction(logger: logger) { connection in
            _ = try await connection.query("SELECT id FROM users WHERE id = \(userID) FOR UPDATE", logger: logger).collect()
            let countRows = try await connection.query("SELECT count(*)::integer FROM passkeys WHERE user_id = \(userID)", logger: logger).collect()
            guard let countRow = countRows.first else { return PasskeyDeletionResult.notFound }
            let count = try countRow.decode(Int.self)
            let existsRows = try await connection.query("SELECT count(*)::integer FROM passkeys WHERE user_id = \(userID) AND id = \(credentialID)", logger: logger).collect()
            let exists = try existsRows.first?.decode(Int.self) ?? 0
            guard exists > 0 else { return PasskeyDeletionResult.notFound }
            guard count > 1 else { return PasskeyDeletionResult.lastPasskey }
            _ = try await connection.query("DELETE FROM passkeys WHERE id = \(credentialID) AND user_id = \(userID)", logger: logger).collect()
            let remainingRows = try await connection.query("SELECT id FROM passkeys WHERE user_id = \(userID)", logger: logger).collect()
            let remaining = try remainingRows.map { try $0.decode(Data.self) }
            return PasskeyDeletionResult.deleted(remainingCredentialIDs: remaining)
        }
    }

    public func setRecoveredAt(userID: UUID, at: Date) async throws {
        _ = try await rows("UPDATE users SET recovered_at = \(at) WHERE id = \(userID)")
    }

    public func deleteUser(userID: UUID) async throws {
        guard let user = try await user(id: userID) else { return }
        try await client.withTransaction(logger: logger) { connection in
            _ = try await connection.query("DELETE FROM users WHERE id = \(userID)", logger: logger).collect()
            _ = try await connection.query("DELETE FROM email_verifications WHERE email = \(user.email)", logger: logger).collect()
        }
    }

    public func incrementRateLimit(key: String, windowStart: Date) async throws -> Int {
        let result = try await rows("""
            INSERT INTO rate_limit_counters (key, window_start, count)
            VALUES (\(key), \(windowStart), 1)
            ON CONFLICT (key, window_start)
            DO UPDATE SET count = rate_limit_counters.count + 1
            RETURNING count
            """)
        guard let row = result.first else { return 0 }
        return try row.decode(Int.self)
    }

    public func cleanupExpired(now: Date, idleBefore: Date, rateLimitWindowBefore: Date) async throws -> CleanupCounts {
        async let challengeRows = rows("DELETE FROM webauthn_challenges WHERE expires_at <= \(now) RETURNING id")
        async let flowRows = rows("""
            DELETE FROM email_verifications
            WHERE consumed_at IS NOT NULL OR invalidated_at IS NOT NULL
               OR COALESCE(verified_expires_at, expires_at) <= \(now)
            RETURNING id
            """)
        async let sessionRows = rows("DELETE FROM sessions WHERE expires_at <= \(now) OR last_seen_at <= \(idleBefore) RETURNING id")
        async let counterRows = rows("DELETE FROM rate_limit_counters WHERE window_start <= \(rateLimitWindowBefore) RETURNING key")
        let (challenges, flows, sessions, counters) = try await (challengeRows, flowRows, sessionRows, counterRows)
        return CleanupCounts(challenges: challenges.count, emailVerifications: flows.count, sessions: sessions.count, rateLimitCounters: counters.count)
    }

    public func consumeFlowAndCreateRecoverySession(flowID: UUID, session: Session, consumedAt: Date) async throws -> Bool {
        try await client.withTransaction(logger: logger) { connection in
            let flowRows = try await connection.query("""
                UPDATE email_verifications SET consumed_at = \(consumedAt)
                WHERE id = \(flowID)
                  AND verified_at IS NULL AND consumed_at IS NULL AND invalidated_at IS NULL AND expires_at > \(consumedAt)
                RETURNING id
                """, logger: logger).collect()
            guard !flowRows.isEmpty else { return false }
            try await insertSession(session, on: connection)
            let stale = try await connection.query("""
                SELECT id FROM sessions WHERE user_id = \(session.userID)
                ORDER BY last_seen_at DESC OFFSET 20
                """, logger: logger).collect()
            for row in stale {
                let id = try row.decode(UUID.self)
                _ = try await connection.query("DELETE FROM sessions WHERE id = \(id)", logger: logger).collect()
            }
            return true
        }
    }

    public func changeEmailConsumingFlow(flowID: UUID, userID: UUID, newEmail: String, sessionID: UUID, newTokenHash: Data, at: Date) async throws -> EmailChangeStoreResult {
        do {
            return try await client.withTransaction(logger: logger) { connection in
                let flowRows = try await connection.query("""
                    SELECT id FROM email_verifications
                    WHERE id = \(flowID) AND verified_at IS NULL AND consumed_at IS NULL AND invalidated_at IS NULL AND expires_at > \(at)
                    FOR UPDATE
                    """, logger: logger).collect()
                guard !flowRows.isEmpty else { return EmailChangeStoreResult.flowUnavailable }
                let sessionRows = try await connection.query("""
                    SELECT id FROM sessions WHERE id = \(sessionID) AND user_id = \(userID) FOR UPDATE
                    """, logger: logger).collect()
                guard !sessionRows.isEmpty else { return EmailChangeStoreResult.sessionUnavailable }
                let conflictRows = try await connection.query("""
                    SELECT id FROM users WHERE email = \(newEmail) AND id <> \(userID) LIMIT 1
                    """, logger: logger).collect()
                guard conflictRows.isEmpty else { return EmailChangeStoreResult.emailTaken }

                _ = try await connection.query("UPDATE users SET email = \(newEmail) WHERE id = \(userID)", logger: logger).collect()
                _ = try await connection.query("UPDATE email_verifications SET consumed_at = \(at) WHERE id = \(flowID)", logger: logger).collect()
                _ = try await connection.query("UPDATE sessions SET token_hash = \(newTokenHash) WHERE id = \(sessionID)", logger: logger).collect()
                _ = try await connection.query("DELETE FROM sessions WHERE user_id = \(userID) AND id <> \(sessionID)", logger: logger).collect()
                return EmailChangeStoreResult.success
            }
        } catch {
            if isUniqueViolation(error) { return .emailTaken }
            throw error
        }
    }

    public func createUserWithPasskeyAndSession(user: User, passkey: Passkey, session: Session, consumeFlowID: UUID, consumedAt: Date) async throws -> StoreWriteResult {
        do {
            return try await client.withTransaction(logger: logger) { connection in
                let flowRows = try await connection.query("""
                    SELECT id FROM email_verifications
                    WHERE id = \(consumeFlowID)
                      AND verified_at IS NOT NULL AND consumed_at IS NULL AND invalidated_at IS NULL
                      AND verified_expires_at > \(consumedAt)
                    FOR UPDATE
                    """, logger: logger).collect()
                guard !flowRows.isEmpty else { return StoreWriteResult.flowUnavailable }
                let conflictRows = try await connection.query("SELECT id FROM users WHERE email = \(user.email) LIMIT 1", logger: logger).collect()
                guard conflictRows.isEmpty else { return StoreWriteResult.emailTaken }
                let credentialRows = try await connection.query("SELECT id FROM passkeys WHERE id = \(passkey.id) LIMIT 1", logger: logger).collect()
                guard credentialRows.isEmpty else { return StoreWriteResult.credentialExists }

                _ = try await connection.query("""
                    INSERT INTO users (id, user_handle, email, created_at, recovered_at)
                    VALUES (\(user.id), \(user.userHandle), \(user.email), \(user.createdAt), \(user.recoveredAt))
                    """, logger: logger).collect()
                try await insertPasskey(passkey, on: connection)
                try await insertSession(session, on: connection)
                _ = try await connection.query("UPDATE email_verifications SET consumed_at = \(consumedAt) WHERE id = \(consumeFlowID)", logger: logger).collect()
                return StoreWriteResult.success
            }
        } catch {
            if isUniqueViolation(error) {
                if String(describing: error).contains("users_email") { return .emailTaken }
                if String(describing: error).contains("passkeys_pkey") { return .credentialExists }
                return .emailTaken
            }
            throw error
        }
    }

    public func completeRecovery(passkey: Passkey, recoverySessionID: UUID, newSession: Session, recoveredAt: Date) async throws -> StoreWriteResult {
        do {
            return try await client.withTransaction(logger: logger) { connection in
                let credentialRows = try await connection.query("SELECT id FROM passkeys WHERE id = \(passkey.id) LIMIT 1", logger: logger).collect()
                guard credentialRows.isEmpty else { return StoreWriteResult.credentialExists }
                let recoveryRows = try await connection.query("""
                    SELECT id FROM sessions
                    WHERE id = \(recoverySessionID) AND user_id = \(passkey.userID) AND kind = 'recovery'
                    FOR UPDATE
                    """, logger: logger).collect()
                guard !recoveryRows.isEmpty else { return StoreWriteResult.flowUnavailable }

                try await insertPasskey(passkey, on: connection)
                _ = try await connection.query("UPDATE users SET recovered_at = \(recoveredAt) WHERE id = \(passkey.userID)", logger: logger).collect()
                _ = try await connection.query("DELETE FROM sessions WHERE user_id = \(passkey.userID)", logger: logger).collect()
                try await insertSession(newSession, on: connection)
                return StoreWriteResult.success
            }
        } catch {
            if isUniqueViolation(error) { return .credentialExists }
            throw error
        }
    }

    private func insertPasskey(_ passkey: Passkey, on connection: PostgresConnection?) async throws {
        let query: PostgresQuery = try """
            INSERT INTO passkeys (
                id, user_id, public_key, alg, sign_count, sign_count_anomaly_at, aaguid, transports,
                uv_initialized, backup_eligible, backup_state, name, created_at, last_used_at
            ) VALUES (
                \(passkey.id), \(passkey.userID), \(passkey.publicKey), \(Int32(passkey.alg)), \(passkey.signCount),
                \(passkey.signCountAnomalyAt), \(passkey.aaguid), \(passkey.transports), \(passkey.uvInitialized),
                \(passkey.backupEligible), \(passkey.backupState), \(passkey.name), \(passkey.createdAt), \(passkey.lastUsedAt)
            )
            """
        if let connection {
            _ = try await connection.query(query, logger: logger).collect()
        } else {
            _ = try await client.query(query, logger: logger).collect()
        }
    }

    private func insertSession(_ session: Session, on connection: PostgresConnection) async throws {
        _ = try await connection.query("""
            INSERT INTO sessions (
                id, user_id, token_hash, kind, flow_id, from_recovery, device_label,
                reauthenticated_at, created_at, last_seen_at, expires_at
            ) VALUES (
                \(session.id), \(session.userID), \(session.tokenHash), \(session.kind.rawValue), \(session.flowID),
                \(session.fromRecovery), \(session.deviceLabel), \(session.reauthenticatedAt),
                \(session.createdAt), \(session.lastSeenAt), \(session.expiresAt)
            )
            """, logger: logger).collect()
    }

    private func decodePasskey(_ row: PostgresRow) throws -> Passkey {
        let values = try row.decode((Data, UUID, Data, Int32, Int64, Date?, UUID?, [String], Bool, Bool, Bool, String?, Date, Date?).self)
        return Passkey(
            id: values.0,
            userID: values.1,
            publicKey: values.2,
            alg: Int(values.3),
            signCount: values.4,
            signCountAnomalyAt: values.5,
            aaguid: values.6,
            transports: values.7,
            uvInitialized: values.8,
            backupEligible: values.9,
            backupState: values.10,
            name: values.11,
            createdAt: values.12,
            lastUsedAt: values.13
        )
    }

    private func decodeSession(_ row: PostgresRow) throws -> Session {
        let values = try row.decode((UUID, UUID, Data, String, UUID?, Bool, String, Date?, Date, Date, Date).self)
        return Session(
            id: values.0,
            userID: values.1,
            tokenHash: values.2,
            kind: SessionKind(rawValue: values.3) ?? .normal,
            flowID: values.4,
            fromRecovery: values.5,
            deviceLabel: values.6,
            reauthenticatedAt: values.7,
            createdAt: values.8,
            lastSeenAt: values.9,
            expiresAt: values.10
        )
    }

    private func decodeEmailVerification(_ row: PostgresRow) throws -> EmailVerification {
        let values = try row.decode((UUID, String, String, UUID?, String, Data, Data, Data, Date, Date?, Date?, Date?, Date?, Date).self)
        return EmailVerification(
            id: values.0,
            email: values.1,
            purpose: VerificationPurpose(rawValue: values.2) ?? .signup,
            sessionID: values.3,
            client: ClientKind(rawValue: values.4) ?? .web,
            tokenHash: values.5,
            codeHash: values.6,
            secretHash: values.7,
            createdAt: values.8,
            verifiedAt: values.9,
            verifiedExpiresAt: values.10,
            consumedAt: values.11,
            invalidatedAt: values.12,
            expiresAt: values.13
        )
    }

    private func decodeChallenge(_ row: PostgresRow) throws -> WebAuthnChallenge {
        let values = try row.decode((UUID, Data, String, UUID?, UUID?, UUID?, Data?, Date).self)
        return WebAuthnChallenge(
            id: values.0,
            challenge: values.1,
            purpose: ChallengePurpose(rawValue: values.2) ?? .authentication,
            userID: values.3,
            sessionID: values.4,
            flowID: values.5,
            userHandle: values.6,
            expiresAt: values.7
        )
    }

    private func isUniqueViolation(_ error: Error) -> Bool {
        let description = String(describing: error)
        return description.contains("23505") || description.localizedCaseInsensitiveContains("duplicate key")
    }
}
