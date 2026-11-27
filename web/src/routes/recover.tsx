import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useCallback } from "react";
import { EmailVerificationFlow } from "../components/EmailVerificationFlow";
import { Page } from "../components/Feedback";
import { queryClient } from "../lib/queryClient";

export const Route = createFileRoute("/recover")({
  component: RecoverPage,
});

function RecoverPage() {
  const navigate = useNavigate();
  const verified = useCallback(() => {
    void queryClient.invalidateQueries({ queryKey: ["me"] });
    void navigate({ to: "/create-passkey" });
  }, [navigate]);

  return (
    <Page
      title="アカウントを回復"
      description="メールアドレスを確認し、新しいパスキーを作成します。"
    >
      <EmailVerificationFlow
        purpose="recovery"
        title="登録したメールアドレスを入力"
        description="アカウント回復用の 6 桁コードまたはリンクを送信します。回復後は新しいパスキーの作成が必要です。"
        submitLabel="回復メールを送信"
        onVerified={verified}
      />
    </Page>
  );
}
