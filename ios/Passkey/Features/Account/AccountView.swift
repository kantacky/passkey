import AuthenticationServices
import SwiftUI

@MainActor
@Observable
final class AccountViewModel {
  enum EmailChangeStep {
    case inactive
    case verifying
    case completed
  }

  @ObservationIgnored let api: any APIClient
  @ObservationIgnored let passkeyService: any PasskeyService
  @ObservationIgnored let signalService: any CredentialSignalService
  @ObservationIgnored let sessionStore: any SessionStore

  var currentEmail: String
  var userHandle: String
  var newEmail = ""
  var verificationCode = ""
  var emailChangeStep = EmailChangeStep.inactive
  var confirmationEmail = ""
  var isWorking = false
  var errorMessage: String?
  var noticeMessage: String?
  var showsDeleteConfirmation = false
  @ObservationIgnored private var flowID: UUID?
  @ObservationIgnored private var flowSecret: String?

  init(
    api: any APIClient,
    passkeyService: any PasskeyService,
    signalService: any CredentialSignalService,
    sessionStore: any SessionStore,
    currentEmail: String,
    userHandle: String
  ) {
    self.api = api
    self.passkeyService = passkeyService
    self.signalService = signalService
    self.sessionStore = sessionStore
    self.currentEmail = currentEmail
    self.userHandle = userHandle
  }

  func startEmailChangeButtonTapped() async {
    await performSensitiveWork {
      let response = try await api.startEmailVerification(email: newEmail, purpose: .emailChange)
      flowID = response.id
      flowSecret = response.secret
      try sessionStore.saveActiveFlow(id: response.id, secret: response.secret)
      verificationCode = ""
      emailChangeStep = .verifying
    }
  }

  func verifyEmailChangeButtonTapped() async {
    guard let flowID, let flowSecret else { return }
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      let response = try await api.verifyEmail(id: flowID, secret: flowSecret, request: .code(verificationCode), includeSession: true)
      guard let session = response.session else { throw APIError.missingSessionToken }
      try sessionStore.saveSessionToken(session.token)
      try? sessionStore.deleteActiveFlow()
      let verifiedEmail = response.email ?? newEmail
      if let handle = Data(base64URLEncoded: userHandle) {
        try? await signalService.reportUserDetailsUpdate(userHandle: handle, newName: verifiedEmail)
      }
      currentEmail = verifiedEmail
      newEmail = ""
      verificationCode = ""
      emailChangeStep = .completed
      noticeMessage = "メールアドレスを変更しました。パスワード管理に表示されるメールアドレスは古いままの場合があります。サインインには影響しません。"
    } catch let error as APIError {
      switch error.errorCode {
      case "invalid_code":
        errorMessage = "コードが正しくありません"
      case "email_taken":
        errorMessage = "このメールアドレスは既に使われています"
      case "flow_expired":
        errorMessage = "時間切れです。最初からやり直してください。"
      default:
        errorMessage = error.errorDescription
      }
    } catch {
      errorMessage = "コードを確認できませんでした。もう一度お試しください。"
    }
  }

  func deleteAccountButtonTapped() {
    showsDeleteConfirmation = true
  }

  func confirmDeleteAccountButtonTapped() async -> Bool {
    var succeeded = false
    await performSensitiveWork {
      try await api.deleteAccount(email: confirmationEmail)
      if let handle = Data(base64URLEncoded: userHandle) {
        try? await signalService.reportAllAcceptedCredentials(userHandle: handle, acceptedCredentialIDs: [])
      }
      try? sessionStore.deleteActiveFlow()
      succeeded = true
    }
    return succeeded
  }

  private func performSensitiveWork(_ operation: () async throws -> Void) async {
    isWorking = true
    errorMessage = nil
    noticeMessage = nil
    defer { isWorking = false }
    do {
      try await withReauthentication(api: api, passkeyService: passkeyService, sessionStore: sessionStore, operation: operation)
    } catch {
      if isCancellation(error) { return }
      if let apiError = error as? APIError {
        switch apiError.errorCode {
        case "recently_recovered":
          errorMessage = "アカウント回復から 24 時間はこの操作を実行できません"
        case "invalid_request":
          errorMessage = "入力内容を確認してください"
        default:
          errorMessage = apiError.errorDescription
        }
      } else {
        errorMessage = "操作を完了できませんでした。もう一度お試しください。"
      }
    }
  }

  private func isCancellation(_ error: any Error) -> Bool {
    if case PasskeyServiceError.cancelled = error { return true }
    if let authorizationError = error as? ASAuthorizationError {
      return authorizationError.code == .canceled
    }
    return false
  }
}

struct AccountView: View {
  @State var model: AccountViewModel
  let currentEmail: String
  let onSignOut: () async -> Void
  let onAccountDeleted: () async -> Void

  init(model: AccountViewModel, currentEmail: String, onSignOut: @escaping () async -> Void, onAccountDeleted: @escaping () async -> Void) {
    _model = State(initialValue: model)
    self.currentEmail = currentEmail
    self.onSignOut = onSignOut
    self.onAccountDeleted = onAccountDeleted
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          LabeledContent("現在のメールアドレス", value: model.currentEmail)
          if model.emailChangeStep == .inactive || model.emailChangeStep == .completed {
            TextField("新しいメールアドレス", text: Bindable(model).newEmail)
              .keyboardType(.emailAddress)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .textContentType(.emailAddress)
            Button("確認メールを送信") {
              Task { await model.startEmailChangeButtonTapped() }
            }
            .disabled(model.isWorking || model.newEmail.isEmpty)
          } else {
            TextField("6 桁コード", text: Bindable(model).verificationCode)
              .keyboardType(.numberPad)
              .textContentType(.oneTimeCode)
            Button("メールアドレスを変更") {
              Task { await model.verifyEmailChangeButtonTapped() }
            }
            .disabled(model.isWorking || model.verificationCode.count != 6)
          }
        } header: {
          Text("メールアドレス")
        } footer: {
          if model.emailChangeStep == .verifying {
            Text("新しいメールアドレスに届いた 6 桁コードを入力してください。コードの有効期限は 10 分です。")
          }
        }

        Section {
          Button("サインアウト") {
            Task { await onSignOut() }
          }
        }

        Section {
          Button("アカウントを削除", role: .destructive, action: model.deleteAccountButtonTapped)
        } header: {
          Text("アカウント削除")
        } footer: {
          Text("すべてのパスキー、セッション、アカウントデータが削除されます。この操作は取り消せません。")
        }

        if let noticeMessage = model.noticeMessage {
          Section {
            Text(noticeMessage)
              .foregroundStyle(.secondary)
          }
        }
        if let errorMessage = model.errorMessage {
          Section {
            Text(errorMessage)
              .foregroundStyle(.red)
              .accessibilityAddTraits(.updatesFrequently)
          }
        }
      }
      .navigationTitle("アカウント")
      .onChange(of: currentEmail) { _, newValue in
        model.currentEmail = newValue
      }
      .alert("アカウントを削除しますか？", isPresented: Bindable(model).showsDeleteConfirmation) {
        TextField("メールアドレスを再入力", text: Bindable(model).confirmationEmail)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Button("キャンセル", role: .cancel) {
          model.confirmationEmail = ""
        }
        Button("アカウントを削除", role: .destructive) {
          Task {
            if await model.confirmDeleteAccountButtonTapped() {
              await onAccountDeleted()
            }
          }
        }
        .disabled(model.confirmationEmail.caseInsensitiveCompare(model.currentEmail) != .orderedSame)
      } message: {
        Text("確認のため、現在のメールアドレスを再入力してください。")
      }
    }
  }
}
