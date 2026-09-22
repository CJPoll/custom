// perm-harness.mjs -- a fake MCP stdio CLIENT for driving server.mjs's T5
// permission relay (DND-286) in the self-test.
//
// It spawns the server (with the fakes the caller exports in the environment:
// ATHENA_RELAY_DM_BIN / _PEEK_BIN / _REQUERY_BIN, ATHENA_ATTEND_OWNER_SLACK_ID,
// ATHENA_ATTEND_STATE_DIR, a fs-watch doorbell), performs the initialize /
// initialized handshake, sends ONE permission_request notification, then touches
// a doorbell so the shim's poll() runs its verdict intake, and collects every
// `notifications/claude/channel/permission` event the server emits. Prints the
// result as one JSON object on stdout for self-test.sh to assert against.
//
// No spin: everything is event-driven (stdout 'data', child 'close') plus a few
// bounded one-shot timers.
//
// Env:
//   HARNESS_SERVER          path to server.mjs (required)
//   PERM_REQUEST            JSON of the permission_request params to send
//                           ({request_id, tool_name, description, input_preview}).
//                           Omit to send none (e.g. a capability-only run).
//   PERM_DOORBELL           doorbell path to touch (fs-watch) to trigger poll()
//   PERM_REQUEST_DELAY_MS   delay after `initialized` before sending (default 150)
//   PERM_TOUCH_DELAY_MS     delay after the request before touching (default 700)
//   PERM_WINDOW_MS          total collect window after initialized (default 2200)
// Everything else in process.env passes through to the server; cwd is inherited
// from this process (self-test.sh sets it per case).

import { spawn } from 'node:child_process';
import { utimesSync, openSync, closeSync, existsSync } from 'node:fs';

const SERVER = process.env.HARNESS_SERVER;
const PERM_REQUEST = process.env.PERM_REQUEST || '';
const DOORBELL = process.env.PERM_DOORBELL || '';
const REQUEST_DELAY_MS = Number(process.env.PERM_REQUEST_DELAY_MS || '150');
const TOUCH_DELAY_MS = Number(process.env.PERM_TOUCH_DELAY_MS || '700');
const WINDOW_MS = Number(process.env.PERM_WINDOW_MS || '2200');

const permissions = []; // params of every notifications/claude/channel/permission
let initResult = null;
let stderrBuf = '';
let exitCode = null;
let finished = false;
let buf = '';

const child = spawn('node', [SERVER], { stdio: ['pipe', 'pipe', 'pipe'] });

function finish() {
  if (finished) return;
  finished = true;
  try {
    child.kill('SIGTERM');
  } catch {
    /* already gone */
  }
  setTimeout(() => {
    process.stdout.write(
      JSON.stringify({ init: initResult, permissions, exit: exitCode, stderr: stderrBuf }) + '\n',
    );
    process.exit(0);
  }, 120);
}

function send(obj) {
  try {
    child.stdin.write(JSON.stringify(obj) + '\n');
  } catch {
    /* server may have exited */
  }
}

function touchDoorbell() {
  if (!DOORBELL) return;
  try {
    if (!existsSync(DOORBELL)) closeSync(openSync(DOORBELL, 'a'));
    const now = new Date();
    utimesSync(DOORBELL, now, now);
  } catch {
    /* ignore */
  }
}

child.stdout.setEncoding('utf8');
child.stdout.on('data', (chunk) => {
  buf += chunk;
  let nl;
  while ((nl = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (!line) continue;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      continue;
    }
    if (msg.id === 1 && msg.result && msg.result.capabilities) {
      initResult = msg.result;
      send({ jsonrpc: '2.0', method: 'notifications/initialized' });
      setTimeout(finish, WINDOW_MS);
      // Send the permission_request, then (later) ring the doorbell so a poll
      // runs AFTER the request is recorded (openRequests has it).
      if (PERM_REQUEST) {
        setTimeout(() => {
          let params = {};
          try {
            params = JSON.parse(PERM_REQUEST);
          } catch {
            /* leave empty */
          }
          send({ jsonrpc: '2.0', method: 'notifications/claude/channel/permission_request', params });
          setTimeout(touchDoorbell, TOUCH_DELAY_MS);
        }, REQUEST_DELAY_MS);
      }
    } else if (msg.method === 'notifications/claude/channel/permission') {
      permissions.push(msg.params);
    }
  }
});

child.stderr.setEncoding('utf8');
child.stderr.on('data', (c) => {
  stderrBuf += c;
});

child.on('close', (code) => {
  exitCode = code;
  finish();
});

send({
  jsonrpc: '2.0',
  id: 1,
  method: 'initialize',
  params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'perm-harness', version: '0' } },
});
setTimeout(() => {
  if (!initResult) finish();
}, WINDOW_MS + 500);
