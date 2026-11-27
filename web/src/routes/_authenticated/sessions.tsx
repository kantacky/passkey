import { useQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";
import { ErrorMessage, Page, StatusMessage } from "../../components/Feedback";
import {
  ReauthenticationPrompt,
  useReauthenticatedAction,
} from "../../components/Reauthentication";
import type { SessionInfo } from "../../lib/api";
import { queryClient } from "../../lib/queryClient";
import {
  revokeOtherSessions,
  revokeSession,
  sessionsQueryOptions,
} from "../../queries/sessions";

export const Route = createFileRoute("/_authenticated/sessions")({
  component: SessionsPage,
});

type RevokeRequest = { type: "one"; session: SessionInfo } | { type: "others" };

function SessionsPage() {
  const sessions = useQuery(sessionsQueryOptions);
  const [message, setMessage] = useState("");
  const action = useReauthenticatedAction<RevokeRequest, void>(
    async (request) => {
      if (request.type === "one") await revokeSession(request.session.id);
      else await revokeOtherSessions();
    },
    async () => {
      setMessage("セッションを失効しました。");
      await queryClient.invalidateQueries({ queryKey: ["sessions"] });
    },
  );

  return (
    <Page
      title="セッション"
      description="サインイン中の端末を確認し、不要なセッションを失効できます。"
    >
      {sessions.isPending ? <p>読み込んでいます…</p> : null}
      {sessions.isError ? (
        <ErrorMessage>セッション一覧を読み込めませんでした。</ErrorMessage>
      ) : null}
      <StatusMessage>{message}</StatusMessage>
      {sessions.data ? (
        <>
          <div className="card-list">
            {sessions.data.map((session) => (
              <article className="card" key={session.id}>
                <div className="card-body">
                  <h2>
                    {session.deviceLabel}
                    {session.isCurrent ? "（このセッション）" : ""}
                  </h2>
                  <dl>
                    <div>
                      <dt>作成日時</dt>
                      <dd>{formatDate(session.createdAt)}</dd>
                    </div>
                    <div>
                      <dt>最終アクセス</dt>
                      <dd>{formatDate(session.lastSeenAt)}</dd>
                    </div>
                  </dl>
                  {!session.isCurrent ? (
                    <button
                      type="button"
                      className="danger"
                      onClick={() => action.perform({ type: "one", session })}
                      disabled={action.busy}
                    >
                      このセッションを失効
                    </button>
                  ) : null}
                </div>
              </article>
            ))}
          </div>
          <section aria-labelledby="revoke-others-heading">
            <h2 id="revoke-others-heading">
              他のセッションをすべてサインアウト
            </h2>
            <p>この端末以外でサインイン中のセッションをすべて失効します。</p>
            <button
              type="button"
              className="danger"
              onClick={() => action.perform({ type: "others" })}
              disabled={action.busy || sessions.data.length <= 1}
            >
              他のセッションをすべてサインアウト
            </button>
          </section>
        </>
      ) : null}
      <ReauthenticationPrompt
        visible={action.needsReauthentication}
        busy={action.busy}
        error={action.error}
        onReauthenticate={() => void action.reauthenticateAndRetry()}
      />
      {!action.needsReauthentication ? (
        <ErrorMessage>{action.error}</ErrorMessage>
      ) : null}
    </Page>
  );
}

function formatDate(value: string): string {
  return new Intl.DateTimeFormat("ja-JP", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(value));
}
