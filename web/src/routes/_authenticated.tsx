import {
  createFileRoute,
  Link,
  Outlet,
  redirect,
  useNavigate,
} from "@tanstack/react-router";
import { useState } from "react";
import { ErrorMessage } from "../components/Feedback";
import type { Me } from "../lib/api";
import { queryClient } from "../lib/queryClient";
import { meQueryOptions, signOut } from "../queries/me";

export const Route = createFileRoute("/_authenticated")({
  beforeLoad: async () => {
    let me: Me;
    try {
      me = await queryClient.ensureQueryData(meQueryOptions);
    } catch {
      throw redirect({ to: "/sign-in" });
    }
    if (me.kind === "recovery") throw redirect({ to: "/create-passkey" });
    return { me };
  },
  component: AuthenticatedLayout,
});

function AuthenticatedLayout() {
  const navigate = useNavigate();
  const [error, setError] = useState("");
  const logout = async () => {
    try {
      await signOut();
      queryClient.clear();
      void navigate({ to: "/sign-in" });
    } catch {
      setError("サインアウトできませんでした。もう一度お試しください。");
    }
  };

  return (
    <div>
      <header className="app-header">
        <Link to="/passkeys" className="brand">
          Passkey
        </Link>
        <nav aria-label="アカウント設定">
          <Link to="/passkeys" activeProps={{ "aria-current": "page" }}>
            パスキー
          </Link>
          <Link to="/sessions" activeProps={{ "aria-current": "page" }}>
            セッション
          </Link>
          <Link to="/account" activeProps={{ "aria-current": "page" }}>
            アカウント
          </Link>
        </nav>
        <button
          type="button"
          className="secondary"
          onClick={() => void logout()}
        >
          サインアウト
        </button>
      </header>
      <ErrorMessage>{error}</ErrorMessage>
      <Outlet />
    </div>
  );
}
