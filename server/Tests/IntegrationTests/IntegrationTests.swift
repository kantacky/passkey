import Foundation
import Logging
import PostgresNIO
import Testing
@testable import Core
@testable import Persistence

@Suite("PostgreSQL integration", .serialized)
struct PostgresIntegrationTests {
    @Test("schema statements cover all designed tables")
    func schemaCoverage() {
        #expect(Migrations.statements.count >= 6)
        #expect(Migrations.statements.contains { $0.contains("CREATE TABLE IF NOT EXISTS users") })
        #expect(Migrations.statements.contains { $0.contains("CREATE TABLE IF NOT EXISTS passkeys") })
        #expect(Migrations.statements.contains { $0.contains("CREATE TABLE IF NOT EXISTS sessions") })
        #expect(Migrations.statements.contains { $0.contains("CREATE TABLE IF NOT EXISTS email_verifications") })
        #expect(Migrations.statements.contains { $0.contains("CREATE TABLE IF NOT EXISTS webauthn_challenges") })
        #expect(Migrations.statements.contains { $0.contains("CREATE TABLE IF NOT EXISTS rate_limit_counters") })
    }

    @Test("challenge consumption is atomic under concurrency")
    func challengeAtomicConsumption() async throws {
        try await withStore { store, _ in
            let challenge = SecurityUtils.randomBytes(count: 32)
            try await store.insertChallenge(WebAuthnChallenge(
                id: SecurityUtils.uuidv7(),
                challenge: challenge,
                purpose: .authentication,
                expiresAt: Date().addingTimeInterval(300)
            ))
            let successes = await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<20 {
                    group.addTask {
                        (try? await store.consumeChallenge(challenge)) != nil
                    }
                }
                var count = 0
                for await succeeded in group where succeeded { count += 1 }
                return count
            }
            #expect(successes == 1)
        }
    }

    @Test("concurrent signup cannot duplicate a normalized email")
    func emailTakenRace() async throws {
        try await withStore { store, client in
            let logger = Logger(label: "test.email-race")
            let now = Date()
            let email = "race-\(UUID().uuidString.lowercased())@example.com"
            let flowIDs = [SecurityUtils.uuidv7(), SecurityUtils.uuidv7()]
            for flowID in flowIDs {
                _ = try await client.query("""
                    INSERT INTO email_verifications (
                        id, email, purpose, client, token_hash, code_hash, secret_hash,
                        created_at, verified_at, verified_expires_at, expires_at
                    ) VALUES (
                        \(flowID), \(email), 'signup', 'web', \(SecurityUtils.randomBytes(count: 32)),
                        \(SecurityUtils.randomBytes(count: 32)), \(SecurityUtils.randomBytes(count: 32)),
                        \(now), \(now), \(now.addingTimeInterval(900)), \(now.addingTimeInterval(600))
                    )
                    """, logger: logger).collect()
            }

            func signupInput(index: Int) -> (User, Passkey, Session) {
                let user = User(
                    id: SecurityUtils.uuidv7(),
                    userHandle: SecurityUtils.randomBytes(count: 64),
                    email: email,
                    createdAt: now
                )
                let passkey = Passkey(
                    id: SecurityUtils.randomBytes(count: 32), userID: user.id, publicKey: Data([UInt8(index)]),
                    alg: -7, signCount: 0, aaguid: nil, transports: [], uvInitialized: true,
                    backupEligible: true, backupState: true, createdAt: now
                )
                let session = Session(
                    id: SecurityUtils.uuidv7(), userID: user.id, tokenHash: SecurityUtils.randomBytes(count: 32),
                    kind: .normal, deviceLabel: "test", reauthenticatedAt: now,
                    createdAt: now, lastSeenAt: now, expiresAt: now.addingTimeInterval(86400)
                )
                return (user, passkey, session)
            }

            let results = try await withThrowingTaskGroup(of: StoreWriteResult.self) { group in
                for (index, flowID) in flowIDs.enumerated() {
                    group.addTask {
                        let (user, passkey, session) = signupInput(index: index)
                        return try await store.createUserWithPasskeyAndSession(
                            user: user,
                            passkey: passkey,
                            session: session,
                            consumeFlowID: flowID,
                            consumedAt: Date()
                        )
                    }
                }
                var collected: [StoreWriteResult] = []
                for try await result in group { collected.append(result) }
                return collected
            }
            #expect(results.count == 2)
            #expect(results.contains(.success))
            #expect(results.contains(.emailTaken))
        }
    }

    @Test("rate limit counter increments exactly once per concurrent caller")
    func rateLimitCounterConcurrency() async throws {
        try await withStore { store, _ in
            let key = "test:\(UUID().uuidString)"
            let window = SecurityUtils.hourWindowStart(for: Date())
            let values = await withTaskGroup(of: Int?.self) { group in
                for _ in 0..<50 {
                    group.addTask { try? await store.incrementRateLimit(key: key, windowStart: window) }
                }
                var collected: [Int] = []
                for await value in group {
                    if let value { collected.append(value) }
                }
                return collected
            }
            #expect(values.count == 50)
            #expect(Set(values).count == 50)
            #expect(values.max() == 50)
        }
    }

    @Test("concurrent deletion cannot remove the last passkey")
    func concurrentLastPasskeyDeletion() async throws {
        try await withStore { store, client in
            let now = Date()
            let user = User(
                id: SecurityUtils.uuidv7(at: now),
                userHandle: SecurityUtils.randomBytes(count: 64),
                email: "concurrent-\(UUID().uuidString.lowercased())@example.com",
                createdAt: now
            )
            _ = try await client.query("""
                INSERT INTO users (id, user_handle, email, created_at) VALUES (\(user.id), \(user.userHandle), \(user.email), \(user.createdAt))
                """, logger: Logger(label: "test")).collect()
            func passkey(_ byte: UInt8) -> Passkey {
                var credentialID = SecurityUtils.randomBytes(count: 32)
                credentialID[0] = byte
                return Passkey(
                    id: credentialID, userID: user.id, publicKey: Data([1]), alg: -7, signCount: 0,
                    aaguid: nil, transports: [], uvInitialized: true, backupEligible: true, backupState: true,
                    createdAt: now
                )
            }
            let first = passkey(81)
            let second = passkey(82)
            #expect(try await store.addPasskey(first) == .success)
            #expect(try await store.addPasskey(second) == .success)

            let results = await withTaskGroup(of: PasskeyDeletionResult?.self) { group in
                for credential in [first.id, second.id] {
                    group.addTask { try? await store.deletePasskeyIfNotLast(userID: user.id, credentialID: credential) }
                }
                var collected: [PasskeyDeletionResult] = []
                for await result in group {
                    if let result { collected.append(result) }
                }
                return collected
            }
            #expect(results.count == 2)
            #expect(results.contains { if case .deleted = $0 { true } else { false } })
            #expect(results.contains(.lastPasskey))
            #expect(try await store.passkeys(userID: user.id).count == 1)
        }
    }

    private func withStore(_ operation: @escaping @Sendable (PostgresAuthStore, PostgresClient) async throws -> Void) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let database = environment["PASSKEY_TEST_DATABASE_NAME"] else {
            // The schema-only test above always runs. PostgreSQL-backed cases run when CI/local setup supplies this database.
            return
        }
        var configuration = PostgresClient.Configuration(
            host: environment["PASSKEY_TEST_DATABASE_HOST"] ?? "127.0.0.1",
            port: Int(environment["PASSKEY_TEST_DATABASE_PORT"] ?? "5432") ?? 5432,
            username: environment["PASSKEY_TEST_DATABASE_USER"] ?? "postgres",
            password: environment["PASSKEY_TEST_DATABASE_PASSWORD"],
            database: database,
            tls: .disable
        )
        configuration.options.maximumConnections = 4
        let client = PostgresClient(configuration: configuration)
        let logger = Logger(label: "passkey.integration")
        let store = PostgresAuthStore(client: client, logger: logger)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            group.addTask {
                try await Migrations.migrate(client: client, logger: logger)
                try await operation(store, client)
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }
}
