import test from "node:test";
import assert from "node:assert/strict";
import { normalizePerformancePayload, normalizePerformanceRange, performanceRangeInterval } from "../src/performance.js";

test("performance telemetry accepts bounded minute aggregates and ignores unknown fields", () => {
  const now = 1_800_000_000_000;
  const payload = normalizePerformancePayload({
    collector: { state: "running", presentMon: "capturing", fpsAvailable: true, error: "" },
    current: { at: now, fps: 60.125, frameTimeMs: null, cpuTotalPct: 120, gpuPct: -5, unknown: 99, gameRunning: true },
    minutes: [{
      bucketStart: now - 60_000 + 321,
      sampleCount: 30,
      metrics: { fps: 59.4, fpsMin: 44.2, cpuTotalPct: 24.5, cpuTotalPctMax: 46, unknown: 123 },
    }],
  }, { currentStep: "鋤地", currentServer: "Asia", recording: { state: "recording" } }, now);

  assert.equal(payload.current.fps, 60.125);
  assert.equal(payload.current.cpuTotalPct, 100);
  assert.equal(payload.current.gpuPct, 0);
  assert.equal(payload.current.frameTimeMs, undefined);
  assert.equal(payload.current.unknown, undefined);
  assert.equal(payload.current.gameRunning, true);
  assert.equal(payload.minutes.length, 1);
  assert.equal(payload.minutes[0].bucketStart % 60_000, 0);
  assert.deepEqual(payload.minutes[0].context, {
    step: "鋤地", stepDetail: "", stepLevel: "", server: "Asia", recordingState: "recording", liveState: "",
  });
  assert.equal(payload.minutes[0].metrics.cpuTotalPctMax, 46);
  assert.equal(payload.minutes[0].metrics.unknown, undefined);
});

test("performance telemetry limits history and normalizes ranges", () => {
  const now = Date.now();
  const minutes = Array.from({ length: 15 }, (_, index) => ({
    bucketStart: now - (15 - index) * 60_000,
    sampleCount: 30,
    metrics: { fps: 30 + index },
  }));
  const payload = normalizePerformancePayload({ minutes }, {}, now);
  assert.equal(payload.minutes.length, 10);
  assert.equal(normalizePerformanceRange("24H"), "24h");
  assert.equal(normalizePerformanceRange("anything"), "6h");
  assert.equal(performanceRangeInterval("7d"), "7 days");
});

test("fresh healthy collector state clears a stale worker error", () => {
  const now = Date.now();
  const recovered = normalizePerformancePayload({
    collector: {
      state: "running", presentMon: "capturing", fpsAvailable: true,
      updatedAt: now, error: "old PresentMon failure that has already recovered",
    },
    current: { at: now, fps: 60 },
  }, {}, now);
  assert.equal(recovered.collector.error, "");

  const degraded = normalizePerformancePayload({
    collector: { state: "degraded", presentMon: "retry_wait", fpsAvailable: false, error: "active failure" },
  }, {}, now);
  assert.equal(degraded.collector.error, "active failure");
});
