import AuthenticationServices
import Foundation

enum CredentialSignalError: Error, Equatable {
  case invalidBase64URL
}

protocol CredentialSignalService: Sendable {
  func reportUnknownCredential(credentialID: Data) async throws
  func reportAllAcceptedCredentials(userHandle: Data, acceptedCredentialIDs: [Data]) async throws
  func reportUserDetailsUpdate(userHandle: Data, newName: String) async throws
}

struct LiveCredentialSignalService: CredentialSignalService {
  func reportUnknownCredential(credentialID: Data) async throws {
    try await ASCredentialDataManager().reportUnknownPublicKeyCredential(
      relyingPartyIdentifier: PasskeyConfiguration.rpID,
      credentialID: credentialID
    )
  }

  func reportAllAcceptedCredentials(userHandle: Data, acceptedCredentialIDs: [Data]) async throws {
    try await ASCredentialDataManager().reportAllAcceptedPublicKeyCredentials(
      relyingPartyIdentifier: PasskeyConfiguration.rpID,
      userHandle: userHandle,
      acceptedCredentialIDs: acceptedCredentialIDs
    )
  }

  func reportUserDetailsUpdate(userHandle: Data, newName: String) async throws {
    try await ASCredentialDataManager().reportPublicKeyCredentialUpdate(
      relyingPartyIdentifier: PasskeyConfiguration.rpID,
      userHandle: userHandle,
      newName: newName
    )
  }
}
