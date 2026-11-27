import AuthenticationServices
import SwiftUI

@MainActor
@Observable
final class PasskeysViewModel {
  @ObservationIgnored let api: any APIClient
  @ObservationIgnored let passkeyService: any PasskeyService
  @ObservationIgnored let signalService: any CredentialSignalService
  @ObservationIgnored let sessionStore: any SessionStore

  var passkeys: [PasskeyCredential] = []
  var isLoading = false
  var isWorking = false
  var errorMessage: String?
  var deletionCandidate: PasskeyCredential?
  var renameCandidate: PasskeyCredential?
  var renameText = ""
  var showRevokeOthersPrompt = false
  var showsAddPasskeyExplanation = false
  var noticeMessage: String?

  init(
    api: any APIClient,
    passkeyService: any PasskeyService,
    signalService: any CredentialSignalService,
    sessionStore: any SessionStore
  ) {
    self.api = api
    self.passkeyService = passkeyService
    self.signalService = signalService
    self.sessionStore = sessionStore
  }

  func task() async {
    isLoading = true
    defer { isLoading = false }
    do {
      passkeys = try await api.passkeys()
    } catch {
      errorMessage = "パスキー一覧を読み込めませんでした"
    }
  }

  func addPasskeyButtonTapped() async {
    await performSensitiveWork {
      let options = try await api.registrationOptions(flowSecret: nil)
      let registration = try await passkeyService.createPasskey(options: options)
      let response = try await api.register(registration, flowSecret: nil)
      passkeys = try await api.passkeys()
      if response.passkey?.backupEligible == false {
        noticeMessage = "パスキーを作成しました。次回からこのパスキーでサインインできます。このパスキーはこの端末（またはセキュリティキー）でのみ使えます。"
      } else {
        noticeMessage = "パスキーを作成しました。次回からこのパスキーでサインインできます。"
      }
      showsAddPasskeyExplanation = false
      showRevokeOthersPrompt = true
    }
  }

  func deleteButtonTapped(_ passkey: PasskeyCredential) {
    deletionCandidate = passkey
  }

  func cancelDeleteButtonTapped() {
    deletionCandidate = nil
  }

  func confirmDeleteButtonTapped() async {
    guard let passkey = deletionCandidate else { return }
    await performSensitiveWork {
      let response = try await api.deletePasskey(id: passkey.id)
      passkeys = try await api.passkeys()
      if let user = try? await api.me(),
         let userHandle = Data(base64URLEncoded: user.userHandle) {
        let ids = response.allAcceptedCredentialIds.compactMap(Data.init(base64URLEncoded:))
        try? await signalService.reportAllAcceptedCredentials(userHandle: userHandle, acceptedCredentialIDs: ids)
      }
      deletionCandidate = nil
      noticeMessage = "パスキーを削除しました。このパスキーは今後どの端末でも使えません。端末のパスワード管理からもこのパスキーを削除できます。"
      showRevokeOthersPrompt = true
    }
  }

  func renameButtonTapped(_ passkey: PasskeyCredential) {
    renameCandidate = passkey
    renameText = passkey.customName ?? ""
  }

  func saveRenameButtonTapped() async {
    guard let passkey = renameCandidate else { return }
    isWorking = true
    defer { isWorking = false }
    do {
      let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
      _ = try await api.renamePasskey(id: passkey.id, name: trimmed.isEmpty ? nil : trimmed)
      passkeys = try await api.passkeys()
      renameCandidate = nil
    } catch {
      errorMessage = "名前を変更できませんでした"
    }
  }

  func revokeOtherSessionsButtonTapped() async {
    await performSensitiveWork {
      try await api.revokeOtherSessions()
      showRevokeOthersPrompt = false
      noticeMessage = "他のセッションをすべてサインアウトしました。"
    }
  }

  private func performSensitiveWork(_ operation: () async throws -> Void) async {
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      try await withReauthentication(api: api, passkeyService: passkeyService, sessionStore: sessionStore, operation: operation)
    } catch {
      if isCancellation(error) { return }
      if let apiError = error as? APIError {
        switch apiError.errorCode {
        case "last_passkey":
          errorMessage = "別のパスキーを追加してから削除してください"
        case "recently_recovered":
          errorMessage = "アカウント回復から 24 時間はこの操作を実行できません"
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

struct PasskeysView: View {
  @State var model: PasskeysViewModel

  init(model: PasskeysViewModel) {
    _model = State(initialValue: model)
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text("パスキーは、顔・指紋・画面ロックを使ってサインインするためのデジタルの鍵です。パスワード管理に保存され、同じアカウントの他の端末でも使えます。")
            .foregroundStyle(.secondary)
          Button {
            model.showsAddPasskeyExplanation = true
          } label: {
            Label("パスキーを追加", systemImage: "plus")
          }
          .disabled(model.isWorking)
        } header: {
          Text("パスキー")
        }

        Section {
          if model.isLoading {
            ProgressView()
          } else {
            ForEach(model.passkeys) { passkey in
              PasskeyCard(passkey: passkey, isOnlyPasskey: model.passkeys.count == 1) {
                model.renameButtonTapped(passkey)
              } deleteTapped: {
                model.deleteButtonTapped(passkey)
              }
            }
          }
        }

        if let noticeMessage = model.noticeMessage {
          Section {
            Text(noticeMessage)
              .foregroundStyle(.secondary)
          }
        }
        if model.showRevokeOthersPrompt {
          Section {
            Button("他のセッションをすべてサインアウト") {
              Task { await model.revokeOtherSessionsButtonTapped() }
            }
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
      .navigationTitle("パスキー")
      .task { await model.task() }
      .refreshable { await model.task() }
      .alert("このパスキーを削除しますか？", isPresented: deletionCandidateIsPresented) {
        Button("キャンセル", role: .cancel, action: model.cancelDeleteButtonTapped)
        Button("パスキーを削除", role: .destructive) {
          Task { await model.confirmDeleteButtonTapped() }
        }
      } message: {
        Text("削除すると、このパスキーではサインインできなくなります。")
      }
      .sheet(isPresented: Bindable(model).showsAddPasskeyExplanation) {
        NavigationStack {
          VStack(alignment: .leading, spacing: 16) {
            Text("パスキーを作成")
              .font(.largeTitle.bold())
            Text("パスキーは、顔・指紋・画面ロックを使ってサインインするためのデジタルの鍵です。iCloud キーチェーンや Google パスワードマネージャーなどのパスワード管理に保存され、同じアカウントの他の端末でも使えます。")
              .foregroundStyle(.secondary)
            Button {
              Task { await model.addPasskeyButtonTapped() }
            } label: {
              HStack {
                if model.isWorking { ProgressView() }
                Text("パスキーを作成")
              }
              .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isWorking)
            Spacer()
          }
          .padding()
          .navigationTitle("パスキーを追加")
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("キャンセル") { model.showsAddPasskeyExplanation = false }
            }
          }
        }
        .presentationDetents([.medium, .large])
      }
      .sheet(item: renameCandidateBinding) { passkey in
        NavigationStack {
          Form {
            TextField("パスキー名", text: Bindable(model).renameText)
              .textInputAutocapitalization(.never)
          }
          .navigationTitle("名前を変更")
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("キャンセル") { model.renameCandidate = nil }
            }
            ToolbarItem(placement: .confirmationAction) {
              Button("保存") {
                Task { await model.saveRenameButtonTapped() }
              }
              .disabled(model.isWorking || model.renameText.count > 64)
            }
          }
        }
        .presentationDetents([.medium])
      }
    }
  }

  private var deletionCandidateIsPresented: Binding<Bool> {
    Binding(
      get: { model.deletionCandidate != nil },
      set: { isPresented in
        if !isPresented { model.deletionCandidate = nil }
      }
    )
  }

  private var renameCandidateBinding: Binding<PasskeyCredential?> {
    Binding(
      get: { model.renameCandidate },
      set: { model.renameCandidate = $0 }
    )
  }
}

struct PasskeyCard: View {
  let passkey: PasskeyCredential
  let isOnlyPasskey: Bool
  let renameTapped: () -> Void
  let deleteTapped: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        PasskeyIcon(passkey: passkey)
        VStack(alignment: .leading) {
          Text(passkey.name ?? defaultName)
            .font(.headline)
          Text(passkey.providerName ?? "パスキー")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      LabeledContent("作成日時", value: passkey.createdAt, format: .dateTime)
      if let lastUsedAt = passkey.lastUsedAt {
        LabeledContent("最終使用", value: lastUsedAt, format: .dateTime)
      } else {
        LabeledContent("最終使用", value: "未使用")
      }
      LabeledContent("同期", value: passkey.backupState || passkey.backupEligible ? "同期できます" : "この端末またはセキュリティキーのみ")
      HStack {
        Button("名前を変更", action: renameTapped)
        Spacer()
        Button("削除", role: .destructive, action: deleteTapped)
          .disabled(isOnlyPasskey)
      }
      if isOnlyPasskey {
        Text("別のパスキーを追加してから削除してください")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
  }

  private var defaultName: String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    return "パスキー（\(formatter.string(from: passkey.createdAt))）"
  }
}


struct PasskeyIcon: View {
  let passkey: PasskeyCredential
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    if let url = iconURL {
      AsyncImage(url: url) { image in
        image.resizable().scaledToFit()
      } placeholder: {
        Image(systemName: "key.fill")
      }
      .frame(width: 32, height: 32)
      .accessibilityHidden(true)
    } else {
      Image(systemName: "key.fill")
        .font(.title2)
        .accessibilityHidden(true)
    }
  }

  private var iconURL: URL? {
    let value = colorScheme == .dark ? passkey.iconDark ?? passkey.iconLight : passkey.iconLight ?? passkey.iconDark
    return value.flatMap(URL.init(string:))
  }
}
