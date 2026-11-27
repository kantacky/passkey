import SwiftUI

struct VerificationCodeSection: View {
  @Binding var code: String
  @FocusState private var codeFieldIsFocused: Bool
  let isWorking: Bool
  let errorMessage: String?
  let expiresAt: Date?
  let verifyButtonTapped: () async -> Void
  let resendButtonTapped: () async -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("メールを確認")
        .font(.title2.bold())
      Text("メールに記載された 6 桁コードを入力してください。コードの有効期限は 10 分です。同じ端末でリンクを開いた場合は自動で次へ進みます。")
        .foregroundStyle(.secondary)
      if let expiresAt {
        HStack {
          Text("残り時間")
          Text(expiresAt, style: .timer)
            .monospacedDigit()
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
      }
      TextField("6 桁コード", text: $code)
        .keyboardType(.numberPad)
        .textContentType(.oneTimeCode)
        .textFieldStyle(.roundedBorder)
        .font(.title3.monospacedDigit())
        .accessibilityLabel("6 桁コード")
        .focused($codeFieldIsFocused)
      Button {
        Task { await verifyButtonTapped() }
      } label: {
        HStack {
          if isWorking { ProgressView() }
          Text("確認する")
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .disabled(isWorking || code.count != 6)
      if let errorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
          .accessibilityAddTraits(.updatesFrequently)
      }
      Button("コードを再送") {
        Task { await resendButtonTapped() }
      }
      .onChange(of: errorMessage != nil) { _, hasError in
        if hasError { codeFieldIsFocused = true }
      }
    }
  }
}
