import { describe, expect, test } from "bun:test";
import {
  classifyWebAuthnError,
  decodeBase64url,
  encodeBase64url,
  parseCreationOptions,
  parseRequestOptions,
  webAuthnErrorMessage,
} from "../lib/webauthn";

class TestPublicKeyCredential {}
Object.defineProperty(window, "PublicKeyCredential", {
  value: TestPublicKeyCredential,
  configurable: true,
});

describe("webauthn utilities", () => {
  test("base64url を往復変換できる", () => {
    const bytes = new Uint8Array([0, 1, 2, 250, 251, 252]);
    const encoded = encodeBase64url(bytes);
    expect(encoded).not.toContain("+");
    expect(encoded).not.toContain("/");
    expect(encoded).not.toContain("=");
    expect(new Uint8Array(decodeBase64url(encoded))).toEqual(bytes);
  });

  test("登録オプションの challenge/user.id/excludeCredentials を変換する", () => {
    const options = parseCreationOptions({
      challenge: "AQID",
      user: {
        id: "BAUG",
        name: "user@example.com",
        displayName: "user@example.com",
      },
      excludeCredentials: [{ type: "public-key", id: "BwgJ" }],
    });

    expect(new Uint8Array(options.challenge as ArrayBuffer)).toEqual(
      new Uint8Array([1, 2, 3]),
    );
    expect(new Uint8Array(options.user.id as ArrayBuffer)).toEqual(
      new Uint8Array([4, 5, 6]),
    );
    expect(
      new Uint8Array(options.excludeCredentials?.[0].id as ArrayBuffer),
    ).toEqual(new Uint8Array([7, 8, 9]));
  });

  test("認証オプションの challenge/allowCredentials を変換する", () => {
    const options = parseRequestOptions({
      challenge: "AQID",
      allowCredentials: [{ type: "public-key", id: "BAUG" }],
    });

    expect(new Uint8Array(options.challenge as ArrayBuffer)).toEqual(
      new Uint8Array([1, 2, 3]),
    );
    expect(
      new Uint8Array(options.allowCredentials?.[0].id as ArrayBuffer),
    ).toEqual(new Uint8Array([4, 5, 6]));
  });

  test("WebAuthn エラーを設計書の文言に分類する", () => {
    expect(
      classifyWebAuthnError(new DOMException("cancel", "NotAllowedError")),
    ).toBe("cancelled");
    expect(
      classifyWebAuthnError(new DOMException("duplicate", "InvalidStateError")),
    ).toBe("already_registered");
    expect(webAuthnErrorMessage("cancelled", "create").title).toBe(
      "パスキーの作成を中止しました",
    );
    expect(
      webAuthnErrorMessage("already_registered", "create").description,
    ).toContain("サインインできます");
    expect(webAuthnErrorMessage("uv_unavailable", "create").title).toBe(
      "画面ロックが必要です",
    );
  });
});
