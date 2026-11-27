import Foundation
import UIKit

extension Notification.Name {
  nonisolated static let passkeySessionExpired = Notification.Name("passkeySessionExpired")
}

enum APIError: Error, Equatable, LocalizedError {
  case invalidResponse
  case invalidBase64URL
  case httpStatus(Int, code: String?, message: String?, retryAfter: Int?)
  case missingSessionToken

  var errorDescription: String? {
    switch self {
    case .invalidResponse:
      "サーバーからの応答を解釈できませんでした"
    case .invalidBase64URL:
      "サーバーからのデータを解釈できませんでした"
    case let .httpStatus(_, _, message, _):
      message ?? "サーバーでエラーが発生しました"
    case .missingSessionToken:
      "サインイン情報が見つかりません"
    }
  }

  var errorCode: String? {
    guard case let .httpStatus(_, code, _, _) = self else { return nil }
    return code
  }

  var isReauthenticationRequired: Bool {
    errorCode == "reauthentication_required"
  }

  var isUnauthenticated: Bool {
    errorCode == "unauthenticated"
  }
}

protocol APIClient: Sendable {
  func startEmailVerification(email: String, purpose: VerificationPurpose) async throws -> EmailVerificationStartResponse
  func emailVerificationStatus(id: UUID, secret: String) async throws -> EmailVerificationStatusResponse
  func verifyEmail(id: UUID, secret: String, request: VerifyEmailRequest, includeSession: Bool) async throws -> VerifyEmailResponse
  func registrationOptions(flowSecret: String?) async throws -> RegistrationOptions
  func register(_ request: RegistrationFinishRequest, flowSecret: String?) async throws -> RegistrationFinishResponse
  func authenticationOptions(reauth: Bool) async throws -> AuthenticationOptions
  func authenticate(_ request: AssertionFinishRequest) async throws -> SessionResponse
  func me() async throws -> User
  func passkeys() async throws -> [PasskeyCredential]
  func renamePasskey(id: String, name: String?) async throws -> PasskeyCredential
  func deletePasskey(id: String) async throws -> DeletePasskeyResponse
  func sessions() async throws -> [UserSession]
  func signOut() async throws
  func revokeSession(id: UUID) async throws
  func revokeOtherSessions() async throws
  func deleteAccount(email: String) async throws
}

actor LiveAPIClient: APIClient {
  private let baseURL: URL
  private let urlSession: URLSession
  private let sessionStore: any SessionStore
  private let userAgent: String

  // UIDevice は MainActor 分離のため、User-Agent は生成時に MainActor 上で一度だけ組み立てる。
  @MainActor
  init(
    baseURL: URL? = nil,
    urlSession: URLSession? = nil,
    sessionStore: any SessionStore
  ) {
    if let baseURL {
      self.baseURL = baseURL
    } else if let configured = ProcessInfo.processInfo.environment["PASSKEY_API_BASE_URL"],
              let url = URL(string: configured) {
      self.baseURL = url
    } else {
      self.baseURL = PasskeyConfiguration.defaultAPIBaseURL
    }
    if let urlSession {
      self.urlSession = urlSession
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.httpCookieStorage = nil
      configuration.httpShouldSetCookies = false
      configuration.urlCache = nil
      self.urlSession = URLSession(configuration: configuration)
    }
    self.sessionStore = sessionStore
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    let device = UIDevice.current
    self.userAgent = "Passkey-iOS/\(version) (\(device.model); iOS \(device.systemVersion))"
  }

  func startEmailVerification(email: String, purpose: VerificationPurpose) async throws -> EmailVerificationStartResponse {
    try await send(
      method: "POST",
      path: "/email-verifications",
      body: EmailVerificationStartRequest(email: email, purpose: purpose)
    )
  }

  func emailVerificationStatus(id: UUID, secret: String) async throws -> EmailVerificationStatusResponse {
    try await send(
      method: "GET",
      path: "/email-verifications/\(id.uuidString)",
      flowSecret: secret
    )
  }

  func verifyEmail(id: UUID, secret: String, request: VerifyEmailRequest, includeSession: Bool) async throws -> VerifyEmailResponse {
    try await self.send(
      method: "POST",
      path: "/email-verifications/\(id.uuidString)/verify",
      body: request,
      flowSecret: secret,
      includeSession: includeSession
    )
  }

  func registrationOptions(flowSecret: String?) async throws -> RegistrationOptions {
    try await send(
      method: "POST",
      path: "/registrations/options",
      body: EmptyRequest(),
      flowSecret: flowSecret,
      includeSession: flowSecret == nil
    )
  }

  func register(_ request: RegistrationFinishRequest, flowSecret: String?) async throws -> RegistrationFinishResponse {
    try await self.send(
      method: "POST",
      path: "/registrations",
      body: request,
      flowSecret: flowSecret,
      includeSession: flowSecret == nil
    )
  }

  func authenticationOptions(reauth: Bool) async throws -> AuthenticationOptions {
    try await send(
      method: "POST",
      path: "/authentications/options",
      body: AuthenticationOptionsRequest(reauth: reauth)
    )
  }

  func authenticate(_ request: AssertionFinishRequest) async throws -> SessionResponse {
    try await self.send(method: "POST", path: "/authentications", body: request)
  }

  func me() async throws -> User {
    try await send(method: "GET", path: "/me")
  }

  func passkeys() async throws -> [PasskeyCredential] {
    let envelope: PasskeysEnvelope = try await send(method: "GET", path: "/passkeys")
    return envelope.passkeys
  }

  func renamePasskey(id: String, name: String?) async throws -> PasskeyCredential {
    try await send(
      method: "PATCH",
      path: "/passkeys/\(id)",
      body: RenamePasskeyRequest(name: name)
    )
  }

  func deletePasskey(id: String) async throws -> DeletePasskeyResponse {
    try await send(method: "DELETE", path: "/passkeys/\(id)")
  }

  func sessions() async throws -> [UserSession] {
    let envelope: SessionsEnvelope = try await send(method: "GET", path: "/sessions")
    return envelope.sessions
  }

  func signOut() async throws {
    let _: EmptyResponse = try await send(method: "DELETE", path: "/sessions/current")
  }

  func revokeSession(id: UUID) async throws {
    let _: EmptyResponse = try await send(method: "DELETE", path: "/sessions/\(id.uuidString)")
  }

  func revokeOtherSessions() async throws {
    let _: EmptyResponse = try await send(method: "POST", path: "/sessions/revoke-others", body: EmptyRequest())
  }

  func deleteAccount(email: String) async throws {
    let _: EmptyResponse = try await send(method: "DELETE", path: "/me", body: DeleteAccountRequest(email: email))
  }

  private func send<Response: Decodable>(
    method: String,
    path: String,
    flowSecret: String? = nil
  ) async throws -> Response {
    try await send(method: method, path: path, body: Optional<EmptyRequest>.none, flowSecret: flowSecret)
  }

  private func send<Body: Encodable, Response: Decodable>(
    method: String,
    path: String,
    body: Body? = nil,
    flowSecret: String? = nil,
    includeSession: Bool = true
  ) async throws -> Response {
    let url = URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)!
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = method
    urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
    urlRequest.setValue("ios", forHTTPHeaderField: "X-Client")
    urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    urlRequest.httpShouldHandleCookies = false
    if includeSession, let token = sessionStore.sessionToken() {
      urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    if let flowSecret {
      urlRequest.setValue(flowSecret, forHTTPHeaderField: "X-Flow-Secret")
    }
    if let body {
      urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
      urlRequest.httpBody = try JSONEncoder().encode(body)
    }

    let (data, response) = try await urlSession.data(for: urlRequest)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw APIError.invalidResponse
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      let error = apiError(statusCode: httpResponse.statusCode, data: data, response: httpResponse)
      if error.isUnauthenticated {
        NotificationCenter.default.post(name: .passkeySessionExpired, object: nil)
      }
      throw error
    }
    if Response.self == EmptyResponse.self, data.isEmpty {
      return EmptyResponse() as! Response
    }
    return try makeDecoder().decode(Response.self, from: data)
  }

  private func apiError(statusCode: Int, data: Data, response: HTTPURLResponse) -> APIError {
    struct ErrorEnvelope: Decodable {
      struct Detail: Decodable {
        let code: String?
        let message: String?
      }
      let error: Detail
    }
    let detail = try? makeDecoder().decode(ErrorEnvelope.self, from: data).error
    let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
    return .httpStatus(statusCode, code: detail?.code, message: detail?.message, retryAfter: retryAfter)
  }

  private func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let string = try container.decode(String.self)
      let fractional = ISO8601DateFormatter()
      fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = fractional.date(from: string) {
        return date
      }
      let plain = ISO8601DateFormatter()
      plain.formatOptions = [.withInternetDateTime]
      if let date = plain.date(from: string) {
        return date
      }
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 date: \(string)")
    }
    return decoder
  }
}
