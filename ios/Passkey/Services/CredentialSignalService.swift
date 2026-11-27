import AuthenticationServices
import Foundation

enum CredentialSignalError: Error, Equatable {
  case unsupportedOS
  case invalidBase64URL
}

protocol CredentialSignalService: Sendable {
  func reportUnknownCredential(credentialID: Data) async throws
  func reportAllAcceptedCredentials(userHandle: Data, acceptedCredentialIDs: [Data]) async throws
  func reportUserDetailsUpdate(userHandle: Data, newName: String) async throws
}

struct LiveCredentialSignalService: CredentialSignalService {
  func reportUnknownCredential(credentialID: Data) async throws {
    guard #available(iOS 26.2, *) else {
      throw CredentialSignalError.unsupportedOS
    }
    try await ASCredentialDataManager().reportUnknownPublicKeyCredential(
      relyingPartyIdentifier: "passkey.kantacky.com",
      credentialID: credentialID
    )
  }

  func reportAllAcceptedCredentials(userHandle: Data, acceptedCredentialIDs: [Data]) async throws {
    guard #available(iOS 26.2, *) else {
      throw CredentialSignalError.unsupportedOS
    }
    try await ASCredentialDataManager().reportAllAcceptedPublicKeyCredentials(
      relyingPartyIdentifier: "passkey.kantacky.com",
      userHandle: userHandle,
      acceptedCredentialIDs: acceptedCredentialIDs
    )
  }

  func reportUserDetailsUpdate(userHandle: Data, newName: String) async throws {
    guard #available(iOS 26.2, *) else {
      throw CredentialSignalError.unsupportedOS
    }
    try await ASCredentialDataManager().reportPublicKeyCredentialUpdate(
      relyingPartyIdentifier: "passkey.kantacky.com",
      userHandle: userHandle,
      newName: newName
    )
  }
}
