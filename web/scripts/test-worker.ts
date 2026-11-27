import { spawn } from "node:child_process";
import { generateKeyPairSync } from "node:crypto";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const testDir = await mkdtemp(join(tmpdir(), "passkey-workerd-"));
let workerd: ReturnType<typeof spawn> | null = null;
let upstream: ReturnType<typeof Bun.serve> | null = null;
let tokenServer: ReturnType<typeof Bun.serve> | null = null;
let workerdOutput = "";
let passed = false;

try {
  await mkdir(".workerd-test", { recursive: true });
  const build = await Bun.build({
    entrypoints: ["worker/index.ts"],
    outdir: ".workerd-test",
    target: "browser",
    format: "esm",
    minify: false,
  });
  if (!build.success) throw new Error("worker bundle failed");

  const upstreamRequests: Array<{
    url: string;
    method: string;
    headers: Record<string, string>;
    body: string;
  }> = [];
  upstream = Bun.serve({
    port: 0,
    async fetch(request) {
      upstreamRequests.push({
        url: request.url,
        method: request.method,
        headers: Object.fromEntries(request.headers.entries()),
        body: await request.text(),
      });
      return Response.json({ upstream: true }, { status: 200 });
    },
  });

  let tokenCalls = 0;
  tokenServer = Bun.serve({
    port: 0,
    fetch() {
      tokenCalls += 1;
      return Response.json({
        id_token: "test-google-id-token",
        expires_in: 3600,
      });
    },
  });

  const privateKey = generateKeyPairSync("rsa", { modulusLength: 2048 })
    .privateKey.export({ type: "pkcs8", format: "pem" })
    .toString();
  const serviceAccount = JSON.stringify({
    client_email: "worker@example.iam.gserviceaccount.com",
    private_key: privateKey,
  });
  const cloudRunUrl = `http://127.0.0.1:${upstream.port}`;
  const workerPort = 18000 + Math.floor(Math.random() * 2000);
  const text = (value: string) => JSON.stringify(value);
  const config = `using Workerd = import "/workerd/workerd.capnp";

const config :Workerd.Config = (
  services = [
    (
      name = "passkey-web-test",
      worker = (
        modules = [(name = "worker", esModule = embed "index.js")],
        compatibilityDate = "2026-11-27",
        globalOutbound = "localNetwork",
        bindings = [
          (name = "CLOUD_RUN_URL", text = ${text(cloudRunUrl)}),
          (name = "RP_ID", text = "passkey.kantacky.com"),
          (name = "APPLE_TEAM_ID", text = "TESTTEAMID"),
          (name = "GOOGLE_SERVICE_ACCOUNT_KEY", text = ${text(serviceAccount)}),
          (name = "GOOGLE_TOKEN_URL", text = ${text(`http://127.0.0.1:${tokenServer.port}/token`)}),
        ],
      ),
    ),
    (name = "localNetwork", network = (allow = ["public", "private", "local"])),
  ],
  sockets = [(name = "http", address = "127.0.0.1:${workerPort}", http = (), service = "passkey-web-test")],
);
`;
  const configPath = join(process.cwd(), ".workerd-test/config.capnp");
  await writeFile(configPath, config);

  workerd = spawn(
    join(process.cwd(), "node_modules/workerd/bin/workerd"),
    ["serve", configPath],
    {
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  workerd.stdout?.on("data", (chunk) => {
    workerdOutput += chunk;
  });
  workerd.stderr?.on("data", (chunk) => {
    workerdOutput += chunk;
  });

  const base = `http://127.0.0.1:${workerPort}`;
  await waitForWorker(base, workerdOutput);

  const proxied = await fetch(`${base}/api/v1/example?x=1`, {
    headers: {
      "CF-Connecting-IP": "198.51.100.24",
      "X-Forwarded-For": "203.0.113.1",
      "X-Real-IP": "203.0.113.1",
      "X-Client-IP": "203.0.113.1",
      "X-Serverless-Authorization": "Bearer attacker-controlled",
      Cookie: "__Host-session=session-cookie",
      Authorization: "Bearer user-token",
      Origin: "https://passkey.kantacky.com",
      "User-Agent": "workerd-test",
    },
  });
  if (proxied.status !== 200)
    throw new Error(`proxy status ${proxied.status}: ${await proxied.text()}`);
  assert(
    proxied.headers.get("strict-transport-security") ===
      "max-age=63072000; includeSubDomains",
    "missing HSTS on proxy response",
  );
  assert(upstreamRequests.length === 1, "upstream was not called");
  const upstreamRequest = upstreamRequests[0];
  assert(
    new URL(upstreamRequest.url).pathname === "/api/v1/example",
    `upstream path ${upstreamRequest.url}`,
  );
  assert(
    new URL(upstreamRequest.url).search === "?x=1",
    "upstream query was not preserved",
  );
  assert(
    upstreamRequest.headers["x-client-ip"] === "198.51.100.24",
    "X-Client-IP was not set from CF-Connecting-IP",
  );
  assert(
    upstreamRequest.headers["x-forwarded-for"] === undefined,
    "X-Forwarded-For was forwarded",
  );
  assert(
    upstreamRequest.headers["x-real-ip"] === undefined,
    "X-Real-IP was forwarded",
  );
  assert(
    upstreamRequest.headers["cf-connecting-ip"] === undefined,
    "CF-Connecting-IP was forwarded",
  );
  assert(
    upstreamRequest.headers["x-serverless-authorization"] ===
      "Bearer test-google-id-token",
    "ID token header mismatch",
  );
  assert(
    upstreamRequest.headers.cookie === "__Host-session=session-cookie",
    "Cookie was not forwarded",
  );
  assert(
    upstreamRequest.headers.authorization === "Bearer user-token",
    "Authorization was not forwarded",
  );
  assert(
    upstreamRequest.headers.origin === "https://passkey.kantacky.com",
    "Origin was not forwarded",
  );
  assert(
    upstreamRequest.headers["user-agent"] === "workerd-test",
    "User-Agent was not forwarded",
  );

  await fetch(`${base}/api/v1/example`, {
    headers: { "CF-Connecting-IP": "198.51.100.24" },
  });
  assert(
    tokenCalls === 1,
    `ID token was not cached (token endpoint calls: ${tokenCalls})`,
  );

  const unknown = await fetch(`${base}/api/unknown`);
  assert(unknown.status === 404, `unknown API status ${unknown.status}`);
  const unknownBody = (await unknown.json()) as { error: { code: string } };
  assert(
    unknownBody.error.code === "not_found",
    "unknown API did not return error JSON",
  );

  const aasa = await fetch(`${base}/.well-known/apple-app-site-association`);
  assert(aasa.status === 200, `AASA status ${aasa.status}`);
  assert(
    aasa.headers.get("content-type")?.startsWith("application/json") === true,
    `AASA Content-Type ${aasa.headers.get("content-type")}`,
  );
  const aasaBody = (await aasa.json()) as {
    webcredentials: { apps: string[] };
    applinks: { details: Array<{ components: Array<Record<string, string>> }> };
  };
  assert(
    aasaBody.webcredentials.apps[0] === "TESTTEAMID.com.kantacky.Passkey",
    "AASA webcredentials app ID mismatch",
  );
  assert(
    aasaBody.applinks.details[0].components[0]["/"] === "/app/verify",
    "AASA applinks path mismatch",
  );
  assert(
    aasa.headers
      .get("content-security-policy")
      ?.includes("default-src 'self'") === true,
    "missing CSP on AASA",
  );

  passed = true;
  console.log("workerd integration tests passed");
} finally {
  workerd?.kill();
  upstream?.stop(true);
  tokenServer?.stop(true);
  await rm(testDir, { recursive: true, force: true });
  if (!passed && workerdOutput.trim())
    console.error(`workerd output:\n${workerdOutput}`);
}

async function waitForWorker(base: string, output: string): Promise<void> {
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    try {
      await fetch(`${base}/.well-known/apple-app-site-association`);
      return;
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }
  throw new Error(`workerd did not start: ${output}`);
}

function assert(condition: boolean, message: string): asserts condition {
  if (!condition) throw new Error(message);
}
