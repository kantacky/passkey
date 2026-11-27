import Foundation
import Testing
import Logging
import WebAuthn
@testable import Core
@testable import Persistence

@Suite("Security utilities")
struct SecurityUtilityTests {
    @Test("session token is base64url and 256 bits")
    func sessionTokenShape() {
        let token = SecurityUtils.randomToken()
        #expect(token.count == 43)
        #expect(token.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil)
    }

    @Test("IPv6 remote addresses are grouped by /64")
    func ipv6RateLimitGrouping() {
        #expect(SecurityUtils.normalizeClientIP("2001:0db8:0000:0000:abcd:0000:0000:0001") == "2001:db8:0:0::/64")
        #expect(SecurityUtils.normalizeClientIP("2001:db8::ffff") == "2001:db8:0:0::/64")
        #expect(SecurityUtils.normalizeClientIP("192.0.2.10") == "192.0.2.10")
    }

    @Test("UUID v7 has version and variant bits")
    func uuidV7Bits() {
        let uuid = SecurityUtils.uuidv7(at: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(uuid.uuid.6 & 0xf0 == 0x70)
        #expect(uuid.uuid.8 & 0xc0 == 0x80)
    }

    @Test("SHA-256 test vector")
    func sha256Vector() {
        #expect(SecurityUtils.sha256("abc").map { String(format: "%02x", $0) }.joined() == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("email normalization")
    func normalizeEmail() {
        #expect(SecurityUtils.normalizeEmail("  User@Example.COM\n") == "user@example.com")
    }
}

@Suite("Mini CBOR")
struct MiniCBORTests {
    @Test("decodes definite maps and byte strings")
    func decodeFixture() throws {
        // a1 61 61 43 01 02 03 => {"a": h'010203'}
        var parser = MiniCBORParser(data: Data([0xa1, 0x61, 0x61, 0x43, 0x01, 0x02, 0x03]))
        let value = try parser.parse()
        guard case .map(let map) = value,
              let bytes = map[.text("a")],
              case .bytes(let data) = bytes else {
            Issue.record("unexpected CBOR shape")
            return
        }
        #expect(data == Data([1, 2, 3]))
    }
}

actor RecordingMailSender: MailSender {
    private var sent: [MailMessage] = []
    func send(_ message: MailMessage) async throws {
        sent.append(message)
    }
    func messages() -> [MailMessage] { sent }
}

@Suite("Email verification use case")
struct EmailVerificationUseCaseTests {
    @Test("signup verification is device-bound and produces registration options")
    func signupFlow() async throws {
        let store = InMemoryAuthStore()
        let sender = RecordingMailSender()
        let core = AuthCore(
            store: store,
            configuration: AuthConfiguration(rpID: "passkey.example.com", origin: "https://passkey.example.com"),
            mailQueue: MailQueue(sender: sender, logger: Logger(label: "test")),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let started = try await core.startEmailVerification(
            email: " User@Example.com ",
            purpose: .signup,
            client: .web,
            ip: "192.0.2.10",
            userAgent: "Safari"
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        let messages = await sender.messages()
        #expect(messages.count == 1)
        guard let code = messages.first?.text.split(whereSeparator: \.isWhitespace).compactMap({ word -> String? in
            let value = String(word)
            return value.count == 6 && value.allSatisfy(\.isNumber) ? value : nil
        }).first else {
            Issue.record("verification mail did not contain a 6 digit code")
            return
        }

        do {
            _ = try await core.verifyEmailVerification(
                id: started.id,
                secret: "wrong-secret",
                token: nil,
                code: code,
                ip: "192.0.2.10",
                userAgent: "Safari"
            )
            Issue.record("wrong flow secret was accepted")
        } catch let error as AuthError {
            #expect(error == .deviceMismatch)
        }
        #expect(try await core.emailVerificationStatus(id: started.id, secret: started.secret) == .pending)

        let verified = try await core.verifyEmailVerification(
            id: started.id,
            secret: started.secret,
            token: nil,
            code: code,
            ip: "192.0.2.10",
            userAgent: "Safari"
        )
        #expect(verified == .signupVerified)
        #expect(try await core.emailVerificationStatus(id: started.id, secret: started.secret) == .verified)

        let options = try await core.registrationOptions(flowSecret: started.secret, authenticatedContext: nil)
        #expect(options.options.challenge.count == 32)
        #expect(options.options.user.id.count == 64)
        #expect(options.options.user.name == "user@example.com")
        #expect(options.options.publicKeyCredentialParameters.map(\.alg.rawValue) == [-7, -257])
        #expect(options.options.authenticatorSelection?.userVerification == .required)
        #expect(options.options.authenticatorSelection?.residentKey == .required)
    }
}

@Suite("Session and passkey policy")
struct SessionAndPasskeyPolicyTests {
    private func seedUser(store: InMemoryAuthStore) async throws -> (User, Passkey, Session) {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let flow = EmailVerification(
            id: SecurityUtils.uuidv7(at: now), email: "user@example.com", purpose: .signup, sessionID: nil,
            client: .web, tokenHash: Data([1]), codeHash: Data([2]), secretHash: Data([3]),
            createdAt: now, expiresAt: now.addingTimeInterval(600)
        )
        try await store.createEmailVerification(flow)
        try await store.markEmailVerificationVerified(id: flow.id, verifiedAt: now, verifiedExpiresAt: now.addingTimeInterval(900))
        let user = User(id: SecurityUtils.uuidv7(at: now), userHandle: SecurityUtils.randomBytes(count: 64), email: flow.email, createdAt: now)
        let passkey = Passkey(
            id: Data([10, 1]), userID: user.id, publicKey: Data([1]), alg: -7, signCount: 0,
            aaguid: nil, transports: [], uvInitialized: true, backupEligible: true, backupState: true,
            createdAt: now
        )
        let session = Session(
            id: SecurityUtils.uuidv7(at: now), userID: user.id, tokenHash: Data([9]), kind: .normal,
            deviceLabel: "Safari", reauthenticatedAt: now, createdAt: now, lastSeenAt: now,
            expiresAt: now.addingTimeInterval(24 * 3600)
        )
        let result = try await store.createUserWithPasskeyAndSession(user: user, passkey: passkey, session: session, consumeFlowID: flow.id, consumedAt: now)
        #expect(result == .success)
        return (user, passkey, session)
    }

    @Test("last passkey cannot be deleted")
    func lastPasskey() async throws {
        let store = InMemoryAuthStore()
        let core = AuthCore(
            store: store,
            configuration: AuthConfiguration(rpID: "passkey.example.com", origin: "https://passkey.example.com"),
            mailQueue: MailQueue(sender: NullMailSender(), logger: Logger(label: "test")),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let (user, firstPasskey, session) = try await seedUser(store: store)
        let second = Passkey(
            id: Data([10, 2]), userID: user.id, publicKey: Data([1]), alg: -7, signCount: 0,
            aaguid: nil, transports: [], uvInitialized: true, backupEligible: true, backupState: true,
            createdAt: session.createdAt
        )
        #expect(try await store.addPasskey(second) == .success)
        let context = AuthenticatedContext(user: user, session: session)
        let remaining = try await core.deletePasskey(credentialID: firstPasskey.id, context: context)
        #expect(remaining == [second.id])
        do {
            _ = try await core.deletePasskey(credentialID: second.id, context: context)
            Issue.record("last passkey deletion succeeded")
        } catch let error as AuthError {
            #expect(error == .lastPasskey)
        }
    }

    @Test("oldest session is evicted beyond 20 concurrent sessions")
    func sessionLimit() async throws {
        let store = InMemoryAuthStore()
        let (_, _, firstSession) = try await seedUser(store: store)
        for index in 0..<25 {
            let at = firstSession.createdAt.addingTimeInterval(TimeInterval(index + 1))
            let session = Session(
                id: SecurityUtils.uuidv7(at: at), userID: firstSession.userID, tokenHash: SecurityUtils.sha256("token-\(index)"),
                kind: .normal, deviceLabel: "test", reauthenticatedAt: at, createdAt: at, lastSeenAt: at,
                expiresAt: at.addingTimeInterval(24 * 3600)
            )
            try await store.createSession(session, maximumPerUser: 20)
        }
        let sessions = try await store.sessions(userID: firstSession.userID)
        #expect(sessions.count == 20)
        #expect(sessions.contains { $0.id == firstSession.id } == false)
    }
}

@Suite("WebAuthn registration input validation")
struct WebAuthnRegistrationValidationTests {
    private func verifiedSignup() async throws -> (core: AuthCore, secret: String, challenge: Data) {
        let sender = RecordingMailSender()
        let core = AuthCore(
            store: InMemoryAuthStore(),
            configuration: AuthConfiguration(rpID: "passkey.example.com", origin: "https://passkey.example.com"),
            mailQueue: MailQueue(sender: sender, logger: Logger(label: "test.webauthn")),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let started = try await core.startEmailVerification(
            email: "webauthn@example.com",
            purpose: .signup,
            client: .web,
            ip: "192.0.2.20",
            userAgent: "Safari"
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        guard let text = await sender.messages().first?.text,
              let code = text.split(whereSeparator: \.isWhitespace).map(String.init).first(where: { $0.count == 6 && $0.allSatisfy(\.isNumber) }) else {
            Issue.record("verification code was not sent")
            throw AuthError.verificationFailed
        }
        _ = try await core.verifyEmailVerification(
            id: started.id,
            secret: started.secret,
            token: nil,
            code: code,
            ip: "192.0.2.20",
            userAgent: "Safari"
        )
        let options = try await core.registrationOptions(flowSecret: started.secret, authenticatedContext: nil)
        return (core, started.secret, Data(options.options.challenge))
    }

    private func input(challenge: Data, type: String = "webauthn.create", origin: String = "https://passkey.example.com", crossOrigin: Bool = false) -> RegistrationCredentialInput {
        let rawID = SecurityUtils.randomBytes(count: 32)
        let json = """
        {"type":"\(type)","challenge":"\(challenge.pkBase64URLEncodedString())","origin":"\(origin)","crossOrigin":\(crossOrigin)}
        """
        return RegistrationCredentialInput(
            id: rawID.pkBase64URLEncodedString(),
            rawID: rawID,
            clientDataJSON: Data(json.utf8),
            attestationObject: packedAttestationObject()
        )
    }

    private func packedAttestationObject() -> Data {
        var authData = Data(repeating: 1, count: 37)
        authData[32] = 0x0d // UP + UV + BE, with BS clear.
        var data = Data([0xa3])
        data.append(contentsOf: [0x63]) ; data.append(contentsOf: "fmt".utf8)
        data.append(contentsOf: [0x66]) ; data.append(contentsOf: "packed".utf8)
        data.append(contentsOf: [0x67]) ; data.append(contentsOf: "attStmt".utf8)
        data.append(0xa0)
        data.append(contentsOf: [0x68]) ; data.append(contentsOf: "authData".utf8)
        data.append(contentsOf: [0x58, UInt8(authData.count)])
        data.append(authData)
        return data
    }

    private func expectFinishFailure(
        challenge: Data,
        type: String = "webauthn.create",
        origin: String = "https://passkey.example.com",
        crossOrigin: Bool = false,
        expected: AuthError
    ) async throws {
        let (core, secret, _) = try await verifiedSignup()
        do {
            _ = try await core.finishRegistration(
                input: input(challenge: challenge, type: type, origin: origin, crossOrigin: crossOrigin),
                flowSecret: secret,
                authenticatedContext: nil,
                userAgent: "Safari",
                client: .web
            )
            Issue.record("invalid WebAuthn input was accepted")
        } catch let error as AuthError {
            #expect(error == expected)
        }
    }

    @Test("registration client data type must be webauthn.create")
    func rejectsWrongClientDataType() async throws {
        let (_, _, challenge) = try await verifiedSignup()
        try await expectFinishFailure(challenge: challenge, type: "webauthn.get", expected: .verificationFailed)
    }

    @Test("registration client data origin must exactly match RP origin")
    func rejectsWrongClientDataOrigin() async throws {
        let (_, _, challenge) = try await verifiedSignup()
        try await expectFinishFailure(challenge: challenge, origin: "https://evil.example.com", expected: .originMismatch)
    }

    @Test("registration client data must not be cross-origin")
    func rejectsCrossOriginClientData() async throws {
        let (_, _, challenge) = try await verifiedSignup()
        try await expectFinishFailure(challenge: challenge, crossOrigin: true, expected: .verificationFailed)
    }

    @Test("registration challenge must exist and be unconsumed")
    func rejectsUnknownChallenge() async throws {
        try await expectFinishFailure(challenge: SecurityUtils.randomBytes(count: 32), expected: .invalidChallenge)
    }

    @Test("registration attestation format must be none")
    func rejectsPackedAttestation() async throws {
        let (core, secret, challenge) = try await verifiedSignup()
        do {
            _ = try await core.finishRegistration(
                input: input(challenge: challenge),
                flowSecret: secret,
                authenticatedContext: nil,
                userAgent: "Safari",
                client: .web
            )
            Issue.record("packed attestation was accepted")
        } catch let error as AuthError {
            #expect(error == .verificationFailed)
        }
    }
}

@Suite("Session expiry and authorization policy")
struct SessionSecurityPolicyTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func core(store: InMemoryAuthStore, at date: Date) -> AuthCore {
        AuthCore(
            store: store,
            configuration: AuthConfiguration(rpID: "passkey.example.com", origin: "https://passkey.example.com"),
            mailQueue: MailQueue(sender: NullMailSender(), logger: Logger(label: "test.session")),
            now: { date }
        )
    }

    private func seedSession(
        store: InMemoryAuthStore,
        at date: Date,
        kind: SessionKind = .normal,
        reauthenticated: Bool = true
    ) async throws -> (user: User, session: Session, token: String) {
        let flowID = SecurityUtils.uuidv7(at: date)
        try await store.createEmailVerification(EmailVerification(
            id: flowID,
            email: "session-\(flowID.uuidString.lowercased())@example.com",
            purpose: .signup,
            sessionID: nil,
            client: .web,
            tokenHash: SecurityUtils.randomBytes(count: 32),
            codeHash: SecurityUtils.randomBytes(count: 32),
            secretHash: SecurityUtils.randomBytes(count: 32),
            createdAt: date,
            verifiedAt: date,
            verifiedExpiresAt: date.addingTimeInterval(900),
            expiresAt: date.addingTimeInterval(600)
        ))
        let user = User(
            id: SecurityUtils.uuidv7(at: date),
            userHandle: SecurityUtils.randomBytes(count: 64),
            email: "session-\(flowID.uuidString.lowercased())@example.com",
            createdAt: date
        )
        let passkey = Passkey(
            id: SecurityUtils.randomBytes(count: 32), userID: user.id, publicKey: Data([1]), alg: -7,
            signCount: 0, aaguid: nil, transports: [], uvInitialized: true,
            backupEligible: true, backupState: true, createdAt: date
        )
        let token = SecurityUtils.randomToken()
        let session = Session(
            id: SecurityUtils.uuidv7(at: date),
            userID: user.id,
            tokenHash: SecurityUtils.sha256(token),
            kind: kind,
            deviceLabel: "Safari (macOS)",
            reauthenticatedAt: reauthenticated ? date : nil,
            createdAt: date,
            lastSeenAt: date,
            expiresAt: date.addingTimeInterval(kind == .recovery ? 900 : 24 * 3600)
        )
        let result = try await store.createUserWithPasskeyAndSession(
            user: user,
            passkey: passkey,
            session: session,
            consumeFlowID: flowID,
            consumedAt: date
        )
        #expect(result == .success)
        return (user, session, token)
    }

    @Test("absolute session expiry is enforced")
    func absoluteExpiry() async throws {
        let store = InMemoryAuthStore()
        let (_, _, token) = try await seedSession(store: store, at: epoch)
        let expiredCore = core(store: store, at: epoch.addingTimeInterval(24 * 3600 + 1))
        do {
            _ = try await expiredCore.authenticate(token: token)
            Issue.record("expired session was accepted")
        } catch let error as AuthError {
            #expect(error == .unauthenticated)
        }
    }

    @Test("idle session expiry is enforced")
    func idleExpiry() async throws {
        let store = InMemoryAuthStore()
        let (_, _, token) = try await seedSession(store: store, at: epoch)
        let idleCore = core(store: store, at: epoch.addingTimeInterval(3601))
        do {
            _ = try await idleCore.authenticate(token: token)
            Issue.record("idle session was accepted")
        } catch let error as AuthError {
            #expect(error == .unauthenticated)
        }
    }

    @Test("reauthentication freshness expires after five minutes")
    func reauthenticationFreshness() async throws {
        let store = InMemoryAuthStore()
        let (_, _, token) = try await seedSession(store: store, at: epoch)
        let laterCore = core(store: store, at: epoch.addingTimeInterval(301))
        let context = try await laterCore.authenticate(token: token)
        do {
            try laterCore.requireReauthenticated(context)
            Issue.record("stale reauthentication was accepted")
        } catch let error as AuthError {
            #expect(error == .reauthenticationRequired)
        }
    }

    @Test("recovery session cannot use normal session APIs")
    func recoveryRestriction() async throws {
        let store = InMemoryAuthStore()
        let (_, _, token) = try await seedSession(store: store, at: epoch, kind: .recovery)
        let currentCore = core(store: store, at: epoch)
        do {
            _ = try await currentCore.authenticate(token: token)
            Issue.record("recovery session was accepted as normal")
        } catch let error as AuthError {
            #expect(error == .recoverySessionRestricted)
        }
        let recoveryContext = try await currentCore.authenticate(token: token, allowRecovery: true)
        do {
            _ = try await currentCore.listSessions(context: recoveryContext)
            Issue.record("recovery session listed sessions")
        } catch let error as AuthError {
            #expect(error == .recoverySessionRestricted)
        }
    }

    @Test("last-seen writes are throttled to five minutes")
    func touchThrottling() async throws {
        let store = InMemoryAuthStore()
        let (_, session, token) = try await seedSession(store: store, at: epoch)
        let beforeThreshold = core(store: store, at: epoch.addingTimeInterval(299))
        _ = try await beforeThreshold.authenticate(token: token)
        #expect(try await store.session(id: session.id)?.lastSeenAt == epoch)

        let atThreshold = core(store: store, at: epoch.addingTimeInterval(300))
        _ = try await atThreshold.authenticate(token: token)
        #expect(try await store.session(id: session.id)?.lastSeenAt == epoch.addingTimeInterval(300))
    }

    @Test("users cannot revoke another user's session by ID")
    func sessionRevocationIDOR() async throws {
        let store = InMemoryAuthStore()
        let (_, _, firstToken) = try await seedSession(store: store, at: epoch)
        let (_, secondSession, _) = try await seedSession(store: store, at: epoch)
        let currentCore = core(store: store, at: epoch)
        let context = try await currentCore.authenticate(token: firstToken)
        do {
            try await currentCore.revokeSession(id: secondSession.id, context: context)
            Issue.record("another user's session was revoked")
        } catch let error as AuthError {
            #expect(error == .notFound)
        }
        #expect(try await store.session(id: secondSession.id) != nil)
    }
}
