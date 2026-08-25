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
  const result = await query(
    `INSERT INTO recording_sessions(uid,client_session_id,base_name,started_at,state)
     VALUES($1,$2,$3,$4,'UPLOADING')
     ON CONFLICT(uid,client_session_id) DO UPDATE SET updated_at=now()
     RETURNING id,uid,client_session_id,base_name,state,expected_segments,created_at,updated_at`,
    [uid, clientSessionId, baseName, startedAt && !Number.isNaN(startedAt.valueOf()) ? startedAt : null],
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
  if (expected < 1) throw new HttpError(400, "完整片段數量無效", "INVALID_SEGMENT_COUNT");
  const result = await query(
    `UPDATE recording_sessions SET expected_segments=$3,state='FINALIZE_PENDING',updated_at=now()
     WHERE id=$1 AND uid=$2 RETURNING id,state`,
    [sessionId, uid, expected],
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
    await query(
      "UPDATE recording_sessions SET state='FINALIZE_PENDING',detail=$2,updated_at=now() WHERE id=$1",
      [sessionId, `等待片段完成 ${segments.filter((row) => row.state === "READY").length}/${session.expected_segments ?? "?"}`],
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
  await query("UPDATE recording_sessions SET state='MERGING',detail='正在無重編碼合成 MP4',updated_at=now() WHERE id=$1", [sessionId]);
  await runTool("ffmpeg", ["-hide_banner", "-loglevel", "warning", "-y", "-f", "concat", "-safe", "0", "-i", concatPath, "-map", "0", "-c", "copy", "-movflags", "+faststart", "-f", "mp4", temporary]);
  const probe = await probeVideo(temporary);
  const stat = await fsp.stat(temporary);
  await fsp.rename(temporary, finalPath);
  await query(
    `UPDATE recording_sessions SET state='COMPLETE',detail='中央完整影片已驗證',completed_at=now(),
      final_relative_path=$2,final_size=$3,duration_seconds=$4,updated_at=now() WHERE id=$1`,
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
      COALESCE(sum(seg.received_bytes),0)::bigint AS received_bytes
     FROM recording_sessions rs LEFT JOIN recording_segments seg ON seg.session_id=rs.id
     WHERE rs.id=$1 AND rs.uid=$2 GROUP BY rs.id`,
    [sessionId, uid],
  );
  if (!result.rowCount) throw new HttpError(404, "找不到錄影工作階段", "SESSION_NOT_FOUND");
  return result.rows[0];
}

export async function listRecordings(uid) {
  const result = await query(
    `SELECT id,uid,client_session_id,base_name,state,detail,expected_segments,started_at,completed_at,
      final_size,duration_seconds,created_at,updated_at,
      (final_relative_path IS NOT NULL) AS playable
     FROM recording_sessions WHERE uid=$1 ORDER BY created_at DESC LIMIT 50`,
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
