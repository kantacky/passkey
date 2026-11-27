public import Foundation
import Logging
public import WebAuthn

public struct AuthenticationOptionsData: Sendable {
    public var options: PublicKeyCredentialRequestOptions

    public init(options: PublicKeyCredentialRequestOptions) {
        self.options = options
    }
}

public struct AuthenticationCredentialInput: Sendable {
    public var id: String
    public var rawID: Data
    public var clientDataJSON: Data
    public var authenticatorData: Data
    public var signature: Data
    public var userHandle: Data?
    public var attestationObject: Data?
    public var authenticatorAttachment: String?

    public init(
        id: String,
        rawID: Data,
        clientDataJSON: Data,
        authenticatorData: Data,
        signature: Data,
        userHandle: Data?,
        attestationObject: Data? = nil,
        authenticatorAttachment: String? = nil
    ) {
        self.id = id
        self.rawID = rawID
        self.clientDataJSON = clientDataJSON
        self.authenticatorData = authenticatorData
        self.signature = signature
        self.userHandle = userHandle
        self.attestationObject = attestationObject
        self.authenticatorAttachment = authenticatorAttachment
    }
}

public struct AuthenticationResult: Sendable, Equatable {
    public var user: User
    public var session: IssuedSession
    public var isReauthentication: Bool
}

extension AuthCore {
    public func authenticationOptions(reauth: Bool, authenticatedContext: AuthenticatedContext?) async throws -> AuthenticationOptionsData {
        let current = now
        let allowCredentials: [PublicKeyCredentialDescriptor]?
        let purpose: ChallengePurpose
        var userID: UUID?
        var sessionID: UUID?

        if reauth {
            guard let context = authenticatedContext, context.session.kind == .normal else { throw AuthError.unauthenticated }
            let passkeys = try await store.passkeys(userID: context.user.id)
            allowCredentials = passkeys.map {
                PublicKeyCredentialDescriptor(id: [UInt8]($0.id), transports: $0.transports.map { .init($0) })
            }
            purpose = .reauthentication
            userID = context.user.id
            sessionID = context.session.id
        } else {
            allowCredentials = []
            purpose = .authentication
        }

        let options = webAuthn.beginAuthentication(
            timeout: .milliseconds(240_000),
            allowCredentials: allowCredentials,
            userVerification: .required
        )
        try await store.insertChallenge(
            WebAuthnChallenge(
                id: SecurityUtils.uuidv7(at: current),
                challenge: Data(options.challenge),
                purpose: purpose,
                userID: userID,
                sessionID: sessionID,
                expiresAt: current.addingTimeInterval(configuration.challengeLifetime)
            )
        )
        return AuthenticationOptionsData(options: options)
    }

    public func finishAuthentication(
        input: AuthenticationCredentialInput,
        authenticatedContext: AuthenticatedContext?,
        ip: String,
        userAgent: String?,
        client: ClientKind
    ) async throws -> AuthenticationResult {
        do {
            return try await finishAuthenticationInner(
                input: input,
                authenticatedContext: authenticatedContext,
                userAgent: userAgent,
                client: client
            )
        } catch {
            let normalizedIP = SecurityUtils.normalizeClientIP(ip)
            let failures = try? await store.incrementRateLimit(
                key: "authentication_fail:ip:\(normalizedIP)",
                windowStart: SecurityUtils.hourWindowStart(for: now)
            )
            securityEvent("authentication_failed")
            if let failures, failures > 30 {
                let windowStart = SecurityUtils.hourWindowStart(for: now)
                let retryAfter = max(1, 3600 - Int(now.timeIntervalSince(windowStart)))
                throw AuthError(statusCode: 429, code: "rate_limited", message: AuthError.rateLimited.message, retryAfter: retryAfter)
            }
            throw error
        }
    }

    private func finishAuthenticationInner(
        input: AuthenticationCredentialInput,
        authenticatedContext: AuthenticatedContext?,
        userAgent: String?,
        client: ClientKind
    ) async throws -> AuthenticationResult {
        guard input.rawID.pkBase64URLEncodedString() == input.id else { throw AuthError.verificationFailed }
        let clientData = try validateClientData([UInt8](input.clientDataJSON), expectedType: "webauthn.get")
        let storedChallenge = try await consumeChallenge(clientData.challenge)

        guard let passkey = try await store.passkey(credentialID: input.rawID) else {
            throw AuthError.unknownCredential
        }
        guard let userHandle = input.userHandle, !userHandle.isEmpty else { throw AuthError.verificationFailed }
        guard let handleUser = try await store.user(userHandle: userHandle), handleUser.id == passkey.userID else {
            throw AuthError.verificationFailed
        }

        let isReauthentication: Bool
        switch storedChallenge.purpose {
        case .authentication:
            isReauthentication = false
        case .reauthentication:
            guard let context = authenticatedContext,
                  context.session.kind == .normal,
                  context.session.id == storedChallenge.sessionID,
                  context.user.id == storedChallenge.userID,
                  passkey.userID == context.user.id else {
                throw AuthError.invalidChallenge
            }
            isReauthentication = true
        case .signup, .addPasskey, .recovery:
            throw AuthError.invalidChallenge
        }

        let assertion = AuthenticationCredential(
            id: URLEncodedBase64(input.id),
            rawID: [UInt8](input.rawID),
            response: AuthenticatorAssertionResponse(
                clientDataJSON: [UInt8](input.clientDataJSON),
                authenticatorData: [UInt8](input.authenticatorData),
                signature: [UInt8](input.signature),
                userHandle: input.userHandle.map { [UInt8]($0) },
                attestationObject: input.attestationObject.map { [UInt8]($0) }
            ),
            authenticatorAttachment: input.authenticatorAttachment.map { .init($0) },
            type: .publicKey
        )

        let verified: VerifiedAuthentication
        do {
            verified = try webAuthn.finishAuthentication(
                credential: assertion,
                expectedChallenge: [UInt8](clientData.challenge),
                credentialPublicKey: [UInt8](passkey.publicKey),
                credentialCurrentSignCount: 0,
                requireUserVerification: true
            )
        } catch {
            throw AuthError.verificationFailed
        }

        let backupEligible = verified.credentialDeviceType == .multiDevice
        guard backupEligible == passkey.backupEligible else { throw AuthError.verificationFailed }

        let current = now
        let newCount = Int64(verified.newSignCount)
        let anomaly = (newCount != 0 || passkey.signCount != 0) && newCount <= passkey.signCount
        if anomaly {
            securityEvent("sign_count_anomaly", metadata: ["user_id": "\(passkey.userID.uuidString)"])
        }
        try await store.updatePasskeyAuthentication(
            credentialID: passkey.id,
            newSignCount: newCount,
            signCountAnomalyAt: anomaly ? current : nil,
            backupState: verified.credentialBackedUp,
            lastUsedAt: current
        )

        let device = SecurityUtils.deviceLabel(userAgent: userAgent, client: client)
        if isReauthentication {
            guard let context = authenticatedContext else { throw AuthError.unauthenticated }
            let token = SecurityUtils.randomToken()
            guard let rotated = try await store.rotateSessionToken(
                sessionID: context.session.id,
                newTokenHash: tokenHash(token),
                reauthenticatedAt: current
            ) else {
                throw AuthError.unauthenticated
            }
            securityEvent("reauthentication_succeeded", metadata: ["user_id": "\(context.user.id.uuidString)"])
            return AuthenticationResult(user: context.user, session: IssuedSession(session: rotated, token: token), isReauthentication: true)
        }

        if let existing = authenticatedContext {
            try await store.deleteSession(id: existing.session.id)
        }
        let issued = makeSession(userID: handleUser.id, kind: .normal, deviceLabel: device, reauthenticated: true)
        try await store.createSession(issued.session, maximumPerUser: configuration.maximumSessionsPerUser)
        securityEvent("sign_in_succeeded", metadata: ["user_id": "\(handleUser.id.uuidString)"])
        return AuthenticationResult(user: handleUser, session: issued, isReauthentication: false)
    }
}
