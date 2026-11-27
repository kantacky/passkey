import { defineWranglerConfig } from "wrangler/experimental-config";

export default defineWranglerConfig({
  assetsDirectory: "./dist",
  minify: true,
  uploadSourceMaps: true,
  types: { generate: false },
});
