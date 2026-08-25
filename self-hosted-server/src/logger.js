import fs from "node:fs";
import path from "node:path";
import util from "node:util";

let installed = false;

function dayKey(date) {
  return date.toISOString().slice(0, 10);
}

function formatArgument(value) {
  if (value instanceof Error) return value.stack || value.message;
  if (typeof value === "string") return value;
  return util.inspect(value, { depth: 6, breakLength: 180, maxArrayLength: 100 });
}

export function installFileLogger(logRoot, { maxBytes = 10 * 1024 * 1024, keep = 15 } = {}) {
  if (installed) return;
  fs.mkdirSync(logRoot, { recursive: true });
  const activePath = path.join(logRoot, "server.log");

  const prune = () => {
    const archives = fs.readdirSync(logRoot)
      .filter((name) => /^server\.\d{8}T\d{9}Z\.log$/.test(name))
      .sort()
      .reverse();
    for (const name of archives.slice(keep)) fs.rmSync(path.join(logRoot, name), { force: true });
  };

  const rotateIfNeeded = () => {
    let stat;
    try { stat = fs.statSync(activePath); } catch { return; }
    if (!stat.size) return;
    if (stat.size < maxBytes && dayKey(stat.mtime) === dayKey(new Date())) return;
    const stamp = new Date().toISOString().replace(/[-:.]/g, "").replace("Z", "Z");
    fs.renameSync(activePath, path.join(logRoot, `server.${stamp}.log`));
    prune();
  };

  const originals = {
    log: console.log.bind(console),
    warn: console.warn.bind(console),
    error: console.error.bind(console),
  };
  for (const level of Object.keys(originals)) {
    console[level] = (...args) => {
      originals[level](...args);
      try {
        rotateIfNeeded();
        const line = `${new Date().toISOString()} ${level.toUpperCase()} ${args.map(formatArgument).join(" ")}\n`;
        fs.appendFileSync(activePath, line, "utf8");
      } catch (error) {
        originals.error("File logger failed", error);
      }
    };
  }
  installed = true;
  console.log(`File log enabled: ${activePath}; rotated copies=${keep}`);
}
