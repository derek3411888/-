export async function withHeaderTimeout(operation, timeoutMs = 15_000) {
  if (typeof operation !== "function") throw new TypeError("operation must be a function");
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) throw new RangeError("timeoutMs must be positive");

  const controller = new AbortController();
  const timer = setTimeout(() => {
    controller.abort(new DOMException("The upstream response headers timed out", "TimeoutError"));
  }, timeoutMs);
  timer.unref?.();
  try {
    return await operation(controller.signal);
  } finally {
    // This timeout protects only the wait for upstream response headers. HLS
    // bodies can legitimately stay open for blocking playlist reloads; leaving
    // the signal armed after fetch() resolves can emit an unhandled stream
    // error and terminate the entire API container.
    clearTimeout(timer);
  }
}

export async function discardFetchBody(response) {
  try {
    await response?.body?.cancel();
  } catch {
    // The response is already being discarded. A failed cancellation must not
    // become an unhandled stream error or obscure the useful HTTP status.
  }
}
