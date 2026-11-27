public import Foundation
import Logging
public import WebAuthn

public struct RegistrationOptionsData: Sendable {
    public var options: PublicKeyCredentialCreationOptions
    public var excludeCredentials: [PublicKeyCredentialDescriptor]

    public init(options: PublicKeyCredentialCreationOptions, excludeCredentials: [PublicKeyCredentialDescriptor]) {
        self.options = options
        self.excludeCredentials = excludeCredentials
    }
}

public struct RegistrationCredentialInput: Sendable {
    public var id: String
    public var rawID: Data
    public var clientDataJSON: Data
    public var attestationObject: Data
    public var transports: [String]

    public init(id: String, rawID: Data, clientDataJSON: Data, attestationObject: Data, transports: [String] = []) {
        self.id = id
        self.rawID = rawID
        self.clientDataJSON = clientDataJSON
        self.attestationObject = attestationObject
        self.transports = transports
    }
}

public struct RegistrationResult: Sendable, Equatable {
    public var user: User
    public var passkey: Passkey
    public var session: IssuedSession
}

extension AuthCore {
    public static var supportedCredentialParameters: [PublicKeyCredentialParameters] {
        [
            PublicKeyCredentialParameters(alg: .algES256),
            PublicKeyCredentialParameters(alg: .algRS256),
        ]
    }

    public func registrationOptions(flowSecret: String?, authenticatedContext: AuthenticatedContext?) async throws -> RegistrationOptionsData {
        guard (flowSecret == nil) != (authenticatedContext == nil) else { throw AuthError.invalidRequest() }
        let current = now
        let email: String
        let userHandle: Data
        let purpose: ChallengePurpose
        var userID: UUID?
        var sessionID: UUID?
        var flowID: UUID?
        var exclude: [PublicKeyCredentialDescriptor] = []

        if let flowSecret {
            guard let flow = try await store.emailVerification(secretHash: SecurityUtils.sha256(flowSecret)) else { throw AuthError.unauthenticated }
            guard flow.purpose == .signup, flow.status(at: current) == .verified else { throw AuthError.flowExpired }
            email = flow.email
            userHandle = SecurityUtils.randomBytes(count: 64)
            purpose = .signup
            flowID = flow.id
        } else if let context = authenticatedContext {
            email = context.user.email
            userHandle = context.user.userHandle
            userID = context.user.id
            sessionID = context.session.id
            switch context.session.kind {
            case .normal:
                try requireReauthenticated(context)
                purpose = .addPasskey
            case .recovery:
                purpose = .recovery
            }
            exclude = try await store.passkeys(userID: context.user.id).map {
                PublicKeyCredentialDescriptor(
                    id: [UInt8]($0.id),
                    transports: $0.transports.map { .init($0) }
                )
            }
        } else {
            throw AuthError.unauthenticated
        }

        var options = webAuthn.beginRegistration(
            user: PublicKeyCredentialUserEntity(id: [UInt8](userHandle), name: email, displayName: email),
            timeout: .milliseconds(240_000),
            attestation: .none,
            publicKeyCredentialParameters: Self.supportedCredentialParameters,
            authenticatorSelection: AuthenticatorSelection(residentKey: .required, userVerification: .required)
        )
        let challenge = WebAuthnChallenge(
            id: SecurityUtils.uuidv7(at: current),
            challenge: Data(options.challenge),
            purpose: purpose,
            userID: userID,
            sessionID: sessionID,
            flowID: flowID,
            userHandle: userHandle,
            expiresAt: current.addingTimeInterval(configuration.challengeLifetime)
        )
        try await store.insertChallenge(challenge)
        return RegistrationOptionsData(options: options, excludeCredentials: exclude)
    }

    public func finishRegistration(
        input: RegistrationCredentialInput,
        flowSecret: String?,
        authenticatedContext: AuthenticatedContext?,
        userAgent: String?,
        client: ClientKind
    ) async throws -> RegistrationResult {
        guard input.rawID.count <= 1023, !input.rawID.isEmpty else { throw AuthError.verificationFailed }
        guard input.rawID.pkBase64URLEncodedString() == input.id else { throw AuthError.verificationFailed }
        let clientData = try validateClientData([UInt8](input.clientDataJSON), expectedType: "webauthn.create")
        let storedChallenge = try await consumeChallenge(clientData.challenge)
        guard let attestationMetadata = WebAuthnBinaryInspector.attestationMetadata(attestationObject: input.attestationObject) else {
            throw AuthError.verificationFailed
        }
        guard attestationMetadata.backupEligible || !attestationMetadata.backupState else { throw AuthError.verificationFailed }
        guard attestationMetadata.userVerified else { throw AuthError.verificationFailed }

        var signupFlow: EmailVerification?
        var context: AuthenticatedContext?
        switch storedChallenge.purpose {
        case .signup:
            guard let flowSecret,
                  let flow = try await store.emailVerification(secretHash: SecurityUtils.sha256(flowSecret)),
                  flow.id == storedChallenge.flowID,
                  flow.purpose == .signup,
                  flow.status(at: now) == .verified else {
                throw AuthError.invalidChallenge
            }
            signupFlow = flow
        case .addPasskey, .recovery:
            guard let authenticatedContext,
                  authenticatedContext.session.id == storedChallenge.sessionID,
                  authenticatedContext.user.id == storedChallenge.userID else {
                throw AuthError.invalidChallenge
            }
            if storedChallenge.purpose == .addPasskey {
                guard authenticatedContext.session.kind == .normal else { throw AuthError.recoverySessionRestricted }
                try requireReauthenticated(authenticatedContext)
            } else {
                guard authenticatedContext.session.kind == .recovery else { throw AuthError.invalidChallenge }
            }
            context = authenticatedContext
        case .authentication, .reauthentication:
            throw AuthError.invalidChallenge
        }

        guard let userHandle = storedChallenge.userHandle else { throw AuthError.invalidChallenge }
        let credential = try await finishWebAuthnRegistration(input: input, challenge: [UInt8](clientData.challenge))
        guard let alg = WebAuthnBinaryInspector.coseAlgorithm(publicKey: Data(credential.publicKey)),
              Self.supportedCredentialParameters.map(\.alg.rawValue).contains(alg) else {
            throw AuthError.verificationFailed
        }

        let device = SecurityUtils.deviceLabel(userAgent: userAgent, client: client)
        let current = now

        if let flow = signupFlow {
            let user = User(
                id: SecurityUtils.uuidv7(at: current),
                userHandle: userHandle,
                email: flow.email,
                createdAt: current
            )
            let passkey = Passkey(
                id: input.rawID,
                userID: user.id,
                publicKey: Data(credential.publicKey),
                alg: alg,
                signCount: Int64(credential.signCount),
                aaguid: credential.aaguid?.id,
                transports: input.transports,
                uvInitialized: true,
                backupEligible: credential.backupEligible,
                backupState: credential.isBackedUp,
                createdAt: current,
                lastUsedAt: current
            )
            let issued = makeSession(userID: user.id, kind: .normal, deviceLabel: device, reauthenticated: true)
            let write = try await store.createUserWithPasskeyAndSession(
                user: user,
                passkey: passkey,
                session: issued.session,
                consumeFlowID: flow.id,
                consumedAt: current
            )
            switch write {
            case .success: break
            case .emailTaken: throw AuthError.emailTaken
            case .credentialExists: throw AuthError.credentialExists
            case .flowUnavailable: throw AuthError.flowExpired
            }
            securityEvent("signup_completed", metadata: ["user_id": "\(user.id.uuidString)"])
            return RegistrationResult(user: user, passkey: passkey, session: issued)
        }

        guard let context else { throw AuthError.unauthenticated }
        let passkey = Passkey(
            id: input.rawID,
            userID: context.user.id,
            publicKey: Data(credential.publicKey),
            alg: alg,
            signCount: Int64(credential.signCount),
            aaguid: credential.aaguid?.id,
            transports: input.transports,
            uvInitialized: true,
            backupEligible: credential.backupEligible,
            backupState: credential.isBackedUp,
            createdAt: current,
            lastUsedAt: current
        )

        if context.session.kind == .recovery {
            var user = context.user
            user.recoveredAt = current
            let issued = makeSession(userID: user.id, kind: .normal, fromRecovery: true, deviceLabel: device, reauthenticated: true)
            let write = try await store.completeRecovery(
                passkey: passkey,
                recoverySessionID: context.session.id,
                newSession: issued.session,
                recoveredAt: current
            )
            switch write {
            case .success: break
            case .credentialExists: throw AuthError.credentialExists
            case .emailTaken, .flowUnavailable: throw AuthError.verificationFailed
            }
            securityEvent("recovery_completed", metadata: ["user_id": "\(user.id.uuidString)"])
            await mailQueue.enqueue(notificationMail(email: user.email, operation: "アカウント回復の完了", deviceLabel: device))
            return RegistrationResult(user: user, passkey: passkey, session: issued)
        }

        let write = try await store.addPasskey(passkey)
        switch write {
        case .success: break
        case .credentialExists: throw AuthError.credentialExists
        case .emailTaken, .flowUnavailable: throw AuthError.verificationFailed
        }
        securityEvent("passkey_added", metadata: ["user_id": "\(context.user.id.uuidString)"])
        await mailQueue.enqueue(notificationMail(email: context.user.email, operation: "パスキー追加", deviceLabel: device))
        return RegistrationResult(user: context.user, passkey: passkey, session: IssuedSession(session: context.session, token: ""))
    }

    private func finishWebAuthnRegistration(input: RegistrationCredentialInput, challenge: [UInt8]) async throws -> Credential {
        let registrationCredential = RegistrationCredential(
            id: URLEncodedBase64(input.id),
            type: .publicKey,
            rawID: [UInt8](input.rawID),
            attestationResponse: AuthenticatorAttestationResponse(
                clientDataJSON: [UInt8](input.clientDataJSON),
                attestationObject: [UInt8](input.attestationObject)
            )
        )
        do {
            return try await webAuthn.finishRegistration(
                challenge: challenge,
                credentialCreationData: registrationCredential,
                requireUserVerification: true,
                supportedPublicKeyAlgorithms: Self.supportedCredentialParameters,
                confirmCredentialIDNotRegisteredYet: { idString in
                    guard let bytes = Data(pkBase64URL: idString) else { return false }
                    return try await store.passkey(credentialID: bytes) == nil
                }
            )
        } catch let error as WebAuthnError {
            if error == .credentialIDAlreadyExists { throw AuthError.credentialExists }
            throw AuthError.verificationFailed
        } catch {
            throw AuthError.verificationFailed
        }
    }
}
