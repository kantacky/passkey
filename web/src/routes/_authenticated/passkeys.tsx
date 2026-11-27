import { useMutation, useQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";
import { ErrorMessage, Page, StatusMessage } from "../../components/Feedback";
import { registrationCompletion } from "../../components/PasskeyCreation";
import {
  ReauthenticationPrompt,
  useReauthenticatedAction,
} from "../../components/Reauthentication";
import { isApiError, type Passkey } from "../../lib/api";
import { registerPasskey } from "../../lib/passkey-actions";
import { queryClient } from "../../lib/queryClient";
import { signalAllAcceptedCredentials } from "../../lib/signal";
import { meQueryOptions } from "../../queries/me";
import {
  deletePasskey,
  passkeysQueryOptions,
  renamePasskey,
} from "../../queries/passkeys";
import { revokeOtherSessions } from "../../queries/sessions";

export const Route = createFileRoute("/_authenticated/passkeys")({
  component: PasskeysPage,
});

function PasskeysPage() {
  const passkeys = useQuery(passkeysQueryOptions);
  const me = useQuery(meQueryOptions);
  const [completion, setCompletion] = useState("");
  const addAction = useReauthenticatedAction<null, unknown>(
    () => registerPasskey(),
    async (result) => {
      await queryClient.invalidateQueries({ queryKey: ["passkeys"] });
      const details = registrationCompletion(result);
      const backupWarning =
        details.backupEligible === false
          ? "このパスキーはこの端末（またはセキュリティキー）でのみ使えます。"
          : "";
      setCompletion(
        `パスキーを作成しました。次回からこのパスキーでサインインできます。${backupWarning}必要に応じて、他のセッションをすべてサインアウトしてください。`,
      );
    },
  );

  return (
    <Page
      title="パスキー"
      description="パスキーは、顔・指紋・画面ロックを使ってサインインするためのデジタルの鍵です。パスワード管理に保存され、同じアカウントの他の端末でも使えます。"
    >
      <section aria-labelledby="add-passkey-heading">
        <h2 id="add-passkey-heading">パスキーを追加</h2>
        <p>
          別の端末やセキュリティキーを使えるように、パスキーを追加できます。追加前に再認証が必要です。
        </p>
        <ErrorMessage>{addAction.error}</ErrorMessage>
        <button
          type="button"
          onClick={() => addAction.perform(null)}
          disabled={addAction.busy}
        >
          パスキーを追加
        </button>
        <ReauthenticationPrompt
          visible={addAction.needsReauthentication}
          busy={addAction.busy}
          error={addAction.error}
          onReauthenticate={() => void addAction.reauthenticateAndRetry()}
        />
      </section>
      <StatusMessage>{completion}</StatusMessage>
      {completion ? <RevokeOthersButton /> : null}
      <RecoveryNotice recoveredAt={me.data?.recoveredAt ?? null} />
      {passkeys.isPending ? <p>読み込んでいます…</p> : null}
      {passkeys.isError ? (
        <ErrorMessage>パスキー一覧を読み込めませんでした。</ErrorMessage>
      ) : null}
      {passkeys.data ? (
        <PasskeyList
          passkeys={passkeys.data}
          onChanged={() => setCompletion("")}
        />
      ) : null}
    </Page>
  );
}

function RecoveryNotice({ recoveredAt }: { recoveredAt: string | null }) {
  if (!recoveredAt) return null;
  const until = new Date(new Date(recoveredAt).getTime() + 24 * 60 * 60 * 1000);
  const restricted = until.getTime() > Date.now();
  return (
    <div className="status" aria-live="polite">
      <p>
        アカウント回復が完了しました。紛失した端末のパスキーは削除してください。
      </p>
      {restricted ? (
        <p>
          以前のパスキーは{" "}
          {new Intl.DateTimeFormat("ja-JP", {
            dateStyle: "medium",
            timeStyle: "short",
          }).format(until)}{" "}
          以降に削除できます。
        </p>
      ) : null}
    </div>
  );
}

function PasskeyList({
  passkeys,
  onChanged,
}: {
  passkeys: Passkey[];
  onChanged: () => void;
}) {
  const [deleteTarget, setDeleteTarget] = useState<Passkey | null>(null);
  const [deleted, setDeleted] = useState(false);
  const [signalMessage, setSignalMessage] = useState("");
  const deleteAction = useReauthenticatedAction<Passkey, string[]>(
    (passkey) => deletePasskey(passkey.id),
    async (allAcceptedCredentialIds) => {
      const me = await queryClient.ensureQueryData(meQueryOptions);
      const signalled = await signalAllAcceptedCredentials(
        me.userHandle,
        allAcceptedCredentialIds,
      );
      setSignalMessage(
        signalled
          ? "端末のパスワード管理にも削除を通知しました。"
          : "端末のパスワード管理に古い表示が残る場合があります。",
      );
      setDeleted(true);
      setDeleteTarget(null);
      await queryClient.invalidateQueries({ queryKey: ["passkeys"] });
      onChanged();
    },
  );

  return (
    <section aria-labelledby="passkey-list-heading">
      <h2 id="passkey-list-heading">登録済みのパスキー</h2>
      {deleted ? (
        <div className="status" aria-live="polite">
          <p>
            パスキーを削除しました。このパスキーは今後どの端末でも使えません。
            {signalMessage}
          </p>
          <details>
            <summary>端末のパスワード管理からも削除する手順</summary>
            <p>
              使用しているパスワード管理アプリまたは端末の設定を開き、このサービスの削除済みパスキーを手動で削除できます。サインインには影響しません。
            </p>
          </details>
          <RevokeOthersButton />
        </div>
      ) : null}
      <div className="card-list">
        {passkeys.map((passkey) => (
          <PasskeyCard
            key={passkey.id}
            passkey={passkey}
            onlyOne={passkeys.length === 1}
            onDelete={() => setDeleteTarget(passkey)}
          />
        ))}
      </div>
      {deleteTarget ? (
        <section
          className="confirmation"
          aria-labelledby="delete-passkey-heading"
        >
          <h2 id="delete-passkey-heading">このパスキーを削除しますか？</h2>
          <p>削除すると、このパスキーではサインインできなくなります。</p>
          <div className="card highlighted">
            <strong>{displayName(deleteTarget)}</strong>
          </div>
          <ErrorMessage>{deleteAction.error}</ErrorMessage>
          <div className="actions">
            <button
              type="button"
              className="secondary"
              onClick={() => setDeleteTarget(null)}
            >
              キャンセル
            </button>
            <button
              type="button"
              className="danger"
              onClick={() => deleteAction.perform(deleteTarget)}
              disabled={deleteAction.busy}
            >
              パスキーを削除
            </button>
          </div>
          <ReauthenticationPrompt
            visible={deleteAction.needsReauthentication}
            busy={deleteAction.busy}
            error={deleteAction.error}
            onReauthenticate={() => void deleteAction.reauthenticateAndRetry()}
          />
        </section>
      ) : null}
    </section>
  );
}

function PasskeyCard({
  passkey,
  onlyOne,
  onDelete,
}: {
  passkey: Passkey;
  onlyOne: boolean;
  onDelete: () => void;
}) {
  const [editing, setEditing] = useState(false);
  const [name, setName] = useState(passkey.name ?? "");
  const [error, setError] = useState("");
  const rename = useMutation({
    mutationFn: () =>
      renamePasskey(passkey.id, name.trim() === "" ? null : name.trim()),
    onSuccess: async () => {
      setEditing(false);
      setError("");
      await queryClient.invalidateQueries({ queryKey: ["passkeys"] });
    },
    onError: (cause) => {
      setError(
        isApiError(cause) ? cause.message : "名前を変更できませんでした。",
      );
    },
  });

  return (
    <article className="card">
      <div className="passkey-icon" aria-hidden="true">
        {passkey.iconUrl ? (
          <img src={passkey.iconUrl} alt="" />
        ) : (
          <GenericPasskeyIcon />
        )}
      </div>
      <div className="card-body">
        <h3>{displayName(passkey)}</h3>
        <dl>
          <div>
            <dt>作成日時</dt>
            <dd>{formatDate(passkey.createdAt)}</dd>
          </div>
          <div>
            <dt>最終使用日時</dt>
            <dd>
              {passkey.lastUsedAt
                ? formatDate(passkey.lastUsedAt)
                : "まだ使用されていません"}
            </dd>
          </div>
          <div>
            <dt>同期</dt>
            <dd>
              {passkey.backupEligible
                ? passkey.backupState
                  ? "同期されます"
                  : "同期できます"
                : "この端末またはセキュリティキーのみ"}
            </dd>
          </div>
        </dl>
        {!passkey.backupState ? (
          <p>
            このパスキーはこの端末（またはセキュリティキー）でのみ使えます。
          </p>
        ) : null}
        {editing ? (
          <form
            onSubmit={(event) => {
              event.preventDefault();
              rename.mutate();
            }}
          >
            <label htmlFor={`rename-${passkey.id}`}>パスキー名</label>
            <input
              id={`rename-${passkey.id}`}
              value={name}
              minLength={1}
              maxLength={64}
              onChange={(event) => setName(event.currentTarget.value)}
            />
            <ErrorMessage>{error}</ErrorMessage>
            <div className="actions">
              <button type="submit" disabled={rename.isPending}>
                保存
              </button>
              <button
                type="button"
                className="secondary"
                onClick={() => setEditing(false)}
              >
                キャンセル
              </button>
            </div>
          </form>
        ) : (
          <div className="actions">
            <button
              type="button"
              className="secondary"
              onClick={() => setEditing(true)}
            >
              名前を変更
            </button>
            <button
              type="button"
              className="danger"
              onClick={onDelete}
              disabled={onlyOne}
              aria-describedby={onlyOne ? `last-${passkey.id}` : undefined}
            >
              削除
            </button>
            {onlyOne ? (
              <span id={`last-${passkey.id}`}>
                別のパスキーを追加してから削除してください
              </span>
            ) : null}
          </div>
        )}
      </div>
    </article>
  );
}

function RevokeOthersButton() {
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");
  const mutation = useMutation({
    mutationFn: revokeOtherSessions,
    onSuccess: async () => {
      setMessage("他のセッションをすべてサインアウトしました。");
      await queryClient.invalidateQueries({ queryKey: ["sessions"] });
    },
    onError: (cause) =>
      setError(
        isApiError(cause)
          ? cause.message
          : "セッションを失効できませんでした。",
      ),
  });
  return (
    <div>
      <button
        type="button"
        className="secondary"
        onClick={() => mutation.mutate()}
        disabled={mutation.isPending}
      >
        他のセッションをすべてサインアウト
      </button>
      <StatusMessage>{message}</StatusMessage>
      <ErrorMessage>{error}</ErrorMessage>
    </div>
  );
}

function displayName(passkey: Passkey): string {
  if (passkey.name) return passkey.name;
  if (passkey.displayName) return passkey.displayName;
  const date = new Date(passkey.createdAt).toLocaleDateString("ja-JP");
  return passkey.providerName
    ? `${passkey.providerName}（${date}）`
    : `パスキー（${date}）`;
}

function formatDate(value: string): string {
  return new Intl.DateTimeFormat("ja-JP", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(value));
}

function GenericPasskeyIcon() {
  return (
    <svg viewBox="0 0 24 24" width="32" height="32" aria-hidden="true">
      <path
        d="M14 3a7 7 0 0 0-6.93 8.03L3 17.1V21h3.9v-2.5h2.5v-2.5h2.4l1.13-1.13A7 7 0 1 0 14 3Zm0 4a2 2 0 1 1 0 4 2 2 0 0 1 0-4Z"
        fill="currentColor"
      />
    </svg>
  );
}
