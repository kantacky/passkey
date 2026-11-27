import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useEffect, useRef, useState } from "react";
import { ErrorMessage, Page, StatusMessage } from "../components/Feedback";
import { isApiError } from "../lib/api";
import { authenticateWithPasskey } from "../lib/passkey-actions";
import { queryClient } from "../lib/queryClient";
import {
  classifyWebAuthnError,
  isConditionalUiAvailable,
  webAuthnErrorMessage,
} from "../lib/webauthn";

export const Route = createFileRoute("/sign-in")({
  component: SignInPage,
});

function SignInPage() {
  const navigate = useNavigate();
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [conditionalAvailable, setConditionalAvailable] = useState<
    boolean | null
  >(null);
  const conditionalControllerRef = useRef<AbortController | null>(null);
  const modalActiveRef = useRef(false);
  const mountedRef = useRef(false);
  const startConditionalRef = useRef<() => void>(() => undefined);

  const startConditional = () => {
    if (!mountedRef.current || modalActiveRef.current) return;
    if (
      conditionalControllerRef.current &&
      !conditionalControllerRef.current.signal.aborted
    )
      return;

    const controller = new AbortController();
    conditionalControllerRef.current = controller;
    const timeout = window.setTimeout(() => controller.abort(), 240_000);

    authenticateWithPasskey("conditional", controller.signal)
      .then(async () => {
        if (!mountedRef.current) return;
        await queryClient.invalidateQueries({ queryKey: ["me"] });
        void navigate({ to: "/passkeys" });
      })
      .catch((cause: unknown) => {
        if (!mountedRef.current) return;
        if (controller.signal.aborted) {
          if (!modalActiveRef.current)
            window.setTimeout(() => startConditionalRef.current(), 0);
          return;
        }
        handleError(cause, setError);
      })
      .finally(() => {
        window.clearTimeout(timeout);
        if (conditionalControllerRef.current === controller)
          conditionalControllerRef.current = null;
      });
  };
  startConditionalRef.current = startConditional;

  useEffect(() => {
    mountedRef.current = true;
    let active = true;
    void isConditionalUiAvailable().then((available) => {
      if (!active || !mountedRef.current) return;
      setConditionalAvailable(available);
      if (available) startConditionalRef.current();
    });
    return () => {
      active = false;
      mountedRef.current = false;
      conditionalControllerRef.current?.abort();
    };
  }, []);

  const modalSignIn = async () => {
    let succeeded = false;
    modalActiveRef.current = true;
    conditionalControllerRef.current?.abort();
    setBusy(true);
    setError("");
    try {
      await authenticateWithPasskey();
      succeeded = true;
      await queryClient.invalidateQueries({ queryKey: ["me"] });
      void navigate({ to: "/passkeys" });
    } catch (cause) {
      handleError(cause, setError);
    } finally {
      modalActiveRef.current = false;
      setBusy(false);
      if (!succeeded) window.setTimeout(() => startConditionalRef.current(), 0);
    }
  };

  return (
    <Page
      title="サインイン"
      description="パスキーでサインインしてください。メールアドレス欄から保存済みのパスキーを選ぶこともできます。"
    >
      <form onSubmit={(event) => event.preventDefault()}>
        <label htmlFor="sign-in-email">メールアドレス</label>
        <input
          id="sign-in-email"
          type="email"
          autoComplete="username webauthn"
          inputMode="email"
        />
        <ErrorMessage>{error}</ErrorMessage>
        <StatusMessage>
          {conditionalAvailable === null
            ? "利用できるサインイン方法を確認しています…"
            : conditionalAvailable
              ? "メールアドレス欄にパスキーの候補が表示されます。"
              : "このブラウザではオートフィルに対応していないため、ボタンからサインインしてください。"}
        </StatusMessage>
        <button
          type="button"
          onClick={() => void modalSignIn()}
          disabled={busy}
        >
          {busy ? "確認中…" : "パスキーでサインイン"}
        </button>
      </form>
      <nav className="links" aria-label="その他の操作">
        <Link to="/sign-up">アカウントを作成</Link>
        <Link to="/recover">アカウントを回復</Link>
      </nav>
    </Page>
  );
}

function handleError(cause: unknown, setError: (message: string) => void) {
  if (isApiError(cause, "unknown_credential")) {
    setError(
      "このパスキーは使えません。削除されたパスキーです。別のパスキーを選ぶか、アカウントを回復してください。",
    );
  } else if (isApiError(cause, "invalid_challenge")) {
    setError("時間切れです。もう一度お試しください。");
  } else if (isApiError(cause, "rate_limited")) {
    setError(
      cause.retryAfter
        ? `試行回数が多すぎます。${cause.retryAfter} 秒後に再試行できます。`
        : "試行回数が多すぎます。時間をおいて再試行してください。",
    );
  } else if (isApiError(cause)) {
    setError(cause.message);
  } else {
    const classified = webAuthnErrorMessage(
      classifyWebAuthnError(cause),
      "get",
    );
    setError(`${classified.title}。${classified.description}`);
  }
}
