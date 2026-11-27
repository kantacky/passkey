import { queryOptions } from "@tanstack/react-query";
import { api, type SessionInfo, type SessionsResponse } from "../lib/api";

export const sessionsQueryOptions = queryOptions({
  queryKey: ["sessions"],
  queryFn: ({ signal }) => fetchSessions(signal),
});

export async function fetchSessions(
  signal?: AbortSignal,
): Promise<SessionInfo[]> {
  const response = await api<SessionsResponse>("/sessions", { signal });
  return response.sessions;
}

export function revokeSession(id: string): Promise<void> {
  return api<void>(`/sessions/${encodeURIComponent(id)}`, { method: "DELETE" });
}

export function revokeOtherSessions(): Promise<void> {
  return api<void>("/sessions/revoke-others", { method: "POST" });
}
