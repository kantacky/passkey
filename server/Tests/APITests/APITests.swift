import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import Logging
import NIOCore
import Testing
@testable import API
@testable import Core
@testable import Persistence

@Suite("API error mapping")
struct APIErrorMappingTests {
    @Test("domain errors expose stable status and code")
    func stableErrors() {
        #expect(AuthError.unauthenticated.statusCode == 401)
        #expect(AuthError.reauthenticationRequired.statusCode == 403)
        #expect(AuthError.emailTaken.statusCode == 409)
        #expect(AuthError.rateLimited.statusCode == 429)
        #expect(AuthError.deviceMismatch.code == "device_mismatch")
    }
}

@Suite("HTTP credential and CSRF policy", .serialized)
struct HTTPCredentialPolicyTests {
    private func application() -> some ApplicationProtocol {
        let core = AuthCore(
            store: InMemoryAuthStore(),
            configuration: AuthConfiguration(rpID: "passkey.example.com", origin: "https://passkey.example.com"),
            mailQueue: MailQueue(sender: NullMailSender(), logger: Logger(label: "test"))
        )
        return Application(router: APIBuilder(core: core).router())
    }

    private func headers(_ pairs: [(String, String)]) -> HTTPFields {
        var fields = HTTPFields()
        for (name, value) in pairs {
            fields.append(HTTPField(name: HTTPField.Name(name)!, value: value))
        }
        return fields
    }

    @Test("Cookie and Bearer session credentials cannot be combined")
    func rejectsCombinedCredentials() async throws {
        try await application().test(.router) { client in
            let response = try await client.execute(
                uri: "/api/v1/email-verifications",
                method: .post,
                headers: headers([
                    ("Content-Type", "application/json"),
                    ("X-Client", "ios"),
                    ("Cookie", "__Host-session=cookie-token"),
                    ("Authorization", "Bearer bearer-token"),
                ]),
                body: ByteBuffer(string: #"{"email":"user@example.com","purpose":"signup"}"#)
            )
            #expect(response.status == .badRequest)
            #expect(String(buffer: response.body).contains("invalid_request"))
        }
    }

    @Test("cookie mutation requires the configured Origin")
    func rejectsOriginMismatch() async throws {
        try await application().test(.router) { client in
            let response = try await client.execute(
                uri: "/api/v1/email-verifications",
                method: .post,
                headers: headers([
                    ("Content-Type", "application/json"),
                    ("Origin", "https://evil.example.com"),
                    ("Cookie", "__Host-session=cookie-token"),
                    ("X-Client-IP", "192.0.2.1"),
                ]),
                body: ByteBuffer(string: #"{"email":"user@example.com","purpose":"signup"}"#)
            )
            #expect(response.status == .forbidden)
            #expect(String(buffer: response.body).contains("origin_mismatch"))
        }
    }
}
