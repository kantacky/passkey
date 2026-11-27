import { createFileRoute } from "@tanstack/react-router";
import { Page } from "../../components/Feedback";
import { VerifyToken } from "../../components/VerifyToken";

export const Route = createFileRoute("/app/verify")({
  validateSearch: (search: Record<string, unknown>) => ({
    flow: typeof search.flow === "string" ? search.flow : undefined,
  }),
  component: AppVerifyPage,
});

function AppVerifyPage() {
  const { flow } = Route.useSearch();
  return (
    <Page
      title="アプリの確認リンク"
      description="アプリが開かない場合は、登録を始めた画面でコードを入力してください。"
    >
      <VerifyToken flow={flow} appLink />
    </Page>
  );
}
