import { createFileRoute } from "@tanstack/react-router";
import { Page } from "../components/Feedback";
import { VerifyToken } from "../components/VerifyToken";

export const Route = createFileRoute("/verify")({
  validateSearch: (search: Record<string, unknown>) => ({
    flow: typeof search.flow === "string" ? search.flow : undefined,
  }),
  component: VerifyPage,
});

function VerifyPage() {
  const { flow } = Route.useSearch();
  return (
    <Page
      title="メールアドレスの確認"
      description="確認リンクを検証しています。"
    >
      <VerifyToken flow={flow} />
    </Page>
  );
}
