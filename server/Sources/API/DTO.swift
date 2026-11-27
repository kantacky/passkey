public import Core
public import Foundation
public import WebAuthn


private func webAuthnMilliseconds(_ duration: Duration?) -> UInt32? {
    guard let duration else { return nil }
    let components = duration.components
    return UInt32(clamping: components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
}

struct StartEmailVerificationRequest: Decodable {
    var email: String
    var purpose: VerificationPurpose
}

struct StartEmailVerificationResponse: Encodable {
    var id: UUID
    var status: FlowStatus
    var secret: String?
}

struct FlowStatusResponse: Encodable {
    var id: UUID
    var status: FlowStatus
}

struct VerifyEmailRequest: Decodable {
    var token: String?
    var code: String?
}

struct VerifyEmailResponse: Encodable {
    var status: String
    var kind: SessionKind?
    var token: String?
    var email: String?
}

struct RegistrationOptionsResponse: Encodable {
    var challenge: String
    var rp: PublicKeyCredentialRelyingPartyEntity
    var user: PublicKeyCredentialUserEntity
    var pubKeyCredParams: [PublicKeyCredentialParameters]
    var timeout: UInt32?
    var attestation: AttestationConveyancePreference
    var authenticatorSelection: AuthenticatorSelection?
    var excludeCredentials: [PublicKeyCredentialDescriptor]

    init(data: RegistrationOptionsData) {
        challenge = Data(data.options.challenge).pkBase64URLEncodedString()
        rp = data.options.relyingParty
        user = data.options.user
        pubKeyCredParams = data.options.publicKeyCredentialParameters
        timeout = webAuthnMilliseconds(data.options.timeout)
        attestation = data.options.attestation
        authenticatorSelection = data.options.authenticatorSelection
        excludeCredentials = data.excludeCredentials
    }
}

struct RegistrationCredentialRequest: Decodable {
    struct ResponseBody: Decodable {
        var clientDataJSON: String
        var attestationObject: String
        var transports: [String]?
    }

    var id: String
    var type: String
    var rawId: String
    var response: ResponseBody

    func coreInput() throws -> RegistrationCredentialInput {
        guard type == "public-key",
              let rawID = Data(pkBase64URL: rawId),
              let clientData = Data(pkBase64URL: response.clientDataJSON),
              let attestation = Data(pkBase64URL: response.attestationObject) else {
            throw AuthError.invalidRequest()
        }
        return RegistrationCredentialInput(
            id: id,
            rawID: rawID,
            clientDataJSON: clientData,
            attestationObject: attestation,
            transports: response.transports ?? []
        )
    }
}

struct AuthenticationOptionsRequest: Decodable {
    var reauth: Bool?
}

struct AuthenticationOptionsResponse: Encodable {
    var challenge: String
    var rpId: String
    var allowCredentials: [PublicKeyCredentialDescriptor]?
    var userVerification: UserVerificationRequirement?
    var timeout: UInt32?

    init(data: AuthenticationOptionsData) {
        challenge = Data(data.options.challenge).pkBase64URLEncodedString()
        rpId = data.options.relyingPartyID
        allowCredentials = data.options.allowCredentials
        userVerification = data.options.userVerification
        timeout = webAuthnMilliseconds(data.options.timeout)
    }
}

struct AuthenticationCredentialRequest: Decodable {
    struct ResponseBody: Decodable {
        var clientDataJSON: String
        var authenticatorData: String
        var signature: String
        var userHandle: String?
        var attestationObject: String?
    }

    var id: String
    var type: String
    var rawId: String
    var response: ResponseBody
    var authenticatorAttachment: String?

    func coreInput() throws -> AuthenticationCredentialInput {
        guard type == "public-key",
              let rawID = Data(pkBase64URL: rawId),
              let clientData = Data(pkBase64URL: response.clientDataJSON),
              let authenticatorData = Data(pkBase64URL: response.authenticatorData),
              let signature = Data(pkBase64URL: response.signature) else {
            throw AuthError.invalidRequest()
        }
        return AuthenticationCredentialInput(
            id: id,
            rawID: rawID,
            clientDataJSON: clientData,
            authenticatorData: authenticatorData,
            signature: signature,
            userHandle: response.userHandle.flatMap { Data(pkBase64URL: $0) },
            attestationObject: response.attestationObject.flatMap { Data(pkBase64URL: $0) },
            authenticatorAttachment: authenticatorAttachment
        )
    }
}

struct UserResponse: Encodable {
    var id: UUID
    var email: String
    var userHandle: String

    init(user: User) {
        id = user.id
        email = user.email
        userHandle = user.userHandle.pkBase64URLEncodedString()
    }
}

struct RegistrationResponse: Encodable {
    var user: UserResponse
    var passkey: PasskeyPresentation
    var token: String?
}

struct AuthenticationResponse: Encodable {
    var user: UserResponse
    var token: String?
    var reauthenticated: Bool
}

struct MeResponse: Encodable {
    var id: UUID
    var email: String
    var userHandle: String
    var kind: SessionKind
    var recoveredAt: Date?
}

struct SessionsResponse: Encodable {
    var sessions: [SessionInfo]
}

struct PasskeysResponse: Encodable {
    var passkeys: [PasskeyPresentation]
}

struct PatchPasskeyRequest: Decodable {
    var name: String?
}

struct DeletePasskeyResponse: Encodable {
    var allAcceptedCredentialIds: [String]
}

struct DeleteMeRequest: Decodable {
    var email: String
}

struct EmptyResponse: Encodable {}

struct ErrorResponse: Encodable {
    struct Body: Encodable {
        var code: String
        var message: String
    }
    var error: Body
}
