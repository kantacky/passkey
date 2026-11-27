import { useMutation } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { isApiError } from "../lib/api";
import { registerPasskey } from "../lib/passkey-actions";
import {
  classifyWebAuthnError,
  isPlatformAuthenticatorAvailable,
  webAuthnErrorMessage,
} from "../lib/webauthn";
import { ErrorMessage, StatusMessage } from "./Feedback";

export function PasskeyCreation({
  onCreated,
  recovery = false,
}: {
  onCreated: (result?: unknown) => void;
  recovery?: boolean;
}) {
  const [platformAvailable, setPlatformAvailable] = useState<boolean | null>(
    null,
  );
  const [error, setError] = useState<{
    title: string;
    description: string;
  } | null>(null);
  const mutation = useMutation({
    mutationFn: registerPasskey,
    onSuccess: (result) => {
      setError(null);
      onCreated(result);
    },
    onError: (cause) => {
      if (isApiError(cause, "invalid_challenge")) {
        setError({
          title: "時間切れです",
          description: "もう一度お試しください。新しい確認情報でやり直します。",
        });
      } else if (isApiError(cause, "credential_exists")) {
        const message = webAuthnErrorMessage("already_registered", "create");
        setError(message);
      } else if (isApiError(cause, "email_taken")) {
        setError({
          title: "このメールアドレスは登録済みです",
          description: "サインインするか、アカウントを回復してください。",
        });
      } else if (isApiError(cause)) {
        setError({
          title: "パスキーを作成できませんでした",
          description: cause.message,
        });
      } else {
        setError(webAuthnErrorMessage(classifyWebAuthnError(cause), "create"));
      }
    },
  });

  useEffect(() => {
    void isPlatformAuthenticatorAvailable().then(setPlatformAvailable);
  }, []);

  return (
    <section aria-labelledby="create-passkey-heading">
      <h2 id="create-passkey-heading">パスキーを作成</h2>
      <p>
        パスキーは、顔・指紋・画面ロックを使ってサインインするためのデジタルの鍵です。iCloud
        キーチェーンや Google
        パスワードマネージャーなどのパスワード管理に保存され、同じアカウントの他の端末でも使えます。
      </p>
      {platformAvailable === false ? (
        <p>
          この端末には画面ロック付きの認証機能が見つかりませんでした。スマートフォンの
          QR コードまたはセキュリティキーを使って作成できます。
        </p>
      ) : null}
      {recovery ? (
        <p>アカウント回復を完了するには、新しいパスキーの作成が必要です。</p>
      ) : null}
      {error ? (
        <ErrorMessage>
          <strong>{error.title}</strong>
          <br />
          {error.description}
        </ErrorMessage>
      ) : null}
      <StatusMessage>
        {mutation.isPending
          ? "端末の案内に従ってパスキーを作成してください。"
          : ""}
      </StatusMessage>
      <button
        type="button"
        onClick={() => mutation.mutate()}
        disabled={mutation.isPending}
      >
        パスキーを作成
      </button>
    </section>
  );
}

export type RegistrationCompletion = {
  providerName: string | null;
  backupEligible: boolean | null;
};

export function registrationCompletion(
  result: unknown,
): RegistrationCompletion {
  if (!result || typeof result !== "object")
    return { providerName: null, backupEligible: null };
  const container = result as Record<string, unknown>;
  const passkey =
    container.passkey && typeof container.passkey === "object"
      ? (container.passkey as Record<string, unknown>)
      : container;
  return {
    providerName:
      typeof passkey.providerName === "string" ? passkey.providerName : null,
    backupEligible:
      typeof passkey.backupEligible === "boolean"
        ? passkey.backupEligible
        : null,
  };
}
