import Foundation

enum VerificationPurpose: String, nonisolated Codable, Sendable {
  case signup
  case recovery
  case emailChange = "email_change"
}

enum VerificationStatus: String, nonisolated Codable, Sendable {
  case pending
  case verified
  case consumed
  case expired
}

enum SessionKind: String, nonisolated Codable, Sendable {
  case normal
  case recovery
}

struct EmailVerificationStartRequest: nonisolated Encodable, Sendable {
  let email: String
  let purpose: VerificationPurpose
}

struct EmailVerificationStartResponse: nonisolated Decodable, Sendable {
  let id: UUID
  let secret: String
  let expiresAt: Date?

  nonisolated init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let id = try container.decodeIfPresent(UUID.self, forKey: .id) {
      self.id = id
    } else if let id = try container.decodeIfPresent(UUID.self, forKey: .flowId) {
      self.id = id
    } else if let id = try container.decodeIfPresent(UUID.self, forKey: .flowID) {
      self.id = id
    } else {
      throw DecodingError.keyNotFound(CodingKeys.id, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "flow id is missing"))
    }
    if let secret = try container.decodeIfPresent(String.self, forKey: .secret) {
      self.secret = secret
    } else if let secret = try container.decodeIfPresent(String.self, forKey: .flowSecret) {
      self.secret = secret
    } else {
      throw DecodingError.keyNotFound(CodingKeys.secret, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "flow secret is missing"))
    }
    expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case flowId
    case flowID
    case secret
    case flowSecret
    case expiresAt
  }
}

struct EmailVerificationStatusResponse: nonisolated Decodable, Sendable {
  let status: VerificationStatus
}

struct VerifyEmailRequest: nonisolated Encodable, Sendable {
  let token: String?
  let code: String?

  static func token(_ token: String) -> Self {
    Self(token: token, code: nil)
  }

  static func code(_ code: String) -> Self {
    Self(token: nil, code: code)
  }
}

struct VerifyEmailResponse: nonisolated Decodable, Sendable {
  let status: VerificationStatus?
  let session: SessionResponse?
  let email: String?

  nonisolated init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    status = try container.decodeIfPresent(VerificationStatus.self, forKey: .status)
    email = try container.decodeIfPresent(String.self, forKey: .email)
    if let session = try container.decodeIfPresent(SessionResponse.self, forKey: .session) {
      self.session = session
    } else if let token = try container.decodeIfPresent(String.self, forKey: .sessionToken) {
      session = SessionResponse(token: token)
    } else if let token = try container.decodeIfPresent(String.self, forKey: .token) {
      session = SessionResponse(token: token)
    } else {
      session = nil
    }
  }

  private enum CodingKeys: String, CodingKey {
    case status
    case session
    case sessionToken
    case token
    case email
  }
}

struct RelyingParty: nonisolated Codable, Sendable {
  let id: String
  let name: String
}

struct WebAuthnUser: nonisolated Codable, Sendable {
  let id: String
  let name: String
  let displayName: String
}

struct PublicKeyCredentialParameters: nonisolated Codable, Sendable {
  let type: String
  let alg: Int
}

struct CredentialDescriptor: nonisolated Codable, Sendable {
  let type: String
  let id: String
  let transports: [String]?
}

struct RegistrationOptions: nonisolated Decodable, Sendable {
  let challenge: String
  let rp: RelyingParty
  let user: WebAuthnUser
  let pubKeyCredParams: [PublicKeyCredentialParameters]
  let excludeCredentials: [CredentialDescriptor]?

  nonisolated init(from decoder: any Decoder) throws {
    let root = try decoder.container(keyedBy: CodingKeys.self)
    let container = (try? root.nestedContainer(keyedBy: CodingKeys.self, forKey: .publicKey)) ?? root
    challenge = try container.decode(String.self, forKey: .challenge)
    rp = try container.decode(RelyingParty.self, forKey: .rp)
    user = try container.decode(WebAuthnUser.self, forKey: .user)
    pubKeyCredParams = try container.decode([PublicKeyCredentialParameters].self, forKey: .pubKeyCredParams)
    excludeCredentials = try container.decodeIfPresent([CredentialDescriptor].self, forKey: .excludeCredentials)
  }

  private enum CodingKeys: String, CodingKey {
    case publicKey
    case challenge
    case rp
    case user
    case pubKeyCredParams
    case excludeCredentials
  }
}

struct AuthenticationOptions: nonisolated Decodable, Sendable {
  let challenge: String
  let rpId: String
  let allowCredentials: [CredentialDescriptor]?
  let userVerification: String?

  nonisolated init(from decoder: any Decoder) throws {
    let root = try decoder.container(keyedBy: CodingKeys.self)
    let container = (try? root.nestedContainer(keyedBy: CodingKeys.self, forKey: .publicKey)) ?? root
    challenge = try container.decode(String.self, forKey: .challenge)
    rpId = try container.decode(String.self, forKey: .rpId)
    allowCredentials = try container.decodeIfPresent([CredentialDescriptor].self, forKey: .allowCredentials)
    userVerification = try container.decodeIfPresent(String.self, forKey: .userVerification)
  }

  private enum CodingKeys: String, CodingKey {
    case publicKey
    case challenge
    case rpId
    case allowCredentials
    case userVerification
  }
}

struct AuthenticationOptionsRequest: nonisolated Encodable, Sendable {
  let reauth: Bool
}

struct RegistrationResponsePayload: nonisolated Encodable, Sendable {
  let clientDataJSON: String
  let attestationObject: String
  let transports: [String]
}

struct RegistrationFinishRequest: nonisolated Encodable, Sendable {
  let id: String
  let rawId: String
  let type: String
  let response: RegistrationResponsePayload
}

struct AssertionResponsePayload: nonisolated Encodable, Sendable {
  let clientDataJSON: String
  let authenticatorData: String
  let signature: String
  let userHandle: String
}

struct AssertionFinishRequest: nonisolated Encodable, Sendable {
  let id: String
  let rawId: String
  let type: String
  let response: AssertionResponsePayload
}


struct RegistrationFinishResponse: nonisolated Decodable, Sendable {
  let token: String?
  let passkey: PasskeyCredential?

  nonisolated init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let token = try container.decodeIfPresent(String.self, forKey: .token) {
      self.token = token
    } else if let session = try container.decodeIfPresent(SessionResponse.self, forKey: .session) {
      token = session.token
    } else {
      token = nil
    }
    passkey = try container.decodeIfPresent(PasskeyCredential.self, forKey: .passkey)
  }

  private enum CodingKeys: String, CodingKey {
    case token
    case session
    case passkey
  }
}

struct SessionResponse: nonisolated Decodable, Sendable {
  let token: String

  nonisolated init(token: String) {
    self.token = token
  }

  nonisolated init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let token = try container.decodeIfPresent(String.self, forKey: .token) {
      self.token = token
      return
    }
    if let nested = try container.decodeIfPresent(SessionResponse.self, forKey: .session) {
      self = nested
      return
    }
    throw DecodingError.keyNotFound(
      CodingKeys.token,
      DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "session token is missing")
    )
  }

  private enum CodingKeys: String, CodingKey {
    case token
    case session
  }
}

struct User: nonisolated Decodable, Sendable {
  let id: UUID
  let email: String
  let userHandle: String
  let kind: SessionKind
  let recoveredAt: Date?
}

struct PasskeyCredential: nonisolated Decodable, Identifiable, Sendable {
  let id: String
  let name: String?
  let aaguid: UUID?
  let providerName: String?
  let customName: String?
  let iconLight: String?
  let iconDark: String?
  let transports: [String]?
  let backupEligible: Bool
  let backupState: Bool
  let createdAt: Date
  let lastUsedAt: Date?
}

struct PasskeysEnvelope: nonisolated Decodable, Sendable {
  let passkeys: [PasskeyCredential]

  nonisolated init(from decoder: any Decoder) throws {
    if let container = try? decoder.singleValueContainer(),
       let passkeys = try? container.decode([PasskeyCredential].self) {
      self.passkeys = passkeys
      return
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    passkeys = try container.decode([PasskeyCredential].self, forKey: .passkeys)
  }

  private enum CodingKeys: String, CodingKey {
    case passkeys
  }
}

struct RenamePasskeyRequest: nonisolated Encodable, Sendable {
  let name: String?
}

struct DeletePasskeyResponse: nonisolated Decodable, Sendable {
  let allAcceptedCredentialIds: [String]

  nonisolated init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let value = try container.decodeIfPresent([String].self, forKey: .allAcceptedCredentialIds) {
      allAcceptedCredentialIds = value
    } else if let value = try container.decodeIfPresent([String].self, forKey: .allAcceptedCredentialIDs) {
      allAcceptedCredentialIds = value
    } else if let value = try container.decodeIfPresent([String].self, forKey: .credentialIDs) {
      allAcceptedCredentialIds = value
    } else {
      allAcceptedCredentialIds = []
    }
  }

  private enum CodingKeys: String, CodingKey {
    case allAcceptedCredentialIds
    case allAcceptedCredentialIDs
    case credentialIDs
  }
}

struct UserSession: nonisolated Decodable, Identifiable, Sendable {
  let id: UUID
  let deviceLabel: String
  let createdAt: Date
  let lastSeenAt: Date
  let current: Bool

  nonisolated init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    deviceLabel = try container.decode(String.self, forKey: .deviceLabel)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    lastSeenAt = try container.decode(Date.self, forKey: .lastSeenAt)
    current = try container.decodeIfPresent(Bool.self, forKey: .current)
      ?? container.decodeIfPresent(Bool.self, forKey: .isCurrent)
      ?? false
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case deviceLabel
    case createdAt
    case lastSeenAt
    case current
    case isCurrent
  }
}

struct SessionsEnvelope: nonisolated Decodable, Sendable {
  let sessions: [UserSession]

  nonisolated init(from decoder: any Decoder) throws {
    if let container = try? decoder.singleValueContainer(),
       let sessions = try? container.decode([UserSession].self) {
      self.sessions = sessions
      return
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sessions = try container.decode([UserSession].self, forKey: .sessions)
  }

  private enum CodingKeys: String, CodingKey {
    case sessions
  }
}

struct DeleteAccountRequest: nonisolated Encodable, Sendable {
  let email: String
}

struct EmptyRequest: nonisolated Encodable, Sendable {}
struct EmptyResponse: nonisolated Decodable, Sendable {}

extension Data {
  init?(base64URLEncoded string: String) {
    var base64 = string
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let padding = (4 - base64.count % 4) % 4
    base64 += String(repeating: "=", count: padding)
    self.init(base64Encoded: base64)
  }

  var base64URLEncodedString: String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
