import { afterEach, describe, expect, test } from "bun:test";
import { ApiError, api } from "../lib/api";

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
});
