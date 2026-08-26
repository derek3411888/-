import crypto from "node:crypto";
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import { spawn } from "node:child_process";
import { pipeline } from "node:stream/promises";
import { config, assertChildPath } from "./config.js";
import { query, withTransaction } from "./db.js";
import { HttpError, boundedText, integer } from "./utils.js";

const activeJobs = new Set();
const AUTO_RETRY_LIMIT = 3;
const SEGMENT_ERROR_RETRY_MS = 2 * 60_000;
const SEGMENT_PROCESSING_STALE_MS = 10 * 60_000;
const SESSION_ERROR_RETRY_MS = 2 * 60_000;
const SESSION_MERGING_STALE_MS = 30 * 60_000;

export function mediaAutoRetryEligible(kind, state, retryCount, updatedAtMs, nowMs = Date.now()) {
  const attempts = Math.max(0, Number(retryCount) || 0);
  const updated = Number(updatedAtMs) || 0;
  if (attempts >= AUTO_RETRY_LIMIT || updated <= 0 || nowMs < updated) return false;
  const age = nowMs - updated;
  if (kind === "segment") {
    if (state === "ERROR") return age >= SEGMENT_ERROR_RETRY_MS;
    if (state === "PROCESSING") return age >= SEGMENT_PROCESSING_STALE_MS;
    return state === "UPLOADED";
  }
  if (kind === "session") {
    if (state === "ERROR") return age >= SESSION_ERROR_RETRY_MS;
    if (state === "MERGING") return age >= SESSION_MERGING_STALE_MS;
    return state === "FINALIZE_PENDING";
  }
  return false;
}

function relativeToMedia(absolutePath) {
  return path.relative(config.mediaRoot, assertChildPath(config.mediaRoot, absolutePath)).split(path.sep).join("/");
}

function absoluteFromMedia(relativePath) {
  if (!relativePath || path.isAbsolute(relativePath)) throw new HttpError(500, "媒體索引路徑無效", "INVALID_MEDIA_PATH");
  return assertChildPath(config.mediaRoot, path.join(config.mediaRoot, relativePath));
}

function safeSessionDirectory(uid, sessionId) {
  return assertChildPath(config.mediaRoot, path.join(config.mediaRoot, uid, sessionId));
}

async function hashFile(filePath) {
  const hash = crypto.createHash("sha256");
  const stream = fs.createReadStream(filePath);
  for await (const chunk of stream) hash.update(chunk);
  return hash.digest("hex");
}

function runTool(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { windowsHide: true, stdio: ["ignore", "ignore", "pipe"] });
    let stderr = "";
    child.stderr.on("data", (chunk) => { stderr = `${stderr}${chunk}`.slice(-16_000); });
    child.once("error", reject);
    child.once("close", (code) => code === 0 ? resolve(stderr) : reject(new Error(`${command} exit=${code}: ${stderr}`)));
  });
}

function parseFfmpegTimestamp(value) {
  const match = /^(\d+):(\d+):(\d+(?:\.\d+)?)$/.exec(String(value ?? "").trim());
  if (!match) return 0;
  return Number(match[1]) * 3600 + Number(match[2]) * 60 + Number(match[3]);
}

function runToolWithProgress(command, args, onProgress) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, ["-progress", "pipe:1", "-nostats", ...args], {
      windowsHide: true, stdio: ["ignore", "pipe", "pipe"],
    });
    let stderr = "";
    let stdout = "";
    child.stderr.on("data", (chunk) => { stderr = `${stderr}${chunk}`.slice(-16_000); });
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString("utf8");
      const lines = stdout.split(/\r?\n/);
      stdout = lines.pop() ?? "";
      for (const line of lines) {
        const separator = line.indexOf("=");
        if (separator < 1) continue;
        if (line.slice(0, separator) === "out_time") onProgress(parseFfmpegTimestamp(line.slice(separator + 1)));
      }
    });
    child.once("error", reject);
    child.once("close", (code) => code === 0 ? resolve(stderr) : reject(new Error(`${command} exit=${code}: ${stderr}`)));
  });
}

function safeExpectedBytes(value) {
  const bytes = Number(value);
  return Number.isSafeInteger(bytes) && bytes > 0 ? bytes : null;
}

async function probeVideo(filePath) {
  const child = spawn("ffprobe", [
    "-v", "error", "-print_format", "json", "-show_format", "-show_streams", filePath,
  ], { windowsHide: true, stdio: ["ignore", "pipe", "pipe"] });
  const stdout = [];
  const stderr = [];
  child.stdout.on("data", (chunk) => stdout.push(chunk));
  child.stderr.on("data", (chunk) => stderr.push(chunk));
  const code = await new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("close", resolve);
  });
  if (code !== 0) throw new Error(`ffprobe exit=${code}: ${Buffer.concat(stderr).toString("utf8").slice(-2000)}`);
  const parsed = JSON.parse(Buffer.concat(stdout).toString("utf8"));
  if (!parsed.streams?.some((stream) => stream.codec_type === "video")) throw new Error("影片沒有可用視訊串流");
  const duration = Number.parseFloat(parsed.format?.duration ?? "0");
  if (!(duration > 0)) throw new Error("影片時間長度無效");
  return { duration, streams: parsed.streams };
}

async function hasMediaCapacity() {
  try {
    const stat = await fsp.statfs(config.mediaRoot, { bigint: true });
    return stat.bavail * stat.bsize >= config.minFreeBytes;
  } catch {
    return true;
  }
}

export async function ensureMediaRoots() {
  await Promise.all([
    fsp.mkdir(config.mediaRoot, { recursive: true }),
    fsp.mkdir(config.snapshotRoot, { recursive: true }),
    fsp.mkdir(config.serverLogRoot, { recursive: true }),
  ]);
}

export async function upsertRecordingSession(uid, body) {
  const clientSessionId = boundedText(body.clientSessionId, 160);
  const baseName = boundedText(body.baseName, 160);
  if (!/^wuthering_auto_recording_\d{8}_\d{6}(?:_\d+)?$/.test(clientSessionId)) {
    throw new HttpError(400, "錄影工作階段 ID 無效", "INVALID_RECORDING_SESSION");
  }
  if (!/^wuthering_auto_recording_\d{8}_\d{6}$/.test(baseName)) {
    throw new HttpError(400, "錄影檔名無效", "INVALID_RECORDING_NAME");
  }
  const startedAt = body.startedAt ? new Date(body.startedAt) : null;
  const expectedSegments = body.expectedSegments == null
    ? null : integer(body.expectedSegments, -1, 1, 100_000);
  const expectedBytes = safeExpectedBytes(body.expectedBytes);
  if (body.expectedSegments != null && expectedSegments < 1) {
    throw new HttpError(400, "完整片段數量無效", "INVALID_SEGMENT_COUNT");
  }
  if (body.expectedBytes != null && expectedBytes == null) {
    throw new HttpError(400, "完整影片位元組數無效", "INVALID_EXPECTED_BYTES");
  }
  const result = await query(
    `INSERT INTO recording_sessions(uid,client_session_id,base_name,started_at,state,
       expected_segments,expected_bytes,progress_stage,progress_percent,progress_total,progress_updated_at)
     VALUES($1,$2,$3,$4,'UPLOADING',$5,$6::bigint,'DEVICE_UPLOAD',
       CASE WHEN $6::bigint IS NULL THEN NULL ELSE 0 END,COALESCE($6::bigint,0),now())
     ON CONFLICT(uid,client_session_id) DO UPDATE SET
       expected_segments=COALESCE(EXCLUDED.expected_segments,recording_sessions.expected_segments),
       expected_bytes=COALESCE(EXCLUDED.expected_bytes,recording_sessions.expected_bytes),
       progress_stage=CASE WHEN EXCLUDED.expected_segments IS NULL
         THEN recording_sessions.progress_stage ELSE 'DEVICE_UPLOAD' END,
       progress_total=GREATEST(recording_sessions.progress_total,COALESCE(EXCLUDED.expected_bytes,0)),
       progress_updated_at=now(),updated_at=now()
     RETURNING id,uid,client_session_id,base_name,state,expected_segments,expected_bytes,
       progress_stage,progress_percent,created_at,updated_at`,
    [uid, clientSessionId, baseName, startedAt && !Number.isNaN(startedAt.valueOf()) ? startedAt : null,
      expectedSegments, expectedBytes],
  );
  await fsp.mkdir(safeSessionDirectory(uid, result.rows[0].id), { recursive: true });
  return result.rows[0];
}

export async function registerSegment(uid, sessionId, body) {
  if (!(await hasMediaCapacity())) {
    await pruneMedia();
    if (!(await hasMediaCapacity())) {
      throw new HttpError(507, "中央影片磁碟低於保留空間且已無完整副本可清理，已暫停上傳", "MEDIA_DISK_RESERVE");
    }
  }
  const index = integer(body.index, -1, 0, 999_999);
  const originalName = boundedText(body.name, 120);
  const size = Number(body.sizeBytes);
  const checksum = String(body.sha256 ?? "").toLowerCase();
  if (index < 0 || !/^segment_\d{5,6}\.mkv$/i.test(originalName)) throw new HttpError(400, "錄影片段名稱或編號無效", "INVALID_SEGMENT");
  if (!Number.isSafeInteger(size) || size <= 0) throw new HttpError(400, "錄影片段大小無效", "INVALID_SEGMENT_SIZE");
  if (!/^[a-f0-9]{64}$/.test(checksum)) throw new HttpError(400, "錄影片段 SHA-256 無效", "INVALID_SEGMENT_HASH");

  return withTransaction(async (client) => {
    const session = await client.query("SELECT id,uid FROM recording_sessions WHERE id=$1 FOR UPDATE", [sessionId]);
    if (!session.rowCount || session.rows[0].uid !== uid) throw new HttpError(404, "找不到錄影工作階段", "SESSION_NOT_FOUND");
    const current = await client.query(
      "SELECT * FROM recording_segments WHERE session_id=$1 AND segment_index=$2 FOR UPDATE",
      [sessionId, index],
    );
    if (current.rowCount) {
      const row = current.rows[0];
      if (Number(row.size_bytes) !== size || row.sha256 !== checksum) {
        throw new HttpError(409, "相同片段編號已有不同檔案", "SEGMENT_IDENTITY_CONFLICT");
      }
      return row;
    }
    const directory = safeSessionDirectory(uid, sessionId);
    const partial = relativeToMedia(path.join(directory, `${String(index).padStart(6, "0")}.upload.part`));
    const inserted = await client.query(
      `INSERT INTO recording_segments(session_id,segment_index,original_name,size_bytes,sha256,upload_relative_path)
       VALUES($1,$2,$3,$4,$5,$6) RETURNING *`,
      [sessionId, index, originalName, size, checksum, partial],
    );
    return inserted.rows[0];
  });
}

export async function receiveSegmentChunk(uid, segmentId, contentRange, req) {
  const match = /^bytes\s+(\d+)-(\d+)\/(\d+)$/i.exec(String(contentRange ?? ""));
  if (!match) throw new HttpError(400, "缺少或無效的 Content-Range", "INVALID_CONTENT_RANGE");
  const start = Number(match[1]);
  const end = Number(match[2]);
  const total = Number(match[3]);
  const chunkLength = end - start + 1;
  if (!Number.isSafeInteger(chunkLength) || chunkLength <= 0 || chunkLength > config.maxUploadChunkBytes) {
    throw new HttpError(413, "上傳區塊大小無效", "INVALID_UPLOAD_CHUNK");
  }
  const rowResult = await query(
    `SELECT rs.uid,s.* FROM recording_segments s
     JOIN recording_sessions rs ON rs.id=s.session_id WHERE s.id=$1`,
    [segmentId],
  );
  if (!rowResult.rowCount || rowResult.rows[0].uid !== uid) throw new HttpError(404, "找不到錄影片段", "SEGMENT_NOT_FOUND");
  const row = rowResult.rows[0];
  if (Number(row.size_bytes) !== total) throw new HttpError(409, "Content-Range 總長度不符", "UPLOAD_SIZE_CONFLICT");
  if (row.state === "READY") return { receivedBytes: total, complete: true };
  if (Number(row.received_bytes) !== start) {
    throw new HttpError(409, "上傳位置不符，請從伺服器回報位置續傳", "UPLOAD_OFFSET_CONFLICT", {
      receivedBytes: Number(row.received_bytes),
    });
  }
  const filePath = absoluteFromMedia(row.upload_relative_path);
  await fsp.mkdir(path.dirname(filePath), { recursive: true });
  const handle = await fsp.open(filePath, start === 0 ? "w" : "r+");
  let written = 0;
  try {
    for await (const chunk of req) {
      written += chunk.length;
      if (written > chunkLength) throw new HttpError(400, "實際區塊超過 Content-Range", "UPLOAD_CHUNK_OVERFLOW");
      await handle.write(chunk, 0, chunk.length, start + written - chunk.length);
    }
    if (written !== chunkLength) throw new HttpError(400, "實際區塊小於 Content-Range", "UPLOAD_CHUNK_SHORT");
    await handle.sync();
  } finally {
    await handle.close();
  }
  const received = start + written;
  await query("UPDATE recording_segments SET received_bytes=$2,updated_at=now() WHERE id=$1", [segmentId, received]);
  if (received === total) {
    const actualHash = await hashFile(filePath);
    if (actualHash !== row.sha256) {
      await fsp.rm(filePath, { force: true });
      await query(
        "UPDATE recording_segments SET received_bytes=0,state='UPLOADING',error_detail=$2,updated_at=now() WHERE id=$1",
        [segmentId, `SHA-256 mismatch expected=${row.sha256} actual=${actualHash}`],
      );
      throw new HttpError(422, "片段 SHA-256 驗證失敗，已重設續傳", "SEGMENT_HASH_MISMATCH");
    }
    await query("UPDATE recording_segments SET state='UPLOADED',error_detail='',updated_at=now() WHERE id=$1", [segmentId]);
    queueSegmentRemux(segmentId);
  }
  return { receivedBytes: received, complete: received === total };
}

export async function getSegmentUploadState(uid, segmentId) {
  const result = await query(
    `SELECT s.id,s.received_bytes,s.size_bytes,s.state,s.error_detail
     FROM recording_segments s JOIN recording_sessions rs ON rs.id=s.session_id
     WHERE s.id=$1 AND rs.uid=$2`,
    [segmentId, uid],
  );
  if (!result.rowCount) throw new HttpError(404, "找不到錄影片段", "SEGMENT_NOT_FOUND");
  return result.rows[0];
}

export async function retrySegment(uid, segmentId) {
  const result = await query(
    `UPDATE recording_segments s SET state='UPLOADED',error_detail='',updated_at=now()
     FROM recording_sessions rs
     WHERE s.id=$1 AND s.session_id=rs.id AND rs.uid=$2 AND s.state='ERROR'
       AND s.received_bytes=s.size_bytes AND s.upload_relative_path IS NOT NULL
     RETURNING s.id,s.state,s.received_bytes,s.size_bytes`,
    [segmentId, uid],
  );
  if (!result.rowCount) {
    const existing = await getSegmentUploadState(uid, segmentId);
    if (["UPLOADED", "PROCESSING", "READY"].includes(existing.state)) return existing;
    throw new HttpError(409, "片段目前不能重試轉檔", "SEGMENT_RETRY_NOT_READY", existing);
  }
  queueSegmentRemux(segmentId);
  return result.rows[0];
}

function queueSegmentRemux(segmentId) {
  const key = `segment:${segmentId}`;
  if (activeJobs.has(key)) return;
  activeJobs.add(key);
  setImmediate(async () => {
    try { await remuxSegment(segmentId); }
    catch (error) {
      await query(
        "UPDATE recording_segments SET state='ERROR',error_detail=$2,updated_at=now() WHERE id=$1",
        [segmentId, String(error.message ?? error).slice(0, 2000)],
      ).catch(() => {});
    } finally { activeJobs.delete(key); }
  });
}

async function remuxSegment(segmentId) {
  const result = await query(
    `SELECT s.*,rs.uid,rs.id AS recording_session_id FROM recording_segments s
     JOIN recording_sessions rs ON rs.id=s.session_id WHERE s.id=$1`,
    [segmentId],
  );
  if (!result.rowCount) return;
  const row = result.rows[0];
  if (row.state === "READY") return;
  if (!row.upload_relative_path) throw new Error("片段缺少上傳路徑");
  const source = absoluteFromMedia(row.upload_relative_path);
  const directory = safeSessionDirectory(row.uid, row.recording_session_id);
  const target = assertChildPath(config.mediaRoot, path.join(directory, `${String(row.segment_index).padStart(6, "0")}.mp4`));
  const temporary = `${target}.remuxing`;
  await query("UPDATE recording_segments SET state='PROCESSING',updated_at=now() WHERE id=$1", [segmentId]);
  await fsp.rm(temporary, { force: true });
  await runTool("ffmpeg", ["-hide_banner", "-loglevel", "warning", "-y", "-i", source, "-map", "0", "-c", "copy", "-movflags", "+faststart", "-f", "mp4", temporary]);
  const probe = await probeVideo(temporary);
  await fsp.rename(temporary, target);
  await fsp.rm(source, { force: true });
  await query(
    `UPDATE recording_segments SET state='READY',mp4_relative_path=$2,upload_relative_path=NULL,
     duration_seconds=$3,error_detail='',updated_at=now() WHERE id=$1`,
    [segmentId, relativeToMedia(target), probe.duration],
  );
  const session = await query("SELECT state FROM recording_sessions WHERE id=$1", [row.recording_session_id]);
  if (session.rows[0]?.state === "FINALIZE_PENDING") queueSessionFinalize(row.recording_session_id);
}

export async function requestSessionFinalize(uid, sessionId, body) {
  const expected = integer(body.expectedSegments, -1, 1, 100_000);
  const expectedBytes = safeExpectedBytes(body.expectedBytes);
  if (expected < 1) throw new HttpError(400, "完整片段數量無效", "INVALID_SEGMENT_COUNT");
  if (body.expectedBytes != null && expectedBytes == null) {
    throw new HttpError(400, "完整影片位元組數無效", "INVALID_EXPECTED_BYTES");
  }
  const result = await query(
    `UPDATE recording_sessions SET expected_segments=$3,expected_bytes=COALESCE($4,expected_bytes),
       state='FINALIZE_PENDING',progress_stage='SEGMENT_PROCESSING',progress_updated_at=now(),updated_at=now()
     WHERE id=$1 AND uid=$2 RETURNING id,state`,
    [sessionId, uid, expected, expectedBytes],
  );
  if (!result.rowCount) throw new HttpError(404, "找不到錄影工作階段", "SESSION_NOT_FOUND");
  queueSessionFinalize(sessionId);
  return recordingSessionState(uid, sessionId);
}

function queueSessionFinalize(sessionId) {
  const key = `session:${sessionId}`;
  if (activeJobs.has(key)) return;
  activeJobs.add(key);
  setTimeout(async () => {
    try { await finalizeSession(sessionId); }
    catch (error) {
      await query(
        "UPDATE recording_sessions SET state='ERROR',detail=$2,updated_at=now() WHERE id=$1",
        [sessionId, String(error.message ?? error).slice(0, 2000)],
      ).catch(() => {});
    } finally { activeJobs.delete(key); }
  }, 250);
}

async function finalizeSession(sessionId) {
  const sessionResult = await query("SELECT * FROM recording_sessions WHERE id=$1", [sessionId]);
  if (!sessionResult.rowCount) return;
  const session = sessionResult.rows[0];
  if (session.state === "COMPLETE") return;
  const segmentsResult = await query(
    "SELECT * FROM recording_segments WHERE session_id=$1 ORDER BY segment_index",
    [sessionId],
  );
  const segments = segmentsResult.rows;
  if (!session.expected_segments || segments.length !== session.expected_segments || segments.some((row) => row.state !== "READY")) {
    const readyCount = segments.filter((row) => row.state === "READY").length;
    const expectedCount = Number(session.expected_segments) || 0;
    const percent = expectedCount ? Math.min(89, 80 + Math.floor(readyCount / expectedCount * 10)) : null;
    await query(
      `UPDATE recording_sessions SET state='FINALIZE_PENDING',detail=$2,progress_stage='SEGMENT_PROCESSING',
       progress_percent=$3,progress_current=$4,progress_total=COALESCE(expected_segments,0),
       progress_updated_at=now(),updated_at=now() WHERE id=$1`,
      [sessionId, `等待片段完成 ${readyCount}/${session.expected_segments ?? "?"}`, percent, readyCount],
    );
    return;
  }
  const directory = safeSessionDirectory(session.uid, session.id);
  const concatPath = assertChildPath(config.mediaRoot, path.join(directory, "concat.ffconcat"));
  const finalPath = assertChildPath(config.mediaRoot, path.join(directory, `${session.base_name}.mp4`));
  const temporary = `${finalPath}.merging`;
  const concat = ["ffconcat version 1.0", ...segments.map((row) => `file '${path.basename(absoluteFromMedia(row.mp4_relative_path)).replaceAll("'", "'\\''")}'`), ""].join("\n");
  await fsp.writeFile(concatPath, concat, "utf8");
  await fsp.rm(temporary, { force: true });
  const expectedDuration = segments.reduce((total, row) => total + Math.max(0, Number(row.duration_seconds) || 0), 0);
  await query(
    `UPDATE recording_sessions SET state='MERGING',detail='正在無重編碼合成 MP4',
     progress_stage='SERVER_MERGE',progress_percent=90,progress_current=0,progress_total=$2,
     progress_updated_at=now(),updated_at=now() WHERE id=$1`,
    [sessionId, Math.max(0, Math.round(expectedDuration * 1000))],
  );
  let lastProgressAt = 0;
  let lastProgressPercent = 90;
  await runToolWithProgress("ffmpeg", ["-hide_banner", "-loglevel", "warning", "-y", "-f", "concat", "-safe", "0", "-i", concatPath, "-map", "0", "-c", "copy", "-movflags", "+faststart", "-f", "mp4", temporary], (seconds) => {
    if (!(expectedDuration > 0)) return;
    const percent = Math.min(98, 90 + Math.floor(seconds / expectedDuration * 9));
    const now = Date.now();
    if (percent === lastProgressPercent && now - lastProgressAt < 2000) return;
    lastProgressPercent = percent;
    lastProgressAt = now;
    query(
      `UPDATE recording_sessions SET progress_percent=$2,progress_current=$3,
       progress_updated_at=now(),updated_at=now() WHERE id=$1 AND state='MERGING'`,
      [sessionId, percent, Math.max(0, Math.round(seconds * 1000))],
    ).catch(() => {});
  });
  await query(
    `UPDATE recording_sessions SET detail='中央合併完成，正在驗證影片',progress_stage='VERIFYING',
     progress_percent=99,progress_updated_at=now(),updated_at=now() WHERE id=$1`, [sessionId],
  );
  const probe = await probeVideo(temporary);
  const stat = await fsp.stat(temporary);
  await fsp.rename(temporary, finalPath);
  await query(
    `UPDATE recording_sessions SET state='COMPLETE',detail='中央完整影片已驗證',completed_at=now(),
      final_relative_path=$2,final_size=$3,duration_seconds=$4,progress_stage='COMPLETE',
      progress_percent=100,progress_current=progress_total,progress_updated_at=now(),updated_at=now() WHERE id=$1`,
    [sessionId, relativeToMedia(finalPath), stat.size, probe.duration],
  );
  for (const segment of segments) {
    await fsp.rm(absoluteFromMedia(segment.mp4_relative_path), { force: true });
  }
  await fsp.rm(concatPath, { force: true });
  await pruneMedia();
}

export async function recordingSessionState(uid, sessionId) {
  const result = await query(
    `SELECT rs.*,
      count(seg.id)::int AS segment_count,
      count(seg.id) FILTER (WHERE seg.state='READY')::int AS ready_segments,
      COALESCE(sum(seg.received_bytes),0)::bigint AS received_bytes,
      COALESCE(sum(seg.size_bytes),0)::bigint AS registered_bytes,
      GREATEST(rs.updated_at,COALESCE(max(seg.updated_at),rs.updated_at)) AS effective_updated_at
     FROM recording_sessions rs LEFT JOIN recording_segments seg ON seg.session_id=rs.id
     WHERE rs.id=$1 AND rs.uid=$2 GROUP BY rs.id`,
    [sessionId, uid],
  );
  if (!result.rowCount) throw new HttpError(404, "找不到錄影工作階段", "SESSION_NOT_FOUND");
  return result.rows[0];
}

export async function listRecordings(uid) {
  const result = await query(
    `SELECT rs.id,rs.uid,rs.client_session_id,rs.base_name,rs.state,rs.detail,rs.expected_segments,
      rs.expected_bytes,rs.progress_stage,rs.progress_percent,rs.progress_current,rs.progress_total,
      rs.started_at,rs.completed_at,rs.final_size,rs.duration_seconds,rs.created_at,
      GREATEST(rs.updated_at,COALESCE(max(seg.updated_at),rs.updated_at)) AS updated_at,
      count(seg.id)::int AS segment_count,
      count(seg.id) FILTER (WHERE seg.state='READY')::int AS ready_segments,
      COALESCE(sum(seg.received_bytes),0)::bigint AS received_bytes,
      COALESCE(sum(seg.size_bytes),0)::bigint AS registered_bytes,
      (rs.final_relative_path IS NOT NULL) AS playable
     FROM recording_sessions rs LEFT JOIN recording_segments seg ON seg.session_id=rs.id
     WHERE rs.uid=$1 GROUP BY rs.id ORDER BY rs.created_at DESC LIMIT 50`,
    [uid],
  );
  return result.rows;
}

export async function listRecordingSegments(uid, sessionId) {
  const result = await query(
    `SELECT s.id,s.segment_index,s.original_name,s.size_bytes,s.received_bytes,s.state,s.duration_seconds,
      (s.mp4_relative_path IS NOT NULL) AS playable,s.error_detail
     FROM recording_segments s JOIN recording_sessions rs ON rs.id=s.session_id
     WHERE rs.uid=$1 AND rs.id=$2 ORDER BY s.segment_index`,
    [uid, sessionId],
  );
  return result.rows;
}

export async function resolvePlayable(uid, sessionId, segmentId = "") {
  if (segmentId) {
    const result = await query(
      `SELECT s.mp4_relative_path AS relative_path FROM recording_segments s
       JOIN recording_sessions rs ON rs.id=s.session_id
       WHERE rs.uid=$1 AND rs.id=$2 AND s.id=$3 AND s.state='READY'`,
      [uid, sessionId, segmentId],
    );
    if (!result.rowCount) throw new HttpError(404, "片段尚不可播放", "VIDEO_NOT_READY");
    return absoluteFromMedia(result.rows[0].relative_path);
  }
  const result = await query(
    "SELECT final_relative_path AS relative_path FROM recording_sessions WHERE uid=$1 AND id=$2 AND state='COMPLETE'",
    [uid, sessionId],
  );
  if (!result.rowCount || !result.rows[0].relative_path) throw new HttpError(404, "完整影片尚不可播放", "VIDEO_NOT_READY");
  return absoluteFromMedia(result.rows[0].relative_path);
}

export async function streamVideo(req, res, filePath) {
  let handle;
  try {
    handle = await fsp.open(filePath, "r");
  } catch (error) {
    if (error?.code === "ENOENT") throw new HttpError(404, "影片檔案不存在或正在整理", "VIDEO_FILE_NOT_FOUND");
    throw error;
  }
  try {
    const stat = await handle.stat();
    const rangeHeader = String(req.headers.range ?? "");
    const range = rangeHeader ? /^bytes=(\d*)-(\d*)$/i.exec(rangeHeader) : null;
    res.setHeader("Accept-Ranges", "bytes");
    res.setHeader("Content-Type", "video/mp4");
    res.setHeader("Cache-Control", "private, no-store");
    if (!rangeHeader) {
      res.writeHead(200, { "Content-Length": stat.size });
      if (req.method === "HEAD") {
        res.end();
        return;
      }
      await pipeline(handle.createReadStream({ autoClose: false }), res);
      return;
    }
    if (!range) {
      res.writeHead(416, { "Content-Range": `bytes */${stat.size}` });
      res.end();
      return;
    }
    let start = range[1] ? Number(range[1]) : 0;
    let end = range[2] ? Number(range[2]) : stat.size - 1;
    if (!range[1] && range[2]) {
      const suffix = Number(range[2]);
      start = Math.max(0, stat.size - suffix);
      end = stat.size - 1;
    }
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || end < start || start >= stat.size) {
      res.writeHead(416, { "Content-Range": `bytes */${stat.size}` });
      res.end();
      return;
    }
    end = Math.min(end, stat.size - 1);
    res.writeHead(206, {
      "Content-Length": end - start + 1,
      "Content-Range": `bytes ${start}-${end}/${stat.size}`,
    });
    if (req.method === "HEAD") {
      res.end();
      return;
    }
    await pipeline(handle.createReadStream({ autoClose: false, start, end }), res);
  } finally {
    await handle.close().catch(() => {});
  }
}

async function deleteCompletedSession(row) {
  const directory = safeSessionDirectory(row.uid, row.id);
  await withTransaction(async (client) => {
    await client.query("DELETE FROM recording_sessions WHERE id=$1 AND state='COMPLETE'", [row.id]);
  });
  await fsp.rm(directory, { recursive: true, force: true });
}

export async function pruneMedia() {
  const devices = await query("SELECT uid FROM devices");
  for (const { uid } of devices.rows) {
    const completed = await query(
      "SELECT id,uid FROM recording_sessions WHERE uid=$1 AND state='COMPLETE' ORDER BY completed_at DESC NULLS LAST,created_at DESC",
      [uid],
    );
    for (const row of completed.rows.slice(config.sessionsPerDevice)) await deleteCompletedSession(row);
  }
  while (!(await hasMediaCapacity())) {
    const oldest = await query(
      "SELECT id,uid FROM recording_sessions WHERE state='COMPLETE' ORDER BY completed_at ASC NULLS FIRST LIMIT 1",
    );
    if (!oldest.rowCount) break;
    await deleteCompletedSession(oldest.rows[0]);
    await query(
      "INSERT INTO server_alerts(level,code,message,details) VALUES('WARN','MEDIA_PRESSURE',$1,$2)",
      ["中央磁碟低於保留空間，已刪除最舊完整影片副本", JSON.stringify(oldest.rows[0])],
    );
  }
}

export async function resumeMediaJobs() {
  const segments = await query("SELECT id FROM recording_segments WHERE state IN ('UPLOADED','PROCESSING')");
  for (const row of segments.rows) queueSegmentRemux(row.id);
  const sessions = await query("SELECT id FROM recording_sessions WHERE state IN ('FINALIZE_PENDING','MERGING')");
  for (const row of sessions.rows) queueSessionFinalize(row.id);
}

async function recordExhaustedMediaAlerts() {
  await query(
    `INSERT INTO server_alerts(level,code,message,details)
     SELECT 'ERROR','MEDIA_AUTO_REPAIR_EXHAUSTED','錄影片段自動修復已達 3 次，等待人工檢查',
       jsonb_build_object('kind','segment','jobId',s.id,'sessionId',s.session_id,'detail',s.error_detail)
     FROM recording_segments s
     WHERE s.state='ERROR' AND s.auto_retry_count >= $1
       AND NOT EXISTS (
         SELECT 1 FROM server_alerts a WHERE a.cleared_at IS NULL
           AND a.code='MEDIA_AUTO_REPAIR_EXHAUSTED'
           AND a.details->>'kind'='segment' AND a.details->>'jobId'=s.id::text
       )`,
    [AUTO_RETRY_LIMIT],
  );
  await query(
    `INSERT INTO server_alerts(level,code,message,details)
     SELECT 'ERROR','MEDIA_AUTO_REPAIR_EXHAUSTED','完整影片自動修復已達 3 次，已保留可播放片段',
       jsonb_build_object('kind','session','jobId',rs.id,'uid',rs.uid,'detail',rs.detail)
     FROM recording_sessions rs
     WHERE rs.state='ERROR' AND rs.auto_retry_count >= $1
       AND NOT EXISTS (
         SELECT 1 FROM server_alerts a WHERE a.cleared_at IS NULL
           AND a.code='MEDIA_AUTO_REPAIR_EXHAUSTED'
           AND a.details->>'kind'='session' AND a.details->>'jobId'=rs.id::text
       )`,
    [AUTO_RETRY_LIMIT],
  );
}

export async function repairStalledMediaJobs() {
  const segments = await query(
    `UPDATE recording_segments SET state='UPLOADED',error_detail='',
       auto_retry_count=auto_retry_count+1,last_auto_repair_at=now(),updated_at=now()
     WHERE auto_retry_count < $1
       AND received_bytes=size_bytes AND upload_relative_path IS NOT NULL
       AND ((state='ERROR' AND updated_at<now()-interval '2 minutes')
         OR (state='PROCESSING' AND updated_at<now()-interval '10 minutes'))
     RETURNING id,session_id,auto_retry_count`,
    [AUTO_RETRY_LIMIT],
  );
  for (const row of segments.rows) queueSegmentRemux(row.id);

  // UPLOADED/FINALIZE_PENDING are idempotent queue states. Requeue them on
  // every repair pass without consuming an error retry.
  const pendingSegments = await query("SELECT id FROM recording_segments WHERE state='UPLOADED'");
  for (const row of pendingSegments.rows) queueSegmentRemux(row.id);

  const sessions = await query(
    `UPDATE recording_sessions rs SET state='FINALIZE_PENDING',detail='中央自動修復後重新合併',
       progress_stage='SEGMENT_PROCESSING',auto_retry_count=rs.auto_retry_count+1,
       last_auto_repair_at=now(),updated_at=now()
     WHERE rs.auto_retry_count < $1
       AND ((rs.state='ERROR' AND rs.updated_at<now()-interval '2 minutes')
         OR (rs.state='MERGING' AND rs.updated_at<now()-interval '30 minutes'))
       AND rs.expected_segments IS NOT NULL
       AND (SELECT count(*) FROM recording_segments s WHERE s.session_id=rs.id)=rs.expected_segments
       AND NOT EXISTS (SELECT 1 FROM recording_segments s WHERE s.session_id=rs.id AND s.state<>'READY')
     RETURNING rs.id,rs.uid,rs.auto_retry_count`,
    [AUTO_RETRY_LIMIT],
  );
  for (const row of sessions.rows) queueSessionFinalize(row.id);

  const pendingSessions = await query(
    `SELECT rs.id FROM recording_sessions rs
     WHERE rs.state='FINALIZE_PENDING' AND rs.expected_segments IS NOT NULL
       AND (SELECT count(*) FROM recording_segments s WHERE s.session_id=rs.id)=rs.expected_segments
       AND NOT EXISTS (SELECT 1 FROM recording_segments s WHERE s.session_id=rs.id AND s.state<>'READY')`,
  );
  for (const row of pendingSessions.rows) queueSessionFinalize(row.id);

  await recordExhaustedMediaAlerts();
  return {
    repairedSegments: segments.rowCount,
    repairedSessions: sessions.rowCount,
    queuedSegments: pendingSegments.rowCount,
    queuedSessions: pendingSessions.rowCount,
  };
}
