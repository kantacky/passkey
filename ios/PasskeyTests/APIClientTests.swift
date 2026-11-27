import Foundation
import Testing
@testable import Passkey

nonisolated final class InMemorySessionStore: SessionStore, @unchecked Sendable {
  private var token: String?
  private var flow: (id: UUID, secret: String)?

  init(token: String? = nil) {
    self.token = token
  }

  nonisolated func sessionToken() -> String? {
    token
  }

  nonisolated func saveSessionToken(_ newToken: String) throws {
    token = newToken
  }

  nonisolated func deleteSessionToken() throws {
    token = nil
  }

  nonisolated func activeFlow() -> (id: UUID, secret: String)? {
    flow
  }

  nonisolated func saveActiveFlow(id: UUID, secret: String) throws {
    flow = (id, secret)
  }

  nonisolated func deleteActiveFlow() throws {
    flow = nil
  }
}

nonisolated final class RecordedRequest: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [URLRequest] = []

  func append(_ request: URLRequest) {
    lock.lock()
    storage.append(request)
    lock.unlock()
  }

  var requests: [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

nonisolated final class MockURLProtocol: URLProtocol {
  nonisolated(unsafe) static var recorder = RecordedRequest()
  nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    Self.recorder.append(request)
    guard let handler = Self.handler, let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    let (response, data) = handler(request)
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
    _ = url
  }

  override func stopLoading() {}
}

@Suite(.serialized)
struct APIClientTests {
  @Test func sendsIOSHeadersAndBearerToken() async throws {
    let recorder = MockURLProtocol.recorder
    MockURLProtocol.handler = { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(#"{"id":"5F2E0451-0000-0000-0000-000000000000","email":"user@example.com","userHandle":"AAEC","kind":"normal","recoveredAt":null}"#.utf8))
    }
    defer { MockURLProtocol.handler = nil }

    let client = makeClient()
    let user = try await client.me()
    #expect(user.email == "user@example.com")
    let request = try #require(recorder.requests.last)
    #expect(request.url?.absoluteString == "https://example.test/api/v1/me")
    #expect(request.value(forHTTPHeaderField: "X-Client") == "ios")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
    #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Passkey-iOS/") == true)
  }

  @Test func decodesAPIErrorCode() async throws {
    MockURLProtocol.handler = { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 403,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, Data(#"{"error":{"code":"reauthentication_required","message":"再認証してください"}}"#.utf8))
    }
    defer { MockURLProtocol.handler = nil }

    do {
      _ = try await makeClient().passkeys()
      Issue.record("expected an API error")
    } catch let error as APIError {
      #expect(error.errorCode == "reauthentication_required")
      #expect(error.isReauthenticationRequired)
    }
  }

  @Test func sendsFlowSecretHeader() async throws {
    MockURLProtocol.handler = { request in
      #expect(request.value(forHTTPHeaderField: "X-Flow-Secret") == "secret")
      let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (response, Data(#"{"status":"pending"}"#.utf8))
    }
    defer { MockURLProtocol.handler = nil }

    let status = try await makeClient().emailVerificationStatus(
      id: UUID(uuidString: "5F2E0451-0000-0000-0000-000000000000")!,
      secret: "secret"
    )
    #expect(status.status == .pending)
  }

  private func makeClient() -> LiveAPIClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return LiveAPIClient(
      baseURL: URL(string: "https://example.test/api/v1")!,
      urlSession: URLSession(configuration: configuration),
      sessionStore: InMemorySessionStore(token: "token")
    )
  }
}
