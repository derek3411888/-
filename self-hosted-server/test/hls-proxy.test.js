import assert from "node:assert/strict";
import test from "node:test";
import { discardFetchBody, withHeaderTimeout } from "../src/hls-proxy.js";

test("HLS header timeout is cleared before a successful response body is streamed", async () => {
  let observedSignal;
  const response = await withHeaderTimeout(async (signal) => {
    observedSignal = signal;
    return { ok: true };
  }, 10);

  assert.equal(response.ok, true);
  await new Promise((resolve) => setTimeout(resolve, 30));
  assert.equal(observedSignal.aborted, false);
});

test("HLS header timeout still aborts a request that never returns headers", async () => {
  await assert.rejects(
    withHeaderTimeout((signal) => new Promise((_resolve, reject) => {
      signal.addEventListener("abort", () => reject(signal.reason), { once: true });
    }), 10),
    (error) => error?.name === "TimeoutError",
  );
});

test("discarding a failed HLS response consumes cancellation errors", async () => {
  let cancelCalls = 0;
  await discardFetchBody({
    body: {
      async cancel() {
        cancelCalls += 1;
        throw new Error("already aborted");
      },
    },
  });
  assert.equal(cancelCalls, 1);
});
