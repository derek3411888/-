import assert from "node:assert/strict";
import test from "node:test";
import {
  SUPPORTED_WUTHERING_SERVERS,
  analyzeServerSchedule,
  canonicalServerName,
} from "../src/server-names.js";

test("official Global server choices stay canonical", () => {
  assert.deepEqual(SUPPORTED_WUTHERING_SERVERS, ["America", "Europe", "Asia", "HMT(HK,MO,TW)", "SEA"]);
  assert.equal(canonicalServerName("HMT(HK, MO, TW)"), "HMT(HK,MO,TW)");
  assert.equal(canonicalServerName("亞洲"), "Asia");
});

test("schedule parser preserves HMT commas and reports duplicates and invalid values", () => {
  assert.deepEqual(analyzeServerSchedule("HMT(HK, MO, TW), Asia | SEA").servers, ["HMT(HK,MO,TW)", "Asia", "SEA"]);
  assert.deepEqual(analyzeServerSchedule("Asia | 亞洲").duplicates, ["Asia"]);
  assert.deepEqual(analyzeServerSchedule("Asia | unknown").invalid, ["unknown"]);
});
