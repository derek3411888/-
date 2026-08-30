import fsp from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const testRoot = path.dirname(fileURLToPath(import.meta.url));

export const serverRoot = path.resolve(testRoot, "..");
export const projectRoot = path.resolve(serverRoot, "..");
export const devRuntimeRoot = path.join(projectRoot, ".dev-runtime");
export const nodeTestRoot = path.join(devRuntimeRoot, "node-tests");

export function assertProjectPath(candidate, label = "開發產物") {
  const resolvedProject = path.resolve(projectRoot);
  const resolvedCandidate = path.resolve(candidate);
  if (resolvedCandidate !== resolvedProject
      && !resolvedCandidate.startsWith(`${resolvedProject}${path.sep}`)) {
    throw new Error(`${label}不得寫到專案資料夾外：${resolvedCandidate}`);
  }
  return resolvedCandidate;
}

export async function createNodeTestDirectory(prefix) {
  const parent = assertProjectPath(nodeTestRoot, "Node 測試根目錄");
  await fsp.mkdir(parent, { recursive: true });
  return fsp.mkdtemp(path.join(parent, `${prefix}-`));
}
