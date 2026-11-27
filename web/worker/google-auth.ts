type ServiceAccountKey = {
  client_email: string;
  private_key: string;
};

type CachedToken = {
  token: string;
  expiresAt: number;
};

const tokenCache = new Map<string, CachedToken>();
const DEFAULT_TOKEN_URL = "https://oauth2.googleapis.com/token";

export async function getGoogleIdToken(
  serviceAccountKeyJson: string,
  audience: string,
  tokenUrl = DEFAULT_TOKEN_URL,
): Promise<string> {
  const key = parseServiceAccountKey(serviceAccountKeyJson);
  const cacheKey = `${key.client_email}:${audience}`;
  const cached = tokenCache.get(cacheKey);
  if (cached && cached.expiresAt > Date.now()) return cached.token;

  const now = Math.floor(Date.now() / 1000);
  const assertion = await signJwt(
    {
      iss: key.client_email,
      sub: key.client_email,
      aud: tokenUrl,
      target_audience: audience,
      iat: now,
      exp: now + 3600,
    },
    key.private_key,
  );

  const response = await fetch(tokenUrl, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  if (!response.ok)
    throw new Error(`google token request failed: ${response.status}`);
  const body = (await response.json()) as {
    id_token?: string;
    expires_in?: number;
  };
  if (!body.id_token)
    throw new Error("google token response did not contain an id token");

  const lifetime = Math.max(1, body.expires_in ?? 3600);
  const refreshMargin = Math.min(300, Math.floor(lifetime / 2));
  tokenCache.set(cacheKey, {
    token: body.id_token,
    expiresAt: Date.now() + (lifetime - refreshMargin) * 1000,
  });
  return body.id_token;
}

export function parseServiceAccountKey(value: string): ServiceAccountKey {
  const parsed = JSON.parse(value) as Partial<ServiceAccountKey>;
  if (!parsed.client_email || !parsed.private_key)
    throw new Error("invalid service account key");
  return { client_email: parsed.client_email, private_key: parsed.private_key };
}

export async function signJwt(
  payload: Record<string, unknown>,
  privateKeyPem: string,
): Promise<string> {
  const header = { alg: "RS256", typ: "JWT" };
  const unsigned = `${base64urlEncodeText(JSON.stringify(header))}.${base64urlEncodeText(JSON.stringify(payload))}`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(privateKeyPem),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(unsigned),
  );
  return `${unsigned}.${base64urlEncodeBytes(new Uint8Array(signature))}`;
}

function pemToDer(pem: string): ArrayBuffer {
  const base64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/u, "")
    .replace(/-----END PRIVATE KEY-----/u, "")
    .replace(/\s+/gu, "");
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1)
    bytes[index] = binary.charCodeAt(index);
  return bytes.buffer;
}

function base64urlEncodeText(value: string): string {
  return base64urlEncodeBytes(new TextEncoder().encode(value));
}

function base64urlEncodeBytes(bytes: Uint8Array): string {
  let binary = "";
  for (let index = 0; index < bytes.length; index += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
  }
  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/u, "");
}

export function resetGoogleIdTokenCacheForTests(): void {
  tokenCache.clear();
}
