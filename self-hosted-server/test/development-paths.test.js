import assert from "node:assert/strict";
import fsp from "node:fs/promises";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import {
  assertProjectPath,
  createNodeTestDirectory,
  devRuntimeRoot,
  projectRoot,
  serverRoot,
} from "./dev-runtime.js";

test("Node 開發產物根目錄固定在 repository 內", async () => {
  assert.equal(assertProjectPath(devRuntimeRoot), path.join(projectRoot, ".dev-runtime"));
  const fixture = await createNodeTestDirectory("path-policy");
  try {
    assert.ok(fixture.startsWith(`${path.resolve(projectRoot)}${path.sep}`));
    await fsp.writeFile(path.join(fixture, "evidence.txt"), "inside repository\n", "utf8");
    assert.equal(await fsp.readFile(path.join(fixture, "evidence.txt"), "utf8"), "inside repository\n");
  } finally {
    await fsp.rm(fixture, { recursive: true, force: true });
  }
  assert.throws(() => assertProjectPath(path.parse(projectRoot).root, "越界測試"), /專案資料夾外/);
});

test("直接執行 Node 伺服器時的資料預設值仍在 repository 內", async () => {
  process.env.SESSION_SECRET ||= "test-session-secret-abcdefghijklmnopqrstuvwxyz";
  process.env.CODEX_BRIDGE_TOKEN ||= "test-codex-bridge-token-abcdefghijklmnopqrstuvwxyz";
  process.env.LIVE_TOKEN_SECRET ||= "test-live-token-secret-abcdefghijklmnopqrstuvwxyz";
  process.env.LIVE_SRT_PASSPHRASE ||= "test-live-srt-passphrase-abcdefghijklm";
  delete process.env.MEDIA_ROOT;
  delete process.env.SNAPSHOT_ROOT;
  delete process.env.SERVER_LOG_ROOT;
  delete process.env.FORMAL_MEDIA_ENABLED;
  const { config } = await import("../src/config.js");
  assert.equal(config.formalMediaEnabled, false, "中央正式影片預設必須停用");
  for (const [label, candidate] of [
    ["mediaRoot", config.mediaRoot],
    ["snapshotRoot", config.snapshotRoot],
    ["serverLogRoot", config.serverLogRoot],
  ]) {
    assertProjectPath(candidate, label);
    assert.ok(candidate.startsWith(`${devRuntimeRoot}${path.sep}`), `${label} 未位於 .dev-runtime`);
  }
});

test("環境變數與 Compose 仍覆蓋為正式 /data 掛載", async () => {
  const overrideRoot = path.join(devRuntimeRoot, "node-tests", "config-override");
  const overrides = {
    MEDIA_ROOT: path.join(overrideRoot, "media"),
    SNAPSHOT_ROOT: path.join(overrideRoot, "snapshots"),
    SERVER_LOG_ROOT: path.join(overrideRoot, "logs"),
    FORMAL_MEDIA_ENABLED: "true",
  };
  const probe = spawnSync(process.execPath, [
    "--input-type=module",
    "--eval",
    "import { config } from './src/config.js'; console.log(JSON.stringify({mediaRoot:config.mediaRoot,snapshotRoot:config.snapshotRoot,serverLogRoot:config.serverLogRoot,formalMediaEnabled:config.formalMediaEnabled}));",
  ], {
    cwd: serverRoot,
    encoding: "utf8",
    shell: false,
    windowsHide: true,
    env: {
      ...process.env,
      ...overrides,
      SESSION_SECRET: "test-session-secret-abcdefghijklmnopqrstuvwxyz",
      CODEX_BRIDGE_TOKEN: "test-codex-bridge-token-abcdefghijklmnopqrstuvwxyz",
      LIVE_TOKEN_SECRET: "test-live-token-secret-abcdefghijklmnopqrstuvwxyz",
      LIVE_SRT_PASSPHRASE: "test-live-srt-passphrase-abcdefghijklm",
    },
  });
  assert.equal(probe.status, 0, `config env override probe 失敗：${probe.stderr}`);
  const resolved = JSON.parse(probe.stdout.trim());
  assert.deepEqual(resolved, {
    mediaRoot: path.resolve(overrides.MEDIA_ROOT),
    snapshotRoot: path.resolve(overrides.SNAPSHOT_ROOT),
    serverLogRoot: path.resolve(overrides.SERVER_LOG_ROOT),
    formalMediaEnabled: true,
  });

  const compose = await fsp.readFile(path.join(serverRoot, "compose.yml"), "utf8");
  assert.match(compose, /^\s+MEDIA_ROOT:\s*\/data\/media\s*$/m);
  assert.match(compose, /^\s+FORMAL_MEDIA_ENABLED:\s*\$\{FORMAL_MEDIA_ENABLED:-false\}\s*$/m);
  assert.match(compose, /^\s+SNAPSHOT_ROOT:\s*\/data\/snapshots\s*$/m);
  assert.match(compose, /^\s+SERVER_LOG_ROOT:\s*\/data\/logs\s*$/m);
  assert.match(compose, /^\s+source:\s*\$\{DATA_ROOT_HOST\}\s*$/m);
  assert.match(compose, /^\s+source:\s*\$\{BACKUP_ROOT_HOST\}\s*$/m);
});

test("npm 下載快取與診斷 Log 實際解析到 repository 內", () => {
  const npmCli = String(process.env.npm_execpath ?? "").trim();
  assert.ok(npmCli, "測試必須由 package.json 的 npm test 入口執行，才能驗證目前 npm 設定");
  for (const [setting, expected] of [
    ["cache", path.join(devRuntimeRoot, "npm-cache")],
    ["logs-dir", path.join(devRuntimeRoot, "npm-logs")],
  ]) {
    const result = spawnSync(process.execPath, [npmCli, "config", "get", setting], {
      cwd: serverRoot,
      encoding: "utf8",
      shell: false,
      windowsHide: true,
    });
    assert.equal(result.status, 0,
      `npm config get ${setting} 失敗：${result.error?.message ?? result.stderr ?? "unknown"}`);
    const actual = path.resolve(result.stdout.trim());
    assert.equal(actual, path.resolve(expected), `${setting} 未落在預期的 repository 路徑`);
    assertProjectPath(actual, `npm ${setting}`);
  }
});

test("Node 原始碼與測試不得直接使用作業系統暫存目錄", async () => {
  const roots = [path.join(serverRoot, "src"), path.join(serverRoot, "test")];
  const violations = [];
  async function scan(directory) {
    for (const entry of await fsp.readdir(directory, { withFileTypes: true })) {
      const candidate = path.join(directory, entry.name);
      if (entry.isDirectory()) {
        await scan(candidate);
      } else if (/\.(?:js|mjs)$/i.test(entry.name) && entry.name !== "development-paths.test.js") {
        const source = await fsp.readFile(candidate, "utf8");
        if (/\bos\s*\.\s*tmpdir\s*\(/.test(source)
            || /from\s+["']node:os["']/.test(source)
            || /["'`]\/tmp\//.test(source)) {
          violations.push(path.relative(serverRoot, candidate));
        }
      }
    }
  }
  for (const root of roots) await scan(root);
  assert.deepEqual(violations, [], `偵測到系統暫存路徑：${violations.join(", ")}`);
});
