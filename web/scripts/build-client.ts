import { cp, rm } from "node:fs/promises";

await rm("dist", { recursive: true, force: true });

const build = Bun.spawnSync(
  [
    process.execPath,
    "build",
    "index.html",
    "--outdir",
    "dist",
    "--minify",
    "--target",
    "browser",
  ],
  {
    stdout: "inherit",
    stderr: "inherit",
  },
);
if (!build.success) process.exit(build.exitCode || 1);

await cp("public", "dist", { recursive: true });
