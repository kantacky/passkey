import Foundation
import Security

protocol SessionStore: Sendable {
  nonisolated func sessionToken() -> String?
  nonisolated func saveSessionToken(_ token: String) throws
  nonisolated func deleteSessionToken() throws
  nonisolated func activeFlow() -> (id: UUID, secret: String)?
  nonisolated func saveActiveFlow(id: UUID, secret: String) throws
  nonisolated func deleteActiveFlow() throws
}

enum KeychainError: Error, Equatable {
  case unexpectedStatus(OSStatus)
  case malformedData
}

final class KeychainSessionStore: SessionStore {
  private let service = "com.kantacky.Passkey"
  private let sessionAccount = "session-token"
  private let flowIDAccount = "active-flow-id"
  private let flowSecretAccount = "active-flow-secret"

  nonisolated func sessionToken() -> String? {
    string(for: sessionAccount)
  }

  nonisolated func saveSessionToken(_ token: String) throws {
    try save(token, for: sessionAccount)
  }

  nonisolated func deleteSessionToken() throws {
    try delete(for: sessionAccount)
  }

  nonisolated func activeFlow() -> (id: UUID, secret: String)? {
    guard let idString = string(for: flowIDAccount),
          let id = UUID(uuidString: idString),
          let secret = string(for: flowSecretAccount) else {
      return nil
    }
    return (id, secret)
  }

  nonisolated func saveActiveFlow(id: UUID, secret: String) throws {
    try save(id.uuidString, for: flowIDAccount)
    try save(secret, for: flowSecretAccount)
  }

  nonisolated func deleteActiveFlow() throws {
    try delete(for: flowIDAccount)
    try delete(for: flowSecretAccount)
  }

  private nonisolated func string(for account: String) -> String? {
    var query = baseQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data,
          let value = String(data: data, encoding: .utf8) else {
      return nil
    }
    return value
  }

  private nonisolated func save(_ value: String, for account: String) throws {
    let data = Data(value.utf8)
    var query = baseQuery(account: account)
    SecItemDelete(query as CFDictionary)
    query[kSecValueData as String] = data
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw KeychainError.unexpectedStatus(status)
    }
  }

  private nonisolated func delete(for account: String) throws {
    let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError.unexpectedStatus(status)
    }
  }

  private nonisolated func baseQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]
  }
}
