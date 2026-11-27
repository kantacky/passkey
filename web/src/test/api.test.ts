import { afterEach, describe, expect, test } from "bun:test";
import { ApiError, api } from "../lib/api";
import { fetchPasskeys } from "../queries/passkeys";
import { fetchSessions } from "../queries/sessions";

const originalFetch = globalThis.fetch;

afterEach(() => {
  globalThis.fetch = originalFetch;
});

describe("api", () => {
  test("JSON を same-origin credentials で送る", async () => {
    let requestUrl = "";
    let requestInit: RequestInit | undefined;
    globalThis.fetch = (async (
      input: string | URL | Request,
      init?: RequestInit,
    ) => {
      requestUrl = String(input);
      requestInit = init;
      return new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }) as unknown as typeof fetch;

    const result = await api<{ ok: boolean }>("/example", {
      method: "POST",
      body: { value: 1 },
    });

    expect(result).toEqual({ ok: true });
    expect(requestUrl).toBe("/api/v1/example");
    expect(requestInit?.credentials).toBe("same-origin");
    expect((requestInit?.headers as Headers).get("Content-Type")).toBe(
      "application/json",
    );
    expect(requestInit?.body).toBe('{"value":1}');
  });

  test("API エラーの code と Retry-After を保持する", async () => {
    globalThis.fetch = (async () =>
      new Response(
        JSON.stringify({
          error: { code: "rate_limited", message: "too many" },
        }),
        {
          status: 429,
          headers: { "Content-Type": "application/json", "Retry-After": "60" },
        },
      )) as unknown as typeof fetch;

    const failure = await api("/example").catch((error: unknown) => error);

    expect(failure).toBeInstanceOf(ApiError);
    expect((failure as ApiError).code).toBe("rate_limited");
    expect((failure as ApiError).retryAfter).toBe(60);
  });

  test("パスキー一覧はサーバーの envelope を展開する", async () => {
    globalThis.fetch = (async () =>
      new Response(
        JSON.stringify({
          passkeys: [
            {
              id: "AQID",
              name: "パスキー（2026/11/27）",
              customName: null,
              providerName: null,
              iconLight: null,
              iconDark: null,
              createdAt: "2026-11-27T12:00:00Z",
              lastUsedAt: null,
              backupEligible: true,
              backupState: true,
            },
          ],
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      )) as unknown as typeof fetch;

    const passkeys = await fetchPasskeys();

    expect(passkeys).toHaveLength(1);
    expect(passkeys[0].name).toBe("パスキー（2026/11/27）");
    expect(passkeys[0].customName).toBeNull();
  });

  test("セッション一覧は envelope と isCurrent を使う", async () => {
    globalThis.fetch = (async () =>
      new Response(
        JSON.stringify({
          sessions: [
            {
              id: "5F2E0451-0000-0000-0000-000000000000",
              deviceLabel: "Safari",
              createdAt: "2026-11-27T12:00:00Z",
              lastSeenAt: "2026-11-27T12:00:00Z",
              isCurrent: true,
            },
          ],
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      )) as unknown as typeof fetch;

    const sessions = await fetchSessions();

    expect(sessions).toHaveLength(1);
    expect(sessions[0].isCurrent).toBe(true);
  });
});
