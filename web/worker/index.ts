import { getGoogleIdToken } from "./google-auth";

export interface Env {
  CLOUD_RUN_URL: string;
  RP_ID: string;
  APPLE_TEAM_ID: string;
  GOOGLE_SERVICE_ACCOUNT_KEY: string;
  GOOGLE_TOKEN_URL?: string;
  API_RATE_LIMIT?: RateLimit;
  ASSETS?: Fetcher;
}

const SECURITY_HEADERS: Record<string, string> = {
  "Strict-Transport-Security": "max-age=63072000; includeSubDomains",
  "Content-Security-Policy":
    "default-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'; object-src 'none'",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
};

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/.well-known/apple-app-site-association") {
      return withSecurityHeaders(appleAppSiteAssociation(env));
    }

    if (url.pathname.startsWith("/api/")) {
      if (!url.pathname.startsWith("/api/v1/")) {
        return withSecurityHeaders(errorJson(404, "not_found", "Not found"));
      }
      try {
        return withSecurityHeaders(await proxyApi(request, env));
      } catch (error) {
        console.warn(
          "api proxy failed",
          error instanceof Error ? error.message : String(error),
        );
        return withSecurityHeaders(
          errorJson(
            502,
            "upstream_unavailable",
            "Upstream service unavailable",
          ),
        );
      }
    }

    if (url.pathname.startsWith("/.well-known/")) {
      return withSecurityHeaders(errorJson(404, "not_found", "Not found"));
    }

    if (env.ASSETS) return env.ASSETS.fetch(request);
    return withSecurityHeaders(errorJson(404, "not_found", "Not found"));
  },
};

function appleAppSiteAssociation(env: Env): Response {
  const body = {
    webcredentials: {
      apps: [`${env.APPLE_TEAM_ID}.com.kantacky.Passkey`],
    },
    applinks: {
      details: [
        {
          appIDs: [`${env.APPLE_TEAM_ID}.com.kantacky.Passkey`],
          components: [{ "/": "/app/verify" }],
        },
      ],
    },
  };
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "public, max-age=300",
    },
  });
}

async function proxyApi(request: Request, env: Env): Promise<Response> {
  const clientIp = request.headers.get("CF-Connecting-IP") ?? "unknown";
  const limited = await isRateLimited(env, clientIp);
  if (limited) {
    return errorJson(429, "rate_limited", "Too many requests", {
      "Retry-After": "60",
    });
  }

  const target = new URL(
    new URL(request.url).pathname + new URL(request.url).search,
    ensureTrailingSlash(env.CLOUD_RUN_URL),
  );
  const idToken = await getGoogleIdToken(
    env.GOOGLE_SERVICE_ACCOUNT_KEY,
    env.CLOUD_RUN_URL,
    env.GOOGLE_TOKEN_URL,
  );

  const headers = new Headers(request.headers);
  headers.delete("Host");
  headers.delete("X-Forwarded-For");
  headers.delete("X-Real-IP");
  headers.delete("X-Client-IP");
  headers.delete("CF-Connecting-IP");
  headers.delete("X-Serverless-Authorization");
  headers.set("X-Client-IP", clientIp);
  headers.set("X-Serverless-Authorization", `Bearer ${idToken}`);

  return fetch(target, {
    method: request.method,
    headers,
    body:
      request.method === "GET" || request.method === "HEAD"
        ? undefined
        : request.body,
    redirect: "manual",
  });
}

async function isRateLimited(env: Env, clientIp: string): Promise<boolean> {
  if (!env.API_RATE_LIMIT) return false;
  try {
    const outcome = await env.API_RATE_LIMIT.limit({
      key: rateLimitKey(clientIp),
    });
    return !outcome.success;
  } catch (error) {
    console.warn(
      "rate limiting unavailable",
      error instanceof Error ? error.message : String(error),
    );
    return false;
  }
}

export function rateLimitKey(clientIp: string): string {
  if (!clientIp.includes(":")) return clientIp;
  if (clientIp.includes(".")) return clientIp;
  const [leftPart, rightPart, extra] = clientIp.split("::");
  if (extra !== undefined) return clientIp;
  const left = leftPart ? leftPart.split(":") : [];
  const right = rightPart ? rightPart.split(":") : [];
  const missing = 8 - left.length - right.length;
  if (missing < 0) return clientIp;
  const groups =
    rightPart === undefined
      ? left
      : [...left, ...Array<string>(missing).fill("0"), ...right];
  if (groups.length !== 8) return clientIp;
  return `${groups.slice(0, 4).join(":")}::`;
}

function errorJson(
  status: number,
  code: string,
  message: string,
  headers: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify({ error: { code, message } }), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...headers,
    },
  });
}

function withSecurityHeaders(response: Response): Response {
  const secured = new Response(response.body, response);
  for (const [name, value] of Object.entries(SECURITY_HEADERS))
    secured.headers.set(name, value);
  return secured;
}

function ensureTrailingSlash(value: string): string {
  return value.endsWith("/") ? value : `${value}/`;
}
