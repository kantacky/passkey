import { afterEach, describe, expect, test } from "bun:test";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { EmailVerificationFlow } from "../components/EmailVerificationFlow";
import { PasskeyCreation } from "../components/PasskeyCreation";

afterEach(() => cleanup());

function renderWithQuery(element: React.ReactElement) {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  });
  return render(
    <QueryClientProvider client={client}>{element}</QueryClientProvider>,
  );
}

describe("components", () => {
  test("コード入力欄は numeric と one-time-code を持つ", async () => {
    const originalFetch = globalThis.fetch;
    globalThis.fetch = (async () =>
      new Response(JSON.stringify({ flowId: "flow-id" }), {
        status: 202,
        headers: { "Content-Type": "application/json" },
      })) as unknown as typeof fetch;
    try {
      renderWithQuery(
        <EmailVerificationFlow
          purpose="signup"
          title="メールアドレスを入力"
          description="説明"
          submitLabel="確認メールを送信"
          onVerified={() => undefined}
        />,
      );

      fireEvent.change(screen.getByLabelText("メールアドレス"), {
        target: { value: "user@example.com" },
      });
      fireEvent.click(screen.getByRole("button", { name: "確認メールを送信" }));

      const codeInput = await screen.findByLabelText("6 桁コード");
      expect(codeInput.getAttribute("inputmode")).toBe("numeric");
      expect(codeInput.getAttribute("autocomplete")).toBe("one-time-code");
      expect(screen.getByRole("button", { name: "コードを再送" })).toBeTruthy();
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  test("パスキー作成前の説明と操作を表示する", () => {
    renderWithQuery(<PasskeyCreation onCreated={() => undefined} />);

    expect(
      screen.getByRole("heading", { name: "パスキーを作成" }),
    ).toBeTruthy();
    expect(
      screen.getByText(
        /顔・指紋・画面ロックを使ってサインインするためのデジタルの鍵/u,
      ),
    ).toBeTruthy();
    expect(screen.getByRole("button", { name: "パスキーを作成" })).toBeTruthy();
  });
});
