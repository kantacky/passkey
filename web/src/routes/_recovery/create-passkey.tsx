import { createFileRoute, redirect, useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import { Page } from "../../components/Feedback";
import {
  PasskeyCreation,
  type RegistrationCompletion,
  registrationCompletion,
} from "../../components/PasskeyCreation";
import type { Me } from "../../lib/api";
import { queryClient } from "../../lib/queryClient";
import { meQueryOptions } from "../../queries/me";

export const Route = createFileRoute("/_recovery/create-passkey")({
  beforeLoad: async () => {
    let me: Me;
    try {
      me = await queryClient.ensureQueryData(meQueryOptions);
    } catch {
      throw redirect({ to: "/sign-in" });
    }
    if (me.kind !== "recovery") throw redirect({ to: "/passkeys" });
  },
  component: RecoveryCreatePasskeyPage,
});

function RecoveryCreatePasskeyPage() {
  const navigate = useNavigate();
  const [created, setCreated] = useState<RegistrationCompletion | null>(null);

  return (
    <Page
      title="新しいパスキーを作成"
      description="アカウント回復を完了するには、新しいパスキーが必要です。"
    >
      {created ? (
        <section aria-labelledby="recovery-created-heading">
          <h2 id="recovery-created-heading">パスキーを作成しました</h2>
          <p>
            アカウント回復が完了しました。
            {created.providerName
              ? `パスキーは ${created.providerName} に保存されています。`
              : ""}
            次に、以前のパスキー一覧を確認し、紛失した端末のパスキーは削除してください。
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
            パスキー一覧を確認
          </button>
        </section>
      ) : (
        <PasskeyCreation
          recovery
          onCreated={(result) => {
            void queryClient.invalidateQueries();
            setCreated(registrationCompletion(result));
          }}
        />
      )}
    </Page>
  );
}
