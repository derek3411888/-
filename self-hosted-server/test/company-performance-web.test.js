import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const readProjectFile = (relativePath) => readFileSync(
  new URL(`../../${relativePath}`, import.meta.url),
  "utf8",
);

test("company console exposes performance dashboard without another Firestore listener", () => {
  const html = readProjectFile("remote-control-web/index.html");
  const script = readProjectFile("remote-control-web/app.js");
  const styles = readProjectFile("remote-control-web/styles.css");

  for (const id of [
    "performanceTitle", "performanceNotice", "performanceFreshnessBadge",
    "perfFps", "perfCpu", "perfGpu", "perfRam",
    "perfFpsChart", "perfUsageChart", "perfFrameChart", "perfIoChart",
  ]) {
    assert.match(html, new RegExp(`id=["']${id}["']`), `missing company performance element ${id}`);
  }
  assert.match(html, /class="card recording-card recording-details"/);
  assert.doesNotMatch(html, /class="card recording-card recording-details"[^>]*\bopen\b/);
  assert.match(script, /readField\(data \|\| \{\}, "performanceJson"/);
  assert.match(script, /slice\(-60\)/);
  assert.match(script, /function renderPerformance\(/);
  assert.match(html, /app\.js\?v=20260829-support-recovery-v2/);
  assert.match(html, /styles\.css\?v=20260829-support-recovery-v2/);
  assert.match(script, /效能資料部分可用；遊戲 FPS 採集異常/);
  assert.doesNotMatch(script, /基礎效能監測正常；遊戲 FPS 採集異常/);
  assert.equal((script.match(/\bonSnapshot\s*\(/g) || []).length, 3,
    "performance must reuse the existing client listener instead of adding one");
  assert.match(styles, /\.performance-kpis\s*\{[^}]*repeat\(4,/s);
  assert.match(styles, /@media \(max-width: 700px\)[\s\S]*\.performance-kpis\s*\{[^}]*minmax\(0, 1fr\)/);
});

test("payload mirrors bounded performance JSON in the existing Firestore heartbeat", () => {
  const telemetry = readProjectFile("payload/PerformanceTelemetry.ahk");
  const worker = readProjectFile("payload/PerformanceTelemetryWorker.ps1");
  const firestore = readProjectFile("payload/RemoteControlFirestore.ahk");

  assert.match(telemetry, /PerformanceTelemetry_ReadFirestoreJson\(\)/);
  assert.match(telemetry, /size > 32768/);
  assert.match(worker, /while \(\$script:minuteHistory\.Count -gt 60\)/);
  assert.match(worker, /Get-Content -LiteralPath \$minutesPath -Tail 60/);
  assert.match(worker, /Write-AtomicUtf8 \$firestorePath/);
  assert.match(firestore, /performanceJson := PerformanceTelemetry_ReadFirestoreJson\(\)/);
  assert.match(firestore, /updateMask\.fieldPaths=performanceJson/);
  assert.match(firestore, /performanceStatusAvailable/);
});
