export function allowInternalSmokeMutation(req, uid) {
  const address = String(req?.socket?.remoteAddress ?? "").toLowerCase();
  const isLoopback = address === "127.0.0.1" || address === "::1"
    || address === "::ffff:127.0.0.1";
  return isLoopback
    && String(req?.headers?.["x-wuthering-integration-smoke"] ?? "") === "1"
    && String(uid).startsWith("smoke-device-");
}
