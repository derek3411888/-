import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const read = (name) => fs.readFileSync(new URL(`../${name}`, import.meta.url), "utf8");
const compose = read("compose.yml");
test("optional tunnel uses a file secret and no published ports or privileged host access", () => {
  const block = compose.match(/^  cloudflared:\r?\n([\s\S]*?)(?=^  \w|^volumes:)/m)?.[1];
  assert.ok(block, "named tunnel connector is present");
  assert.match(block, /profiles: \["tunnel"\]/);
  assert.match(block, /cloudflare\/cloudflared:2026\.10\.7/);
  assert.match(block, /--token-file/);
  assert.match(block, /cloudflared_token/);
  assert.match(block, /read_only: true/);
  assert.match(block, /no-new-privileges:true/);
  assert.doesNotMatch(block, /\bports:|network_mode: host|docker\.sock|privileged: true|TUNNEL_TOKEN:|--token[", ]/);
});
test("origin settings support exact additional origins and fail-closed Codex Access configuration", () => {
  for (const name of ["ALLOWED_ORIGINS", "CLOUDFLARE_ACCESS_ISSUER", "CLOUDFLARE_ACCESS_AUDIENCE", "CODEX_ALLOWED_EMAILS", "CODEX_LOGIN_URL"]) {
    assert.match(compose, new RegExp(`${name}: \\$\\{${name}:-\\}`));
  }
  assert.match(compose, /PUBLIC_URL: \$\{PUBLIC_URL:-https:\/\/\$\{PUBLIC_IP_ADDRESS\}\}/);
});
test("tunnel and direct routes use the same guarded Caddy origin", () => {
  const caddy = read("Caddyfile");
  assert.match(caddy, /@internal path \/internal \/internal\/\*/);
  assert.match(caddy, /respond @internal 404/);
  assert.match(caddy, /http:\/\/:8080\s*\{\s*import control_site\s*\}/);
  assert.match(caddy, /\{\$DIRECT_HOSTNAME:\}/);
  assert.doesNotMatch(compose, /["']\d*:?8080:8080/);
});
test("connector secret is excluded from both Git and Docker context", () => {
  assert.match(read(".dockerignore"), /^secrets\/?$/m);
  const ignore = fs.readFileSync(new URL("../../.gitignore", import.meta.url), "utf8");
  assert.match(ignore, /^self-hosted-server\/secrets\//m);
});
