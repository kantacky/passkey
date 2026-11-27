import Foundation
import Testing
@testable import Passkey

struct ModelTests {
  @Test func base64URLRoundTrip() throws {
    let bytes = Data([0, 1, 2, 250, 251, 252, 253, 254, 255])
    let encoded = bytes.base64URLEncodedString
    #expect(!encoded.contains("+"))
    #expect(!encoded.contains("/"))
    #expect(!encoded.contains("="))
    #expect(Data(base64URLEncoded: encoded) == bytes)
  }

  @Test func base64URLAcceptsPaddedInput() throws {
    #expect(Data(base64URLEncoded: "AAEC") == Data([0, 1, 2]))
    #expect(Data(base64URLEncoded: "AAEC+///") == Data([0, 1, 2, 251, 255, 255]))
  }

  @Test func decodesNestedSessionToken() throws {
    let data = Data(#"{"session":{"token":"token-value"}}"#.utf8)
    let response = try JSONDecoder().decode(SessionResponse.self, from: data)
    #expect(response.token == "token-value")
  }

  @Test func decodesFlatSessionToken() throws {
    let data = Data(#"{"token":"token-value"}"#.utf8)
    let response = try JSONDecoder().decode(SessionResponse.self, from: data)
    #expect(response.token == "token-value")
  }

  @Test func decodesPasskeysEnvelopeFromArray() throws {
    let json = #"""
    [
      {
        "id": "AQID",
        "name": null,
        "aaguid": null,
        "providerName": null,
        "transports": ["internal"],
        "backupEligible": true,
        "backupState": true,
        "createdAt": "2026-11-27T12:00:00Z",
        "lastUsedAt": null
      }
    ]
    """#
    let envelope = try makeAPIDecoder().decode(PasskeysEnvelope.self, from: Data(json.utf8))
    #expect(envelope.passkeys.count == 1)
    #expect(envelope.passkeys[0].id == "AQID")
  }


  @Test func decodesRegistrationResponseWithoutToken() throws {
    let data = Data(#"{"user":{"id":"5F2E0451-0000-0000-0000-000000000000","email":"user@example.com","userHandle":"AAEC"}}"#.utf8)
    let response = try JSONDecoder().decode(RegistrationFinishResponse.self, from: data)
    #expect(response.token == nil)
  }

  @Test func decodesNestedAuthenticationOptions() throws {
    let json = #"""
    {"publicKey":{"challenge":"AAEC","rpId":"passkey.kantacky.com","allowCredentials":[],"userVerification":"required"}}
    """#
    let options = try JSONDecoder().decode(AuthenticationOptions.self, from: Data(json.utf8))
    #expect(options.rpId == "passkey.kantacky.com")
  }

  @Test func decodesSessionIsCurrentAlias() throws {
    let json = #"""
    {"id":"5F2E0451-0000-0000-0000-000000000000","deviceLabel":"Passkey-iOS","createdAt":"2026-11-27T12:00:00Z","lastSeenAt":"2026-11-27T12:00:00Z","isCurrent":true}
    """#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let session = try decoder.decode(UserSession.self, from: Data(json.utf8))
    #expect(session.current)
  }

  private func makeAPIDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
