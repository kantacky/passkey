export type JsonCredential = Record<string, unknown>;

type PublicKeyCredentialWithJson = PublicKeyCredential & {
  toJSON?: () => JsonCredential;
};

type PublicKeyCredentialConstructorWithParsers = typeof PublicKeyCredential & {
  parseCreationOptionsFromJSON?: (
    options: Record<string, unknown>,
  ) => PublicKeyCredentialCreationOptions;
  parseRequestOptionsFromJSON?: (
    options: Record<string, unknown>,
  ) => PublicKeyCredentialRequestOptions;
};

export function isWebAuthnSupported(): boolean {
  return (
    typeof window !== "undefined" &&
    typeof window.PublicKeyCredential !== "undefined" &&
    !!navigator.credentials
  );
}

export async function isConditionalUiAvailable(): Promise<boolean> {
  if (!isWebAuthnSupported()) return false;
  const ctor = window.PublicKeyCredential as typeof PublicKeyCredential & {
    isConditionalMediationAvailable?: () => Promise<boolean>;
  };
  if (!ctor.isConditionalMediationAvailable) return false;
  try {
    return await ctor.isConditionalMediationAvailable();
  } catch {
    return false;
  }
}

export async function isPlatformAuthenticatorAvailable(): Promise<
  boolean | null
> {
  if (!isWebAuthnSupported()) return null;
  const ctor = window.PublicKeyCredential as typeof PublicKeyCredential & {
    isUserVerifyingPlatformAuthenticatorAvailable?: () => Promise<boolean>;
  };
  if (!ctor.isUserVerifyingPlatformAuthenticatorAvailable) return null;
  try {
    return await ctor.isUserVerifyingPlatformAuthenticatorAvailable();
  } catch {
    return null;
  }
}

export async function createPasskey(
  optionsJson: RegistrationOptionsLike,
): Promise<JsonCredential> {
  if (!isWebAuthnSupported()) throw new Error("unsupported");
  const publicKey = parseCreationOptions(optionsJson);
  const credential = (await navigator.credentials.create({
    publicKey,
  })) as PublicKeyCredentialWithJson | null;
  if (!credential) throw new Error("credential_not_created");
  return creationCredentialToJSON(credential);
}

export async function getPasskey(
  optionsJson: AuthenticationOptionsLike,
  mediation?: CredentialMediationRequirement,
  signal?: AbortSignal,
): Promise<JsonCredential> {
  if (!isWebAuthnSupported()) throw new Error("unsupported");
  const publicKey = parseRequestOptions(optionsJson);
  const credential = (await navigator.credentials.get({
    publicKey,
    mediation,
    signal,
  })) as PublicKeyCredentialWithJson | null;
  if (!credential) throw new Error("credential_not_selected");
  return requestCredentialToJSON(credential);
}

export type RegistrationOptionsLike = Record<string, unknown>;
export type AuthenticationOptionsLike = Record<string, unknown>;

export function parseCreationOptions(
  optionsJson: RegistrationOptionsLike,
): PublicKeyCredentialCreationOptions {
  const input = unwrapPublicKey(optionsJson);
  const ctor =
    window.PublicKeyCredential as PublicKeyCredentialConstructorWithParsers;
  if (ctor.parseCreationOptionsFromJSON)
    return ctor.parseCreationOptionsFromJSON(input);

  const user = { ...(input.user as Record<string, unknown>) };
  user.id = decodeBase64url(String(user.id));
  return {
    ...(input as unknown as PublicKeyCredentialCreationOptions),
    challenge: decodeBase64url(String(input.challenge)),
    user: user as unknown as PublicKeyCredentialUserEntity,
    excludeCredentials: convertCredentialDescriptors(input.excludeCredentials),
  };
}

export function parseRequestOptions(
  optionsJson: AuthenticationOptionsLike,
): PublicKeyCredentialRequestOptions {
  const input = unwrapPublicKey(optionsJson);
  const ctor =
    window.PublicKeyCredential as PublicKeyCredentialConstructorWithParsers;
  if (ctor.parseRequestOptionsFromJSON)
    return ctor.parseRequestOptionsFromJSON(input);

  return {
    ...(input as unknown as PublicKeyCredentialRequestOptions),
    challenge: decodeBase64url(String(input.challenge)),
    allowCredentials: convertCredentialDescriptors(input.allowCredentials),
  };
}

function unwrapPublicKey(
  optionsJson: Record<string, unknown>,
): Record<string, unknown> {
  const nested = optionsJson.publicKey;
  if (
    nested &&
    typeof nested === "object" &&
    !ArrayBuffer.isView(nested) &&
    !(nested instanceof ArrayBuffer)
  ) {
    return { ...(nested as Record<string, unknown>) };
  }
  return { ...optionsJson };
}

function convertCredentialDescriptors(
  value: unknown,
): PublicKeyCredentialDescriptor[] | undefined {
  if (!Array.isArray(value)) return undefined;
  return value.map((entry) => {
    const credential = entry as Record<string, unknown>;
    return {
      ...(credential as unknown as PublicKeyCredentialDescriptor),
      id: decodeBase64url(String(credential.id)),
    };
  });
}

function creationCredentialToJSON(
  credential: PublicKeyCredentialWithJson,
): JsonCredential {
  if (credential.toJSON) return credential.toJSON();
  const response = credential.response as AuthenticatorAttestationResponse;
  return {
    id: credential.id,
    rawId: encodeBase64url(credential.rawId),
    type: credential.type,
    authenticatorAttachment: credential.authenticatorAttachment,
    clientExtensionResults: credential.getClientExtensionResults(),
    response: {
      clientDataJSON: encodeBase64url(response.clientDataJSON),
      attestationObject: encodeBase64url(response.attestationObject),
      transports:
        typeof response.getTransports === "function"
          ? response.getTransports()
          : undefined,
    },
  };
}

function requestCredentialToJSON(
  credential: PublicKeyCredentialWithJson,
): JsonCredential {
  if (credential.toJSON) return credential.toJSON();
  const response = credential.response as AuthenticatorAssertionResponse;
  return {
    id: credential.id,
    rawId: encodeBase64url(credential.rawId),
    type: credential.type,
    authenticatorAttachment: credential.authenticatorAttachment,
    clientExtensionResults: credential.getClientExtensionResults(),
    response: {
      clientDataJSON: encodeBase64url(response.clientDataJSON),
      authenticatorData: encodeBase64url(response.authenticatorData),
      signature: encodeBase64url(response.signature),
      userHandle: response.userHandle
        ? encodeBase64url(response.userHandle)
        : null,
    },
  };
}

export function encodeBase64url(input: ArrayBuffer | ArrayBufferView): string {
  const bytes =
    input instanceof ArrayBuffer
      ? new Uint8Array(input)
      : new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
  let binary = "";
  for (let index = 0; index < bytes.length; index += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
  }
  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/u, "");
}

export function decodeBase64url(value: string): ArrayBuffer {
  const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1)
    bytes[index] = binary.charCodeAt(index);
  return bytes.buffer;
}

export type WebAuthnErrorKind =
  | "cancelled"
  | "already_registered"
  | "uv_unavailable"
  | "unsupported"
  | "failed";

export function classifyWebAuthnError(error: unknown): WebAuthnErrorKind {
  if (error instanceof DOMException) {
    if (error.name === "NotAllowedError") return "cancelled";
    if (error.name === "InvalidStateError") return "already_registered";
    if (error.name === "NotSupportedError" || error.name === "SecurityError")
      return "uv_unavailable";
  }
  if (error instanceof Error && error.message === "unsupported")
    return "unsupported";
  return "failed";
}

export function webAuthnErrorMessage(
  kind: WebAuthnErrorKind,
  operation: "create" | "get",
): { title: string; description: string } {
  if (operation === "create") {
    switch (kind) {
      case "cancelled":
        return {
          title: "パスキーの作成を中止しました",
          description:
            "作成はまだ完了していません。「パスキーを作成」ボタンで再試行できます。",
        };
      case "already_registered":
        return {
          title: "このパスキーは登録済みです",
          description: "このパスキーでサインインできます。",
        };
      case "uv_unavailable":
        return {
          title: "画面ロックが必要です",
          description:
            "端末の画面ロック（パスコード等）を設定してから、もう一度お試しください。",
        };
      case "unsupported":
        return {
          title: "このブラウザではパスキーを使えません",
          description: "最新のブラウザまたは対応する端末でお試しください。",
        };
      case "failed":
        return {
          title: "パスキーを作成できませんでした",
          description:
            "もう一度お試しください。サインアップにはパスキーの作成が必要です。",
        };
    }
  }
  switch (kind) {
    case "cancelled":
      return {
        title: "サインインを中止しました",
        description: "もう一度お試しください。",
      };
    case "uv_unavailable":
      return {
        title: "画面ロックが必要です",
        description:
          "端末の画面ロック（パスコード等）を設定してから、もう一度お試しください。",
      };
    case "unsupported":
      return {
        title: "このブラウザではパスキーを使えません",
        description: "最新のブラウザまたは対応する端末でお試しください。",
      };
    default:
      return {
        title: "サインインできませんでした",
        description:
          "もう一度お試しください。時間切れの場合は新しいパスキー確認が始まります。",
      };
  }
}
