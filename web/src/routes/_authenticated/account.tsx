import { useQuery } from "@tanstack/react-query";
import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import { EmailVerificationFlow } from "../../components/EmailVerificationFlow";
import { ErrorMessage, Page, StatusMessage } from "../../components/Feedback";
import {
  ReauthenticationPrompt,
  useReauthenticatedAction,
} from "../../components/Reauthentication";
import { api, isApiError } from "../../lib/api";
import { reauthenticate } from "../../lib/passkey-actions";
import { queryClient } from "../../lib/queryClient";
import {
  signalAllAcceptedCredentials,
  signalCurrentUserDetails,
} from "../../lib/signal";
import {
  classifyWebAuthnError,
  webAuthnErrorMessage,
} from "../../lib/webauthn";
import { meQueryOptions } from "../../queries/me";

export const Route = createFileRoute("/_authenticated/account")({
  component: AccountPage,
});

function AccountPage() {
  const me = useQuery(meQueryOptions);

  return (
    <Page
      title="アカウント"
      description="メールアドレスの変更とアカウント削除を行えます。"
    >
      {me.data ? (
        <EmailChangeSection
          userHandle={me.data.userHandle}
          currentEmail={me.data.email}
        />
      ) : null}
      {me.data ? (
        <DeleteAccountSection
          userHandle={me.data.userHandle}
          email={me.data.email}
        />
      ) : null}
      {me.isPending ? <p>読み込んでいます…</p> : null}
      {me.isError ? (
        <ErrorMessage>アカウント情報を読み込めませんでした。</ErrorMessage>
      ) : null}
    </Page>
  );
}

function EmailChangeSection({
  userHandle,
  currentEmail,
}: {
  userHandle: string;
  currentEmail: string;
}) {
  const [ready, setReady] = useState(false);
  const [complete, setComplete] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  const begin = async () => {
    setBusy(true);
    setError("");
    try {
      await reauthenticate();
      setReady(true);
    } catch (cause) {
      if (isApiError(cause)) setError(cause.message);
      else {
        const classified = webAuthnErrorMessage(
          classifyWebAuthnError(cause),
          "get",
        );
        setError(`${classified.title}。${classified.description}`);
      }
    } finally {
      setBusy(false);
    }
  };

  return (
    <section aria-labelledby="email-change-heading">
      <h2 id="email-change-heading">メールアドレス変更</h2>
      <p>現在のメールアドレス: {currentEmail}</p>
      <p>
        新しいメールアドレスの所有確認が完了すると変更されます。新旧両方のメールアドレスに通知が送信されます。
      </p>
      <ErrorMessage>{error}</ErrorMessage>
      <StatusMessage>{complete}</StatusMessage>
      {!ready && !complete ? (
        <button type="button" onClick={() => void begin()} disabled={busy}>
          {busy ? "再認証しています…" : "再認証して変更を始める"}
        </button>
      ) : null}
      {ready && !complete ? (
        <EmailVerificationFlow
          purpose="email_change"
          title="新しいメールアドレスを入力"
          description="新しいメールアドレスに確認コードを送信します。"
          submitLabel="確認メールを送信"
          onVerified={async (_flowId, email) => {
            const signalled = await signalCurrentUserDetails(userHandle, email);
            await queryClient.invalidateQueries({ queryKey: ["me"] });
            setReady(false);
            setComplete(
              signalled
                ? "メールアドレスを変更しました。パスワード管理に表示される情報も更新しました。"
                : "メールアドレスを変更しました。パスワード管理に表示されるメールアドレスは古いままの場合があります。サインインには影響しません。",
            );
          }}
        />
      ) : null}
    </section>
  );
}

function DeleteAccountSection({
  userHandle,
  email,
}: {
  userHandle: string;
  email: string;
}) {
  const navigate = useNavigate();
  const [confirmation, setConfirmation] = useState("");
  const [formError, setFormError] = useState("");
  const action = useReauthenticatedAction<string, void>(
    async (value) => {
      await api<void>("/me", { method: "DELETE", body: { email: value } });
    },
    async () => {
      await signalAllAcceptedCredentials(userHandle, []);
      queryClient.clear();
      void navigate({ to: "/sign-in" });
    },
  );

  const submit = (event: React.FormEvent) => {
    event.preventDefault();
    if (confirmation.trim().toLowerCase() !== email.toLowerCase()) {
      setFormError(
        "確認のため、現在のメールアドレスを正確に入力してください。",
      );
      return;
    }
    setFormError("");
    action.perform(confirmation.trim());
  };

  return (
    <section aria-labelledby="delete-account-heading">
      <h2 id="delete-account-heading">アカウント削除</h2>
      <p>
        アカウント、パスキー、セッション、確認用のデータをすべて削除します。この操作は取り消せません。
      </p>
      <form onSubmit={submit}>
        <label htmlFor="delete-email">確認のためメールアドレスを再入力</label>
        <input
          id="delete-email"
          type="email"
          autoComplete="email"
          value={confirmation}
          onChange={(event) => setConfirmation(event.currentTarget.value)}
          required
        />
        <ErrorMessage>{formError || action.error}</ErrorMessage>
        <button type="submit" className="danger" disabled={action.busy}>
          アカウントを削除
        </button>
      </form>
      <ReauthenticationPrompt
        visible={action.needsReauthentication}
        busy={action.busy}
        error={action.error}
        onReauthenticate={() => void action.reauthenticateAndRetry()}
      />
    </section>
  );
}
