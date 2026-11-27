import { queryOptions } from "@tanstack/react-query";
import { api, type SessionInfo } from "../lib/api";

export const sessionsQueryOptions = queryOptions({
  queryKey: ["sessions"],
  queryFn: ({ signal }) => api<SessionInfo[]>("/sessions", { signal }),
});

export function revokeSession(id: string): Promise<void> {
  return api<void>(`/sessions/${encodeURIComponent(id)}`, { method: "DELETE" });
}

export function revokeOtherSessions(): Promise<void> {
  return api<void>("/sessions/revoke-others", { method: "POST" });
}
