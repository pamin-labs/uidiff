#!/usr/bin/env node
const { spawnSync } = require("node:child_process");
const { arch, argv, platform } = process;

const { uidiffNative } = require("./package.json");
const nativePlatform = `${platform}-${arch}`;

function main() {
  const name = uidiffNative?.[nativePlatform];
  if (typeof name !== "string") {
    console.error(`uidiff: unsupported platform ${nativePlatform}.`);
    return 2;
  }
  let path;
  try {
    path = require.resolve(`${name}/native`);
  } catch (error) {
    if (!(error instanceof Error) || !("code" in error) || error.code !== "MODULE_NOT_FOUND") throw error;
    console.error(`uidiff: ${name} is unavailable. Use a supported platform and install optional dependencies.`);
    return 2;
  }

  const result = spawnSync(path, argv.slice(2), { stdio: "inherit" });
  if (result.error) {
    console.error(`uidiff: ${name}: ${result.error.code}`);
    return 2;
  }
  return result.status ?? 2;
}

process.exitCode = main();
