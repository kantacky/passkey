export class ApiError extends Error {
  readonly status: number;
  readonly code: string;
  readonly retryAfter: number | null;

  constructor(
    status: number,
    code: string,
    message: string,
    retryAfter: number | null = null,
  ) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
    this.retryAfter = retryAfter;
  }
}

type ApiOptions = {
  method?: "GET" | "POST" | "PATCH" | "DELETE";
  body?: unknown;
  signal?: AbortSignal;
};

export async function api<T>(
  path: string,
  options: ApiOptions = {},
): Promise<T> {
  const headers = new Headers();
  if (options.body !== undefined)
    headers.set("Content-Type", "application/json");

  const response = await fetch(`/api/v1${path}`, {
    method: options.method ?? "GET",
    credentials: "same-origin",
    headers,
    body: options.body === undefined ? undefined : JSON.stringify(options.body),
    signal: options.signal,
  });

  const retryAfterHeader = response.headers.get("Retry-After");
  const retryAfter =
    retryAfterHeader === null ? null : Number(retryAfterHeader);
  const text = await response.text();
  const json = text ? safeJson(text) : null;

  if (!response.ok) {
    const error =
      json && typeof json === "object"
        ? (json as { error?: { code?: unknown; message?: unknown } }).error
        : undefined;
    throw new ApiError(
      response.status,
      typeof error?.code === "string" ? error.code : "request_failed",
      typeof error?.message === "string"
        ? error.message
        : "通信に失敗しました。時間をおいてもう一度お試しください。",
      Number.isFinite(retryAfter) ? retryAfter : null,
    );
  }

  return json as T;
}

function safeJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

export function isApiError(error: unknown, code?: string): error is ApiError {
  return (
    error instanceof ApiError && (code === undefined || error.code === code)
  );
}

export type SessionKind = "normal" | "recovery";

export type Me = {
  id: string;
  email: string;
  userHandle: string;
  kind: SessionKind;
  recoveredAt: string | null;
};

export type Passkey = {
  id: string;
  name: string;
  customName?: string | null;
  providerName?: string | null;
  iconLight?: string | null;
  iconDark?: string | null;
  createdAt: string;
  lastUsedAt?: string | null;
  backupEligible: boolean;
  backupState: boolean;
};

export type PasskeysResponse = {
  passkeys: Passkey[];
};

export type SessionInfo = {
  id: string;
  deviceLabel: string;
  createdAt: string;
  lastSeenAt: string;
  isCurrent: boolean;
};

export type SessionsResponse = {
  sessions: SessionInfo[];
};

export type VerificationPurpose = "signup" | "recovery" | "email_change";
export type VerificationStatus =
  | "pending"
  | "verified"
  | "consumed"
  | "expired";

export type EmailVerification = {
  id: string;
  status: VerificationStatus;
  purpose?: VerificationPurpose;
  expiresAt?: string;
  verifiedExpiresAt?: string;
};

export type AuthenticationOptionsResponse = Record<string, unknown>;
export type RegistrationOptionsResponse = Record<string, unknown>;
