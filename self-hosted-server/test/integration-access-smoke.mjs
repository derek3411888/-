// Shared by deployment smoke and isolated HTTP tests. Never submits a valid
// Codex request or migration change, and requires no real Access credential.
export async function verifyAnonymousPrivilegedAccess({ base, cookie, origin }) {
  const cases = [
    ["GET", "/api/v1/codex-support", {}, undefined, 401],
    ["POST", "/api/v1/codex-support", { Origin: origin, "X-Wuthering-CSRF": "1" }, { mode: "UNKNOWN", message: "must not be sent" }, 401],
    ["PUT", "/api/v1/admin/migration/mode", {}, { mode: "UNKNOWN" }, 401],
  ];
  for (const [method, route, headers, body, expected] of cases) {
    const response = await fetch(base + route, {
      method, headers: { Cookie: cookie, "Content-Type": "application/json", ...headers },
      body: body === undefined ? undefined : JSON.stringify(body), redirect: "manual",
    });
    await response.text();
    if (response.status !== expected) throw new Error(`${method} ${route}: expected ${expected}, got ${response.status}`);
  }
}
