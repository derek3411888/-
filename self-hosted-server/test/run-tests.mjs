import { spawn } from "node:child_process";
import fsp from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { assertProjectPath, devRuntimeRoot, serverRoot } from "./dev-runtime.js";

const processTemp = assertProjectPath(path.join(devRuntimeRoot, "node-tests", "process-temp"), "Node 暫存目錄");
const replHistory = assertProjectPath(path.join(devRuntimeRoot, "node-repl-history"), "Node REPL 記錄");
const nodeCache = assertProjectPath(path.join(devRuntimeRoot, "node-cache"), "Node 快取目錄");
const v8Coverage = assertProjectPath(path.join(devRuntimeRoot, "node-coverage", "raw"), "V8 coverage 目錄");

await Promise.all([
  fsp.mkdir(processTemp, { recursive: true }),
  fsp.mkdir(nodeCache, { recursive: true }),
]);

const testNames = (await fsp.readdir(path.join(serverRoot, "test")))
  .filter((name) => name.endsWith(".test.js"))
  .sort()
  .map((name) => path.join("test", name));

const coverage = process.argv.slice(2).includes("--coverage");
const nodeArguments = ["--test"];
if (coverage) nodeArguments.push("--experimental-test-coverage");
nodeArguments.push(...testNames);

const environment = {
  ...process.env,
  TEMP: processTemp,
  TMP: processTemp,
  TMPDIR: processTemp,
  XDG_CACHE_HOME: nodeCache,
  NODE_REPL_HISTORY: replHistory,
};
// If a caller already requested raw V8 coverage, preserve that intent but force
// its output below the repository-owned development runtime directory.
if (process.env.NODE_V8_COVERAGE) {
  await fsp.mkdir(v8Coverage, { recursive: true });
  environment.NODE_V8_COVERAGE = v8Coverage;
}

const child = spawn(process.execPath, nodeArguments, {
  cwd: serverRoot,
  env: environment,
  shell: false,
  stdio: "inherit",
  windowsHide: true,
});

child.once("error", (error) => {
  console.error(error);
  process.exitCode = 1;
});
child.once("exit", (code, signal) => {
  if (signal) {
    console.error(`Node 測試被訊號中止：${signal}`);
    process.exitCode = 1;
    return;
  }
  process.exitCode = Number(code ?? 1);
});
