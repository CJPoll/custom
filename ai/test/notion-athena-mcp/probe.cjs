// Test driver for ai/test/notion-athena-mcp/self-test.sh. Starts a local HTTP
// listener, sends ONE request to it with node's http client, and prints the
// Notion-Version header the listener saw ("<none>" when absent).
//   node probe.cjs <hostname-to-dial> [<Notion-Version value to send>]
// The listener is on 127.0.0.1; <hostname-to-dial> is what the request names,
// so the shim's host match can be exercised without any network.
'use strict';
const http = require('http');

const dial = process.argv[2];
const sent = process.argv[3];

const server = http.createServer((req, res) => {
  res.end(String(req.headers['notion-version'] || '<none>'));
});
server.listen(0, '127.0.0.1', () => {
  const headers = { Authorization: 'Bearer test-placeholder' };
  if (sent) headers['Notion-Version'] = sent;
  const req = http.request({ hostname: dial, port: server.address().port, path: '/', method: 'POST', headers }, (res) => {
    let body = '';
    res.on('data', (c) => { body += c; });
    res.on('end', () => { process.stdout.write(body + '\n'); server.close(); });
  });
  req.on('error', (e) => { process.stderr.write('probe: ' + e.message + '\n'); server.close(); process.exit(1); });
  req.end('{}');
});
