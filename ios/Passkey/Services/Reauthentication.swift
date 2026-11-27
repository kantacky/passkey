import Foundation

@MainActor
func reauthenticate(
  api: any APIClient,
  passkeyService: any PasskeyService,
  sessionStore: any SessionStore
) async throws {
  let options = try await api.authenticationOptions(reauth: true)
  let assertion = try await passkeyService.assertPasskey(options: options, presentation: .modal)
  let session = try await api.authenticate(assertion)
  try sessionStore.saveSessionToken(session.token)
}

@MainActor
func withReauthentication<T>(
  api: any APIClient,
  passkeyService: any PasskeyService,
  sessionStore: any SessionStore,
  operation: () async throws -> T
) async throws -> T {
  do {
    return try await operation()
  } catch let error as APIError where error.isReauthenticationRequired {
    try await reauthenticate(api: api, passkeyService: passkeyService, sessionStore: sessionStore)
    return try await operation()
  }
}
