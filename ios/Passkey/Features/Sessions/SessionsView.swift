import AuthenticationServices
import SwiftUI

@MainActor
@Observable
final class SessionsViewModel {
  @ObservationIgnored let api: any APIClient
  @ObservationIgnored let passkeyService: any PasskeyService
  @ObservationIgnored let sessionStore: any SessionStore

  var sessions: [UserSession] = []
  var isLoading = false
  var isWorking = false
  var errorMessage: String?
  var noticeMessage: String?

  init(api: any APIClient, passkeyService: any PasskeyService, sessionStore: any SessionStore) {
    self.api = api
    self.passkeyService = passkeyService
    self.sessionStore = sessionStore
  }

  func task() async {
    isLoading = true
    defer { isLoading = false }
    do {
      sessions = try await api.sessions()
    } catch {
      errorMessage = "セッション一覧を読み込めませんでした"
    }
  }

  func revokeButtonTapped(_ session: UserSession) async {
    await performSensitiveWork {
      try await api.revokeSession(id: session.id)
      sessions = try await api.sessions()
      noticeMessage = "セッションを失効しました"
    }
  }

  func revokeOthersButtonTapped() async {
    await performSensitiveWork {
      try await api.revokeOtherSessions()
      sessions = try await api.sessions()
      noticeMessage = "他のセッションをすべてサインアウトしました"
    }
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
      errorMessage = "操作を完了できませんでした。もう一度お試しください。"
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

struct SessionsView: View {
  @State var model: SessionsViewModel

  init(model: SessionsViewModel) {
    _model = State(initialValue: model)
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          if model.isLoading {
            ProgressView()
          } else {
            ForEach(model.sessions) { session in
              VStack(alignment: .leading, spacing: 6) {
                HStack {
                  Text(session.deviceLabel)
                    .font(.headline)
                  if session.current {
                    Text("この端末")
                      .font(.caption.bold())
                      .padding(.horizontal, 6)
                      .padding(.vertical, 2)
                      .background(.green.opacity(0.2), in: Capsule())
                  }
                }
                LabeledContent("作成日時", value: session.createdAt, format: .dateTime)
                LabeledContent("最終アクセス", value: session.lastSeenAt, format: .dateTime)
                if !session.current {
                  Button("このセッションを失効", role: .destructive) {
                    Task { await model.revokeButtonTapped(session) }
                  }
                  .disabled(model.isWorking)
                }
              }
              .padding(.vertical, 4)
            }
          }
        } header: {
          Text("セッション")
        }

        Section {
          Button("他のセッションをすべてサインアウト") {
            Task { await model.revokeOthersButtonTapped() }
          }
          .disabled(model.isWorking)
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
      .navigationTitle("セッション")
      .task { await model.task() }
      .refreshable { await model.task() }
    }
  }
}
