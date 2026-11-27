import { queryOptions } from "@tanstack/react-query";
import { api, type Passkey, type PasskeysResponse } from "../lib/api";

export const passkeysQueryOptions = queryOptions({
  queryKey: ["passkeys"],
  queryFn: ({ signal }) => fetchPasskeys(signal),
});

export async function fetchPasskeys(signal?: AbortSignal): Promise<Passkey[]> {
  const response = await api<PasskeysResponse>("/passkeys", { signal });
  return response.passkeys;
}

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
  allAcceptedCredentialIds: string[];
};

export async function deletePasskey(id: string): Promise<string[]> {
  const response = await api<DeletePasskeyResponse>(
    `/passkeys/${encodeURIComponent(id)}`,
    { method: "DELETE" },
  );
  return response.allAcceptedCredentialIds;
}
