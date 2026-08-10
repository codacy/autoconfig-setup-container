// Minimal localhost proxy. Holds the real Anthropic API key in THIS process's
// environment (owned by `runner`) and injects it into every upstream request,
// overwriting whatever dummy credential the agent sent. The agent (a different
// UID) cannot read this process's /proc/<pid>/environ, so the key stays secret.
const http = require('http');
const https = require('https');

const PORT = parseInt(process.env.ANTHROPIC_PROXY_PORT || '8118', 10);
const REAL_KEY = process.env.ANTHROPIC_API_KEY;
const UPSTREAM = 'api.anthropic.com';

if (!REAL_KEY) {
  console.error('anthropic-proxy: ANTHROPIC_API_KEY not set; refusing to start');
  process.exit(1);
}

const server = http.createServer((req, res) => {
  const headers = { ...req.headers, host: UPSTREAM };
  // Replace any client-supplied auth with the real key.
  delete headers['authorization'];
  headers['x-api-key'] = REAL_KEY;
  headers['anthropic-version'] = headers['anthropic-version'] || '2023-06-01';

  const upstream = https.request(
    { hostname: UPSTREAM, port: 443, path: req.url, method: req.method, headers },
    (up) => { res.writeHead(up.statusCode, up.headers); up.pipe(res); }
  );
  upstream.on('error', (e) => { res.writeHead(502); res.end('proxy error: ' + e.message); });
  req.pipe(upstream);
});

server.listen(PORT, '127.0.0.1', () => console.error(`anthropic-proxy listening on 127.0.0.1:${PORT}`));
