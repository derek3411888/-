import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const worker = readFileSync(
  new URL("../../payload/PerformanceTelemetryWorker.ps1", import.meta.url),
  "utf8",
);

test("PresentMon FPS collection uses a bounded asynchronous stdout pump", () => {
  assert.match(worker, /--output_stdout/);
  assert.doesNotMatch(worker, /--output_file/);
  assert.match(worker, /RedirectStandardOutput\s*=\s*\$true/);
  assert.match(worker, /WutheringPresentMonLinePump/);
  assert.match(worker, /maximumLines/);
  assert.doesNotMatch(worker, /IO\.FileStream\(\$script:presentCsv/);
});

test("collector cannot report running while an active FPS error exists", () => {
  assert.match(worker, /\$collectorState\s*=\s*if\s*\(\$lastCollectorError/);
  assert.match(worker, /'degraded'/);
  assert.match(worker, /state\s*=\s*\$collectorState/);
  assert.doesNotMatch(worker, /state\s*=\s*'running';\s*version/);
  assert.match(worker, /recordingProgress\s*=\s*Read-FfmpegProgress 'recording'/);
  assert.match(worker, /liveProgress\s*=\s*Read-FfmpegProgress 'live'/);
});

test("valid frames win over warnings and a stalled stream is restarted", () => {
  const validFramesBranch = worker.indexOf("if ($null -ne $fps.Fps)");
  const fatalStderrBranch = worker.indexOf("Test-PresentMonFatalMessage $presentError");
  assert.ok(validFramesBranch >= 0 && fatalStderrBranch > validFramesBranch);
  assert.match(worker, /lastPresentFrameAt\s*=\s*\$sampleStarted/);
  assert.match(worker, /TotalSeconds\s*-ge\s*30/);
  assert.match(worker, /30 秒未收到有效 FrameTime/);
  assert.match(worker, /Stop-PresentMon\s*\r?\n\s*\$presentMonState\s*=\s*'retry_wait'/);
});

test("worker startup and recovered frames actively clear an earlier error", () => {
  assert.match(worker, /\$startupCollector\s*=\s*\[ordered\]@\{[\s\S]*?error\s*=\s*''/);
  assert.match(worker, /Write-AtomicUtf8\s+\$heartbeatPath[\s\S]*?\$startupCollector/);
  assert.match(worker, /Remove-Item\s+-LiteralPath\s+\(Join-Path\s+\$OutputRoot\s+'collector_error\.log'\)/);
  assert.match(worker, /if\s*\(\$null\s+-ne\s+\$fps\.Fps\)\s*\{[\s\S]*?\$lastCollectorError\s*=\s*''[\s\S]*?\$presentMonState\s*=\s*'capturing'/);
});

test("a single FPS sample stays an array and FPS errors do not erase other metrics", () => {
  assert.match(worker, /\$values\s*=\s*\[double\[\]\]@\(\$Frames\)/);
  assert.doesNotMatch(worker, /\$values\s*=\s*\[double\[\]\]\$Frames\.ToArray\(\)/);
  assert.match(worker, /try\s*\{\s*\$fps\s*=\s*Get-FpsMetrics/);
  assert.match(worker, /PresentMon FPS:/);
  assert.match(worker, /\$fps\s*=\s*\[pscustomobject\]@\{\s*Fps\s*=\s*\$null/);
});
