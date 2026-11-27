import { queryOptions } from "@tanstack/react-query";
import { api, type Me } from "../lib/api";

export const meQueryOptions = queryOptions({
  queryKey: ["me"],
  queryFn: ({ signal }) => api<Me>("/me", { signal }),
  staleTime: 5_000,
});

export async function signOut(): Promise<void> {
  await api("/sessions/current", { method: "DELETE" });
}
