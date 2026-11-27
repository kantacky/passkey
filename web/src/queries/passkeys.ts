import { queryOptions } from "@tanstack/react-query";
import { api, type Passkey } from "../lib/api";

export const passkeysQueryOptions = queryOptions({
  queryKey: ["passkeys"],
  queryFn: ({ signal }) => api<Passkey[]>("/passkeys", { signal }),
});

export function renamePasskey(
  id: string,
  name: string | null,
): Promise<Passkey> {
  return api<Passkey>(`/passkeys/${encodeURIComponent(id)}`, {
    method: "PATCH",
    body: { name },
  });
}

export type DeletePasskeyResponse = {
  allAcceptedCredentialIds?: string[];
  remainingCredentialIds?: string[];
};

export async function deletePasskey(id: string): Promise<string[]> {
  const response = await api<DeletePasskeyResponse>(
    `/passkeys/${encodeURIComponent(id)}`,
    { method: "DELETE" },
  );
  return (
    response.allAcceptedCredentialIds ?? response.remainingCredentialIds ?? []
  );
}
