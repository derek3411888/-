export const SUPPORTED_WUTHERING_SERVERS = Object.freeze([
  "America",
  "Europe",
  "Asia",
  "HMT(HK,MO,TW)",
  "SEA",
]);

function aliasKey(value) {
  return String(value ?? "")
    .trim()
    .toLocaleLowerCase("zh-TW")
    .replaceAll("（", "(")
    .replaceAll("）", ")")
    .replaceAll("，", ",")
    .replace(/[\s　_\-－—]/gu, "");
}

export function canonicalServerName(value) {
  const key = aliasKey(value);
  if (["america", "美洲", "美服", "美洲服"].includes(key)) return "America";
  if (["europe", "歐洲", "欧洲", "歐服", "欧服", "歐洲服", "欧洲服"].includes(key)) return "Europe";
  if (["asia", "亞洲", "亚洲", "亞服", "亚服", "亞洲服", "亚洲服"].includes(key)) return "Asia";
  if (["sea", "東南亞", "东南亚", "東南亞服", "东南亚服"].includes(key)) return "SEA";
  if (["hmt", "hmt(hk,mo,tw)", "hmt(hkmotw)", "hmt(hk/mo/tw)", "港澳台", "港澳台服"].includes(key)) {
    return "HMT(HK,MO,TW)";
  }
  return "";
}

export function splitServerSchedule(value) {
  if (Array.isArray(value)) return value.map((item) => String(item ?? "").trim()).filter(Boolean);
  const text = String(value ?? "").replaceAll("\r", "\n");
  const result = [];
  let token = "";
  let depth = 0;
  for (const character of text) {
    if (["(", "（"].includes(character)) depth += 1;
    if ([")", "）"].includes(character) && depth > 0) depth -= 1;
    if ([",", ";", "；", "|", "\n"].includes(character) && depth === 0) {
      if (token.trim()) result.push(token.trim());
      token = "";
    } else {
      token += character;
    }
  }
  if (token.trim()) result.push(token.trim());
  return result;
}

export function analyzeServerSchedule(value) {
  const servers = [];
  const invalid = [];
  const duplicates = [];
  const seen = new Set();
  for (const item of splitServerSchedule(value)) {
    const canonical = canonicalServerName(item);
    if (!canonical) {
      invalid.push(item);
      continue;
    }
    if (seen.has(canonical)) {
      if (!duplicates.includes(canonical)) duplicates.push(canonical);
      continue;
    }
    seen.add(canonical);
    servers.push(canonical);
  }
  return { servers, invalid, duplicates };
}
