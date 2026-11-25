#!/usr/bin/env node
const { spawnSync } = require("node:child_process");
const { arch, argv, platform } = process;

const name = `@uidiff/${platform}-${arch}`;
const binary = platform === "win32" ? "uidiff.exe" : "uidiff";

function main() {
  let path;
  try {
    path = require.resolve(`${name}/${binary}`);
  } catch (error) {
    if (error.code !== "MODULE_NOT_FOUND") throw error;
    console.error(`uidiff: ${name} is unavailable. Use a supported platform and install optional dependencies.`);
    return 2;
  }

  const result = spawnSync(path, argv.slice(2), { stdio: "inherit" });
  if (result.error) {
    console.error(`uidiff: ${binary}: ${result.error.code}`);
    return 2;
  }
  return result.status ?? 2;
}

process.exitCode = main();
