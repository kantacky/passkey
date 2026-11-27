import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useCallback, useState } from "react";
import { EmailVerificationFlow } from "../components/EmailVerificationFlow";
import { Page } from "../components/Feedback";
import {
  PasskeyCreation,
  type RegistrationCompletion,
  registrationCompletion,
} from "../components/PasskeyCreation";
import { queryClient } from "../lib/queryClient";

export const Route = createFileRoute("/sign-up")({
  component: SignUpPage,
});

function SignUpPage() {
  const navigate = useNavigate();
  const [verified, setVerified] = useState(false);
  const [created, setCreated] = useState<RegistrationCompletion | null>(null);
  const finish = useCallback(() => setVerified(true), []);
  const complete = useCallback((result?: unknown) => {
    void queryClient.invalidateQueries();
    setCreated(registrationCompletion(result));
  }, []);

  return (
    <Page
      title="アカウントを作成"
      description="メールアドレスを確認し、パスキーを作成します。"
    >
      {created ? (
        <section aria-labelledby="signup-created-heading">
          <h2 id="signup-created-heading">パスキーを作成しました</h2>
          <p>
            次回からこのパスキーでサインインできます。
            {created.providerName
              ? `パスキーは ${created.providerName} に保存されています。`
              : "パスキーは、作成時に選んだパスワード管理に保存されています。"}
          </p>
          {created.backupEligible === false ? (
            <p>
              このパスキーはこの端末（またはセキュリティキー）でのみ使えます。
            </p>
          ) : null}
          <button
            type="button"
            onClick={() => void navigate({ to: "/passkeys" })}
          >
            パスキー一覧へ進む
          </button>
        </section>
      ) : verified ? (
        <PasskeyCreation onCreated={complete} />
      ) : (
        <EmailVerificationFlow
          purpose="signup"
          title="メールアドレスを入力"
          description="6 桁コードまたはメール内のリンクで、このメールアドレスを確認します。"
          submitLabel="確認メールを送信"
          onVerified={finish}
        />
      )}
    </Page>
  );
}
