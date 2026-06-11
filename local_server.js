const http = require("http");
const fs = require("fs");
const path = require("path");
const url = require("url");
const { execFile } = require("child_process");

const root = __dirname;
const port = Number(process.env.INVESTMENT_SYSTEM_PORT || 8787);
const host = process.env.INVESTMENT_SYSTEM_HOST || "127.0.0.1";

const mimeTypes = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".webmanifest": "application/manifest+json; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".txt": "text/plain; charset=utf-8",
  ".md": "text/markdown; charset=utf-8"
};

function send(res, status, body, type = "text/plain; charset=utf-8") {
  res.writeHead(status, {
    "Content-Type": type,
    "Cache-Control": status === 200 ? "no-cache" : "no-store"
  });
  res.end(body);
}

let updateRunning = null;

function runMarketUpdate() {
  if (updateRunning) return updateRunning;

  const script = path.join(root, "run_update_with_log.ps1");
  const powershell = path.join(process.env.SystemRoot || "C:\\WINDOWS", "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
  updateRunning = new Promise((resolve) => {
    const startedAt = new Date();
    execFile(
      powershell,
      ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script],
      { cwd: root, timeout: 120000 },
      (error, stdout, stderr) => {
        const finishedAt = new Date();
        updateRunning = null;
        resolve({
          ok: !error,
          startedAt: startedAt.toISOString(),
          finishedAt: finishedAt.toISOString(),
          stdout: stdout || "",
          stderr: stderr || "",
          code: error && typeof error.code !== "undefined" ? error.code : 0,
          message: error ? error.message : "updated"
        });
      }
    );
  });

  return updateRunning;
}

const server = http.createServer((req, res) => {
  const parsed = url.parse(req.url, true);

  try {
    if (parsed.pathname === "/api/update-market") {
      runMarketUpdate().then(result => {
        send(res, result.ok ? 200 : 500, JSON.stringify(result), "application/json; charset=utf-8");
      });
      return;
    }

    let filePath = parsed.pathname === "/" ? "investment_system.html" : decodeURIComponent(parsed.pathname.slice(1));
    filePath = path.normalize(filePath);
    if (filePath.startsWith("..") || path.isAbsolute(filePath)) {
      return send(res, 403, "Forbidden");
    }

    const abs = path.join(root, filePath);
    if (!fs.existsSync(abs) || fs.statSync(abs).isDirectory()) {
      return send(res, 404, "Not found");
    }

    const ext = path.extname(abs).toLowerCase();
    if (filePath === "investment_system.html") {
      runMarketUpdate().then(() => {
        send(res, 200, fs.readFileSync(abs), mimeTypes[ext] || "application/octet-stream");
      });
      return;
    }

    send(res, 200, fs.readFileSync(abs), mimeTypes[ext] || "application/octet-stream");
  } catch (error) {
    send(res, 500, error.message);
  }
});

server.listen(port, host, () => {
  console.log(`Investment system running at http://${host}:${port}/`);
});
