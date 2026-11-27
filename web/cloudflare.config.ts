import { bindings, defineConfig } from "cf/config";

export default defineConfig({
  worker: {
    name: "passkey-web",
    compatibilityDate: "2026-11-27",
    entrypoint: "./worker/index.ts",
    domains: ["passkey.kantacky.com"],
    assets: {
      notFoundHandling: "single-page-application",
      runWorkerFirst: ["/api/*", "/.well-known/*"],
    },
    env: {
      ASSETS: bindings.assets(),
      API_RATE_LIMIT: bindings.rateLimit({
        namespace: "1001",
        simple: { limit: 60, period: 60 },
      }),
      CLOUD_RUN_URL: bindings.text("https://<cloud-run-service-url>"),
      RP_ID: bindings.text("passkey.kantacky.com"),
      APPLE_TEAM_ID: bindings.text("<APPLE_TEAM_ID>"),
      GOOGLE_SERVICE_ACCOUNT_KEY: bindings.secret(),
    },
  },
});
