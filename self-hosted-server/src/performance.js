import { boundedText, integer } from "./utils.js";

const metricBounds = {
  fps: [0, 1000], fps1Low: [0, 1000], fpsMin: [0, 1000],
  frameTimeMs: [0, 10_000], frameTimeP95Ms: [0, 10_000], frameTimeP99Ms: [0, 10_000],
  cpuTotalPct: [0, 100], cpuGamePct: [0, 100], cpuOkwwPct: [0, 100], cpuLrmcPct: [0, 100], cpuFfmpegPct: [0, 100],
  gpuPct: [0, 100], gpuVramMb: [0, 1_000_000], gpuTempC: [0, 200], gpuPowerW: [0, 5_000], gpuEncoderPct: [0, 100],
  ramUsedGb: [0, 10_000], ramTotalGb: [0, 10_000], gameRamMb: [0, 1_000_000], okwwRamMb: [0, 1_000_000],
  lrmcRamMb: [0, 1_000_000], ffmpegRamMb: [0, 1_000_000], diskReadMbps: [0, 100_000], diskWriteMbps: [0, 100_000],
  diskFreeGb: [0, 1_000_000], diskFreeGbMin: [0, 1_000_000], networkDownMbps: [0, 100_000], networkUpMbps: [0, 100_000],
  recordingFps: [0, 1000], recordingDroppedFrames: [0, 1e12], recordingDuplicatedFrames: [0, 1e12],
  liveFps: [0, 1000], liveDroppedFrames: [0, 1e12], liveDuplicatedFrames: [0, 1e12],
};

for (const [name, bounds] of Object.entries({ ...metricBounds })) {
  if (/(Pct|TempC|PowerW|Mbps|RamMb|UsedGb)$/.test(name)) metricBounds[`${name}Max`] = bounds;
}
Object.freeze(metricBounds);

function finite(value, minimum, maximum) {
  if (value === null || value === undefined || value === "") return null;
  const number = Number(value);
  if (!Number.isFinite(number)) return null;
  return Math.round(Math.max(minimum, Math.min(maximum, number)) * 1000) / 1000;
}

function normalizeMetrics(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  const output = {};
  for (const [name, bounds] of Object.entries(metricBounds)) {
    const number = finite(value[name], bounds[0], bounds[1]);
    if (number !== null) output[name] = number;
  }
  return output;
}

function normalizeCurrent(value, now) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const at = integer(value.at, now, now - 48 * 60 * 60_000, now + 5 * 60_000);
  const metrics = normalizeMetrics(value);
  return {
    at,
    ...metrics,
    recordingActive: Boolean(value.recordingActive),
    recordingSpeed: boundedText(value.recordingSpeed, 40),
    liveActive: Boolean(value.liveActive),
    liveSpeed: boundedText(value.liveSpeed, 40),
    gameRunning: Boolean(value.gameRunning),
    okwwRunning: Boolean(value.okwwRunning),
    lrmcRunning: Boolean(value.lrmcRunning),
    ffmpegCount: integer(value.ffmpegCount, 0, 0, 100),
  };
}

function normalizeCollector(value, now) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return {
    state: boundedText(value.state, 40) || "unknown",
    version: integer(value.version, 1, 1, 100),
    updatedAt: integer(value.updatedAt, now, now - 48 * 60 * 60_000, now + 5 * 60_000),
    sampleIntervalSec: integer(value.sampleIntervalSec, 2, 1, 60),
    presentMon: boundedText(value.presentMon, 80),
    presentMonVersion: boundedText(value.presentMonVersion, 40),
    fpsAvailable: Boolean(value.fpsAvailable),
    nvidiaTelemetry: Boolean(value.nvidiaTelemetry),
    error: boundedText(value.error, 500),
  };
}

function performanceContext(status) {
  const recording = status?.recording && typeof status.recording === "object" ? status.recording : {};
  const live = status?.live && typeof status.live === "object" ? status.live : {};
  return {
    step: boundedText(status?.currentStep, 200),
    stepDetail: boundedText(status?.currentStepDetail, 600),
    stepLevel: boundedText(status?.currentStepLevel, 20),
    server: boundedText(status?.currentServer, 160),
    recordingState: boundedText(recording.state, 80),
    liveState: boundedText(live.state, 80),
  };
}

export function normalizePerformancePayload(value, status = {}, now = Date.now()) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const collector = normalizeCollector(value.collector, now);
  const current = normalizeCurrent(value.current, now);
  const context = performanceContext(status);
  const minutes = [];
  const seen = new Set();
  for (const item of (Array.isArray(value.minutes) ? value.minutes.slice(-10) : [])) {
    if (!item || typeof item !== "object") continue;
    const raw = integer(item.bucketStart, 0, now - 48 * 60 * 60_000, now + 5 * 60_000);
    if (!raw) continue;
    const bucketStart = Math.floor(raw / 60_000) * 60_000;
    if (seen.has(bucketStart)) continue;
    seen.add(bucketStart);
    const metrics = normalizeMetrics(item.metrics);
    if (!Object.keys(metrics).length) continue;
    minutes.push({
      bucketStart,
      sampleCount: integer(item.sampleCount, 0, 0, 3600),
      metrics,
      context,
      collector,
    });
  }
  return { collector, current, minutes };
}

const ranges = Object.freeze({
  "15m": "15 minutes",
  "1h": "1 hour",
  "6h": "6 hours",
  "24h": "24 hours",
  "7d": "7 days",
  "14d": "14 days",
});

export function normalizePerformanceRange(value) {
  const key = String(value || "6h").toLowerCase();
  return Object.hasOwn(ranges, key) ? key : "6h";
}

export function performanceRangeInterval(value) {
  return ranges[normalizePerformanceRange(value)];
}
