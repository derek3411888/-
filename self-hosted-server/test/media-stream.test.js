import assert from "node:assert/strict";
import fsp from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { Writable } from "node:stream";
import test from "node:test";

process.env.SESSION_SECRET ||= "test-session-secret-abcdefghijklmnopqrstuvwxyz";
process.env.LIVE_TOKEN_SECRET ||= "test-live-token-secret-abcdefghijklmnopqrstuvwxyz";
process.env.LIVE_SRT_PASSPHRASE ||= "test-live-srt-passphrase-abcdefghijklm";

const { streamVideo } = await import("../src/media.js");

class MemoryResponse extends Writable {
  constructor() {
    super();
    this.statusCode = 0;
    this.headers = {};
    this.chunks = [];
  }

  setHeader(name, value) { this.headers[String(name).toLowerCase()] = String(value); }

  writeHead(status, headers = {}) {
    this.statusCode = status;
    for (const [name, value] of Object.entries(headers)) this.setHeader(name, value);
    return this;
  }

  _write(chunk, _encoding, callback) {
    this.chunks.push(Buffer.from(chunk));
    callback();
  }

  body() { return Buffer.concat(this.chunks); }
}

async function withVideo(callback) {
  const directory = await fsp.mkdtemp(path.join(os.tmpdir(), "wuthering-video-test-"));
  const filePath = path.join(directory, "sample.mp4");
  const content = Buffer.from("0123456789abcdef", "utf8");
  await fsp.writeFile(filePath, content);
  try {
    await callback(filePath, content);
  } finally {
    await fsp.rm(directory, { recursive: true, force: true });
  }
}

test("video HEAD returns metadata without a response body", async () => {
  await withVideo(async (filePath, content) => {
    const response = new MemoryResponse();
    await streamVideo({ method: "HEAD", headers: {} }, response, filePath);
    assert.equal(response.statusCode, 200);
    assert.equal(response.headers["content-length"], String(content.length));
    assert.equal(response.headers["accept-ranges"], "bytes");
    assert.equal(response.headers["content-type"], "video/mp4");
    assert.equal(response.body().length, 0);
  });
});

test("video HEAD supports byte ranges without a response body", async () => {
  await withVideo(async (filePath, content) => {
    const response = new MemoryResponse();
    await streamVideo({ method: "HEAD", headers: { range: "bytes=2-5" } }, response, filePath);
    assert.equal(response.statusCode, 206);
    assert.equal(response.headers["content-length"], "4");
    assert.equal(response.headers["content-range"], `bytes 2-5/${content.length}`);
    assert.equal(response.body().length, 0);
  });
});

test("video GET returns the requested byte range", async () => {
  await withVideo(async (filePath, content) => {
    const response = new MemoryResponse();
    await streamVideo({ method: "GET", headers: { range: "bytes=3-7" } }, response, filePath);
    assert.equal(response.statusCode, 206);
    assert.equal(response.headers["content-range"], `bytes 3-7/${content.length}`);
    assert.deepEqual(response.body(), content.subarray(3, 8));
  });
});

test("video rejects malformed and out-of-bounds ranges", async () => {
  await withVideo(async (filePath, content) => {
    for (const range of ["bytes=bad", `bytes=${content.length}-`]) {
      const response = new MemoryResponse();
      await streamVideo({ method: "GET", headers: { range } }, response, filePath);
      assert.equal(response.statusCode, 416);
      assert.equal(response.headers["content-range"], `bytes */${content.length}`);
      assert.equal(response.body().length, 0);
    }
  });
});
