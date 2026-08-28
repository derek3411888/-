function safeNonce(value) {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0) return 0;
  return parsed;
}

export function buildFallbackCommandBaseline({
  state,
  lastNonce,
  commandNonce,
  remoteNonce,
  remoteAckNonce,
  nowMs = Date.now(),
}) {
  const localFloor = Math.max(safeNonce(lastNonce), safeNonce(commandNonce));
  const cloudNonce = safeNonce(remoteNonce);
  const cloudAckNonce = safeNonce(remoteAckNonce);

  if (localFloor <= 0) return null;
  // A newer Firestore command must remain untouched so the device can consume it.
  if (cloudNonce > localFloor) return null;
  // Both sides already agree on a completed generation.
  if (cloudNonce === localFloor && cloudAckNonce >= localFloor) return null;

  const desiredState = String(state ?? "").trim().toUpperCase() === "PAUSE" ? "PAUSE" : "RUN";
  return {
    nonce: localFloor,
    desiredState,
    at: safeNonce(nowMs) || Date.now(),
  };
}
