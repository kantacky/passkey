import { useMutation } from "@tanstack/react-query";
import { useEffect, useRef, useState } from "react";
import {
  api,
  type EmailVerification,
  isApiError,
  type VerificationPurpose,
} from "../lib/api";
import { ErrorMessage, StatusMessage } from "./Feedback";

type StartResponse = {
  id?: string;
  flowId?: string;
  flow?: { id?: string };
  expiresAt?: string;
};

type VerifyResponse = {
  status?: string;
};

export function EmailVerificationFlow({
  purpose,
  onVerified,
  title,
  description,
  submitLabel,
}: {
  purpose: VerificationPurpose;
  onVerified: (flowId: string, email: string) => void;
  title: string;
  description: string;
  submitLabel: string;
}) {
  const [email, setEmail] = useState("");
  const [code, setCode] = useState("");
  const [flowId, setFlowId] = useState<string | null>(null);
  const [expiresAt, setExpiresAt] = useState<string | null>(null);
  const [error, setError] = useState("");
  const [status, setStatus] = useState("");
  const [remainingSeconds, setRemainingSeconds] = useState<number | null>(null);
  const notifiedRef = useRef(false);
  const codeInputRef = useRef<HTMLInputElement>(null);

  const startMutation = useMutation({
    mutationFn: async (value: string) => {
      const response = await api<StartResponse>("/email-verifications", {
        method: "POST",
        body: { email: value, purpose },
      });
      return response;
    },
    onSuccess: (response) => {
      const id = response.flowId ?? response.id ?? response.flow?.id;
      setError("");
      setCode("");
      notifiedRef.current = false;
      if (id) {
        setFlowId(id);
        setExpiresAt(response.expiresAt ?? null);
        setStatus(
          "メールを送信しました。メールに記載された 6 桁コードを入力してください。",
        );
        window.setTimeout(() => codeInputRef.current?.focus(), 0);
      } else {
        setError("確認フローを開始できませんでした。もう一度お試しください。");
      }
    },
    onError: (cause) => {
      setError(
        isApiError(cause, "rate_limited") && cause.retryAfter
          ? `送信回数が多すぎます。${cause.retryAfter} 秒後に再試行できます。`
          : "メールを送信できませんでした。もう一度お試しください。",
      );
    },
  });

  const verifyMutation = useMutation({
    mutationFn: async ({ id, value }: { id: string; value: string }) =>
      api<VerifyResponse>(
        `/email-verifications/${encodeURIComponent(id)}/verify`,
        {
          method: "POST",
          body: { code: value },
        },
      ),
    onSuccess: () => {
      if (flowId && !notifiedRef.current) {
        notifiedRef.current = true;
        onVerified(flowId, email.trim());
      }
    },
    onError: (cause) => {
      if (isApiError(cause, "invalid_code")) {
        setError(
          "コードが正しくありません。メールに記載された 6 桁コードを確認してください。",
        );
      } else if (isApiError(cause, "device_mismatch")) {
        setError(
          "このリンクまたはコードは、登録を始めた画面で使う必要があります。メールに記載の 6 桁コードを、登録を始めた画面で入力してください。",
        );
      } else if (isApiError(cause, "flow_expired")) {
        setError("時間切れです。コードを再送して最初からやり直してください。");
      } else {
        setError("コードを確認できませんでした。もう一度お試しください。");
      }
      codeInputRef.current?.focus();
    },
  });

  useEffect(() => {
    if (!flowId || notifiedRef.current) return;
    let cancelled = false;
    const poll = async () => {
      try {
        const flow = await api<EmailVerification>(
          `/email-verifications/${encodeURIComponent(flowId)}`,
        );
        if (cancelled || notifiedRef.current) return;
        if (flow.status === "verified" || flow.status === "consumed") {
          notifiedRef.current = true;
          onVerified(flowId, email.trim());
        } else if (flow.status === "expired") {
          setError(
            "時間切れです。コードを再送して最初からやり直してください。",
          );
        }
      } catch {
        if (!cancelled)
          setStatus(
            "確認状態を待っています。メールに届いたコードを入力してください。",
          );
      }
    };
    const timer = window.setInterval(poll, 3_000);
    void poll();
    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, [flowId, onVerified]);

  useEffect(() => {
    if (!expiresAt) return;
    const update = () => {
      const seconds = Math.max(
        0,
        Math.ceil((new Date(expiresAt).getTime() - Date.now()) / 1000),
      );
      setRemainingSeconds(seconds);
    };
    update();
    const timer = window.setInterval(update, 1_000);
    return () => window.clearInterval(timer);
  }, [expiresAt]);

  const start = (event: React.FormEvent) => {
    event.preventDefault();
    setError("");
    setStatus("");
    startMutation.mutate(email.trim());
  };

  const verify = (event: React.FormEvent) => {
    event.preventDefault();
    if (!flowId) return;
    setError("");
    verifyMutation.mutate({ id: flowId, value: code.trim() });
  };

  if (!flowId) {
    return (
      <form onSubmit={start} noValidate={false}>
        <h2>{title}</h2>
        <p>{description}</p>
        <label htmlFor={`${purpose}-email`}>メールアドレス</label>
        <input
          id={`${purpose}-email`}
          type="email"
          autoComplete="email"
          required
          value={email}
          onChange={(event) => setEmail(event.currentTarget.value)}
        />
        <ErrorMessage>{error}</ErrorMessage>
        <StatusMessage>{status}</StatusMessage>
        <button type="submit" disabled={startMutation.isPending}>
          {startMutation.isPending ? "送信中…" : submitLabel}
        </button>
      </form>
    );
  }

  return (
    <form onSubmit={verify}>
      <h2>確認コードを入力</h2>
      <p>
        {email} に送信されたメールに記載された 6
        桁コードを入力してください。マジックリンクを同じ端末のこのブラウザで開いた場合は、自動的に次へ進みます。
      </p>
      {remainingSeconds !== null ? (
        <p aria-live="polite">
          コードの有効期限: 残り約 {Math.ceil(remainingSeconds / 60)} 分
        </p>
      ) : null}
      <label htmlFor={`${purpose}-code`}>6 桁コード</label>
      <input
        ref={codeInputRef}
        id={`${purpose}-code`}
        type="text"
        inputMode="numeric"
        autoComplete="one-time-code"
        pattern="[0-9]{6}"
        required
        value={code}
        onChange={(event) => setCode(event.currentTarget.value)}
      />
      <ErrorMessage>{error}</ErrorMessage>
      <StatusMessage>{status}</StatusMessage>
      <div className="actions">
        <button type="submit" disabled={verifyMutation.isPending}>
          {verifyMutation.isPending ? "確認中…" : "確認する"}
        </button>
        <button
          type="button"
          className="secondary"
          disabled={startMutation.isPending}
          onClick={() => {
            notifiedRef.current = false;
            startMutation.mutate(email.trim());
          }}
        >
          コードを再送
        </button>
        <button
          type="button"
          className="secondary"
          onClick={() => {
            setFlowId(null);
            setCode("");
            setError("");
            setStatus("");
            notifiedRef.current = false;
          }}
        >
          最初からやり直す
        </button>
      </div>
    </form>
  );
}
