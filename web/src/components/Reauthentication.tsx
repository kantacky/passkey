import { useMutation } from "@tanstack/react-query";
import { useRef, useState } from "react";
import { isApiError } from "../lib/api";
import { reauthenticate } from "../lib/passkey-actions";
import { classifyWebAuthnError, webAuthnErrorMessage } from "../lib/webauthn";
import { ErrorMessage, StatusMessage } from "./Feedback";

export function useReauthenticatedAction<TArgs, TResult>(
  action: (args: TArgs) => Promise<TResult>,
  onSuccess?: (result: TResult) => void | Promise<void>,
) {
  const [needsReauthentication, setNeedsReauthentication] = useState(false);
  const [error, setError] = useState("");
  const pendingRef = useRef<{ args: TArgs } | null>(null);

  const mutation = useMutation({
    mutationFn: async ({
      args,
      reauthenticateFirst,
    }: {
      args: TArgs;
      reauthenticateFirst: boolean;
    }) => {
      if (reauthenticateFirst) await reauthenticate();
      return action(args);
    },
    onSuccess: (result) => {
      pendingRef.current = null;
      setNeedsReauthentication(false);
      setError("");
      void onSuccess?.(result);
    },
    onError: (cause, variables) => {
      if (
        !variables.reauthenticateFirst &&
        isApiError(cause, "reauthentication_required")
      ) {
        pendingRef.current = { args: variables.args };
        setNeedsReauthentication(true);
        setError("");
        return;
      }
      setError(describeError(cause));
    },
  });

  const perform = (args: TArgs) => {
    setError("");
    mutation.mutate({ args, reauthenticateFirst: false });
  };

  const reauthenticateAndRetry = () => {
    const pending = pendingRef.current;
    if (!pending) return;
    setError("");
    mutation.mutate({ args: pending.args, reauthenticateFirst: true });
  };

  return {
    perform,
    needsReauthentication,
    reauthenticateAndRetry,
    error,
    busy: mutation.isPending,
    setError,
  };
}

function describeError(cause: unknown): string {
  if (isApiError(cause)) return cause.message;
  const classified = webAuthnErrorMessage(classifyWebAuthnError(cause), "get");
  return `${classified.title}。${classified.description}`;
}

export function ReauthenticationPrompt({
  visible,
  busy,
  error,
  onReauthenticate,
}: {
  visible: boolean;
  busy: boolean;
  error: string;
  onReauthenticate: () => void;
}) {
  if (!visible) return null;
  return (
    <section
      className="reauthentication"
      aria-labelledby="reauthentication-heading"
    >
      <h2 id="reauthentication-heading">続行するには再認証が必要です</h2>
      <p>
        この操作はアカウントの安全に関わるため、パスキーで本人確認を行います。
      </p>
      <ErrorMessage>{error}</ErrorMessage>
      <StatusMessage>{busy ? "パスキーで確認しています…" : ""}</StatusMessage>
      <button type="button" onClick={onReauthenticate} disabled={busy}>
        パスキーで再認証
      </button>
    </section>
  );
}
