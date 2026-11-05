import http from "node:http";

// Only an ephemeral loopback fixture. Never contacts a device or real API.
const server = http.createServer((req, res) => {
  if (req.url === "/ok") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end('{"fixture":"ok"}');
    return;
  }
  if (req.url !== "/slow") { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { "Content-Type": "application/json" });
  res.write(" ");
  // A trickling response evades per-receive timeout but must not evade the
  // client's whole-response deadline.
  const timer = setInterval(() => res.write(" "), 100);
  res.on("close", () => clearInterval(timer));
});
server.listen(0, "127.0.0.1", () => console.log(server.address().port));
setTimeout(() => { server.closeAllConnections(); server.close(); }, 20000).unref();
