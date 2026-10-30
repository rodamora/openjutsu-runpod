// Front for the Openjutsu app behind Runpod's HTTP proxy.
//
// Runpod's proxy (Cloudflare) sends the pod-internal address as Host and the public name only in
// X-Forwarded-Host. Openjutsu's same-origin check compares Origin with `${X-Forwarded-Proto}//${Host}`,
// so every API call from the browser would be refused as cross-origin. This restores Host from
// X-Forwarded-Host and streams everything else through unchanged (uploads, SSE progress, downloads).
// A browser cannot set X-Forwarded-Host, so the check still stops cross-site requests; the app's
// password still guards every route.
import http from "node:http";

const listen = { host: "0.0.0.0", port: Number(process.env.APP_PORT ?? 3000) };
const target = { host: "127.0.0.1", port: Number(process.env.NEXT_PORT ?? 3010) };
const agent = new http.Agent({ keepAlive: true });

const server = http.createServer((req, res) => {
  const headers = { ...req.headers };
  const forwarded = headers["x-forwarded-host"];
  if (typeof forwarded === "string" && forwarded) headers.host = forwarded.split(",")[0].trim();
  const upstream = http.request({ ...target, agent, method: req.method, path: req.url, headers }, (reply) => {
    res.writeHead(reply.statusCode ?? 502, reply.headers);
    reply.pipe(res);
  });
  upstream.on("error", () => {
    if (!res.headersSent) res.writeHead(502, { "content-type": "text/plain" });
    res.end("Openjutsu is not answering.");
  });
  res.on("close", () => { if (!res.writableFinished) upstream.destroy(); });
  req.pipe(upstream);
});
// Jobs stream progress for many minutes and uploads can be 512 MB: no server-side timeouts.
server.requestTimeout = 0;
server.headersTimeout = 60_000;
server.timeout = 0;
server.listen(listen.port, listen.host, () => console.log(JSON.stringify({ component: "front", event: "listening", ...listen })));
