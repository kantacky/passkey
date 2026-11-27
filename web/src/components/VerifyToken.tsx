import { useNavigate } from "@tanstack/react-router";
import { useEffect, useRef, useState } from "react";
import { api, isApiError } from "../lib/api";
import { queryClient } from "../lib/queryClient";
import { ErrorMessage, StatusMessage } from "./Feedback";

type VerifyResponse = {
  status?: string;
  purpose?: "signup" | "recovery" | "email_change";
};

export function VerifyToken({
  flow,
  appLink = false,
}: {
  flow?: string;
  appLink?: boolean;
}) {
  const navigate = useNavigate();
  const [state, setState] = useState<
    "loading" | "success" | "error" | "missing"
  >("loading");
  const [message, setMessage] = useState("");
  const startedRef = useRef(false);

  useEffect(() => {
    if (startedRef.current) return;
    startedRef.current = true;
    const params = new URLSearchParams(window.location.hash.replace(/^#/u, ""));
    const token = params.get("token");
    window.history.replaceState(
      null,
      "",
      window.location.pathname + window.location.search,
    );

    if (!flow || !token) {
      setState("missing");
      setMessage(
        "確認リンクが正しくありません。メールに記載されたリンクを開くか、登録を始めた画面で 6 桁コードを入力してください。",
      );
      return;
    }

    const verify = async () => {
      try {
        const response = await api<VerifyResponse>(
          `/email-verifications/${encodeURIComponent(flow)}/verify`,
          {
            method: "POST",
            body: { token },
          },
        );
        await queryClient.invalidateQueries({ queryKey: ["me"] });
        setState("success");
        if (response.purpose === "recovery") {
          setMessage(
            "アカウントの確認が完了しました。新しいパスキーを作成します。",
          );
          window.setTimeout(
            () => void navigate({ to: "/create-passkey" }),
            800,
          );
        } else if (response.purpose === "email_change") {
          setMessage("メールアドレスを変更しました。");
          window.setTimeout(() => void navigate({ to: "/account" }), 800);
        } else {
          setMessage(
            "メールアドレスを確認しました。登録を始めた画面に戻ると、パスキーの作成に進めます。",
          );
        }
      } catch (cause) {
        setState("error");
        if (isApiError(cause, "device_mismatch")) {
          setMessage(
            "メールに記載の 6 桁コードを、登録を始めた画面で入力してください。コードはメールの件名と冒頭に記載されています。",
          );
        } else if (isApiError(cause, "flow_expired")) {
          setMessage(
            "時間切れです。登録を始めた画面でコードを再送し、最初からやり直してください。",
          );
        } else if (isApiError(cause, "invalid_code")) {
          setMessage(
            "確認リンクが無効です。最新のメールを開くか、登録を始めた画面でコードを入力してください。",
          );
        } else {
          setMessage(
            "確認できませんでした。登録を始めた画面で 6 桁コードを入力してください。",
          );
        }
      }
    };
    void verify();
  }, [flow, navigate]);

  return (
    <section aria-labelledby="verify-state-heading">
      <h2 id="verify-state-heading">メールアドレスの確認</h2>
      {appLink ? (
        <p>
          アプリがインストールされていない場合は、このページの案内に従って登録を始めた画面でコードを入力してください。
        </p>
      ) : null}
      {state === "loading" ? (
        <StatusMessage>確認しています…</StatusMessage>
      ) : null}
      {state === "success" ? <StatusMessage>{message}</StatusMessage> : null}
      {state === "error" || state === "missing" ? (
        <ErrorMessage>{message}</ErrorMessage>
      ) : null}
    </section>
  );
}
