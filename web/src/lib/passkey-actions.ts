import {
  type AuthenticationOptionsResponse,
  api,
  type RegistrationOptionsResponse,
} from "./api";
import { signalUnknownCredential } from "./signal";
import { createPasskey, getPasskey, type JsonCredential } from "./webauthn";

export async function registerPasskey(): Promise<unknown> {
  const options = await api<RegistrationOptionsResponse>(
    "/registrations/options",
    { method: "POST", body: {} },
  );
  const credential = await createPasskey(options);
  return api("/registrations", { method: "POST", body: credential });
}

export async function authenticateWithPasskey(
  mediation?: CredentialMediationRequirement,
  signal?: AbortSignal,
): Promise<unknown> {
  const options = await api<AuthenticationOptionsResponse>(
    "/authentications/options",
    { method: "POST", body: {} },
  );
  const assertion = await getPasskey(options, mediation, signal);
  try {
    return await api("/authentications", { method: "POST", body: assertion });
  } catch (error) {
    if (
      error instanceof Error &&
      error.name === "ApiError" &&
      "code" in error &&
      error.code === "unknown_credential"
    ) {
      const credentialId =
        typeof assertion.id === "string"
          ? assertion.id
          : typeof assertion.rawId === "string"
            ? assertion.rawId
            : null;
      if (credentialId) void signalUnknownCredential(credentialId);
    }
    throw error;
  }
}

export async function reauthenticate(): Promise<void> {
  const options = await api<AuthenticationOptionsResponse>(
    "/authentications/options",
    { method: "POST", body: { reauth: true } },
  );
  const assertion = await getPasskey(options);
  await api("/authentications", { method: "POST", body: assertion });
}

export type { JsonCredential };
