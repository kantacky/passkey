import { afterEach, describe, expect, test } from "bun:test";
import {
  getGoogleIdToken,
  resetGoogleIdTokenCacheForTests,
  signJwt,
} from "../../worker/google-auth";
import { cloudflareCountry, rateLimitKey } from "../../worker/index";

const originalFetch = globalThis.fetch;

afterEach(() => {
  globalThis.fetch = originalFetch;
  resetGoogleIdTokenCacheForTests();
});

describe("worker helpers", () => {
  test("IPv6 レート制限キーは /64 に丸める", () => {
    expect(rateLimitKey("192.0.2.10")).toBe("192.0.2.10");
    expect(rateLimitKey("2001:db8:abcd:1234:1111:2222:3333:4444")).toBe(
      "2001:db8:abcd:1234::",
    );
  });

  test("Cloudflare の国コードだけを転送用に読む", () => {
    const request = new Request("https://passkey.kantacky.com/api/v1/me");
    Object.defineProperty(request, "cf", { value: { country: "JP" } });

    expect(cloudflareCountry(request)).toBe("JP");
    expect(cloudflareCountry(new Request("https://passkey.kantacky.com"))).toBeNull();
  });

  test("RS256 JWT を署名できる", async () => {
    const { privateKeyPem, publicKey } = await generateRsaKeyPair();
    const jwt = await signJwt({ sub: "test" }, privateKeyPem);
    const [encodedHeader, encodedPayload, encodedSignature] = jwt.split(".");
    expect(JSON.parse(decodeBase64urlText(encodedHeader))).toEqual({
      alg: "RS256",
      typ: "JWT",
    });
    expect(JSON.parse(decodeBase64urlText(encodedPayload))).toEqual({
      sub: "test",
    });

    const verified = await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5",
      publicKey,
      decodeBase64urlBytes(encodedSignature).buffer as ArrayBuffer,
      new TextEncoder().encode(`${encodedHeader}.${encodedPayload}`),
    );
    expect(verified).toBe(true);
  });

  test("Google ID トークンは isolate 内でキャッシュする", async () => {
    const { privateKeyPem } = await generateRsaKeyPair();
    let calls = 0;
    globalThis.fetch = (async () => {
      calls += 1;
      return new Response(
        JSON.stringify({ id_token: "id-token", expires_in: 3600 }),
        {
          status: 200,
          headers: { "Content-Type": "application/json" },
        },
      );
    }) as unknown as typeof fetch;

    const key = JSON.stringify({
      client_email: "worker@example.iam.gserviceaccount.com",
      private_key: privateKeyPem,
    });
    const first = await getGoogleIdToken(
      key,
      "https://server.example",
      "https://token.test/token",
    );
    const second = await getGoogleIdToken(
      key,
      "https://server.example",
      "https://token.test/token",
    );

    expect(first).toBe("id-token");
    expect(second).toBe("id-token");
    expect(calls).toBe(1);
  });
});

async function generateRsaKeyPair(): Promise<{
  privateKeyPem: string;
  publicKey: CryptoKey;
}> {
  const pair = await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  );
  const pkcs8 = new Uint8Array(
    await crypto.subtle.exportKey("pkcs8", pair.privateKey),
  );
  return {
    privateKeyPem: pem("PRIVATE KEY", pkcs8),
    publicKey: pair.publicKey,
  };
}

function pem(label: string, bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  const base64 = btoa(binary);
  const lines = base64.match(/.{1,64}/g) ?? [];
  return `-----BEGIN ${label}-----\n${lines.join("\n")}\n-----END ${label}-----\n`;
}

function decodeBase64urlText(value: string): string {
  return new TextDecoder().decode(decodeBase64urlBytes(value));
}

function decodeBase64urlBytes(value: string): Uint8Array {
  const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
  const binary = atob(base64 + "=".repeat((4 - (base64.length % 4)) % 4));
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1)
    bytes[index] = binary.charCodeAt(index);
  return bytes;
}
