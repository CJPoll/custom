// harness.mjs -- a fake MCP stdio CLIENT for driving server.mjs in the self-test.
//
// It spawns the server, performs the initialize / initialized handshake, collects
// every `notifications/claude/channel` event the server pushes for a bounded
// window, optionally touches a doorbell path as a stimulus, and prints the result
// as one JSON object on stdout for self-test.sh to assert against.
//
// No spin: everything is event-driven (stdout 'data', child 'close') plus a
// single bounded window timer.
//
// Env knobs (all optional):
//   HARNESS_SERVER        path to server.mjs (required)
//   HARNESS_NO_INIT=1     do NOT send initialize (for tenancy-failure cases where
//                         the server exits before the handshake)
//   HARNESS_WINDOW_MS     collect events for this long after initialized (default 700)
//   HARNESS_TOUCH         a doorbell path to `touch` as a stimulus
//   HARNESS_TOUCH_DELAY_MS delay before the touch (default 200)
// Everything else in process.env is passed through to the server (cwd is inherited
// from the harness process, which self-test.sh sets per case).

import { spawn } from 'node:child_process';
import { utimesSync, openSync, closeSync, existsSync, unlinkSync } from 'node:fs';

const SERVER = process.env.HARNESS_SERVER;
const NO_INIT = process.env.HARNESS_NO_INIT === '1';
const WINDOW_MS = Number(process.env.HARNESS_WINDOW_MS || '700');
const TOUCH = process.env.HARNESS_TOUCH || '';
const TOUCH_DELAY_MS = Number(process.env.HARNESS_TOUCH_DELAY_MS || '200');
// HARNESS_RENAME: unlink+recreate this path as a stimulus (an inode rename, which
// fs.watch reports as 'rename' -- the rotation/repair recovery path).
const RENAME = process.env.HARNESS_RENAME || '';
// Tool driving (T4): request tools/list, and/or call one tool after a delay.
const LIST_TOOLS = process.env.HARNESS_LIST_TOOLS === '1';
const CALL_TOOL = process.env.HARNESS_CALL_TOOL || '';
const CALL_ARGS = process.env.HARNESS_CALL_ARGS || '{}';
const CALL_DELAY_MS = Number(process.env.HARNESS_CALL_DELAY_MS || '250');

const events = [];
let toolsList = null; // result.tools from tools/list
let callResult = null; // result (or {error}) from tools/call
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
  // Give the server a beat to reap its own child (the waiter) on SIGTERM.
  setTimeout(() => {
    process.stdout.write(
      JSON.stringify({ init: initResult, events, toolsList, callResult, exit: exitCode, stderr: stderrBuf }) + '\n',
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

let windowTimer = null;
function startWindow() {
  if (windowTimer) return;
  windowTimer = setTimeout(finish, WINDOW_MS);
  if (TOUCH) {
    setTimeout(() => {
      try {
        if (!existsSync(TOUCH)) {
          const fd = openSync(TOUCH, 'a');
          closeSync(fd);
        }
        // A pure attrib bump (like the client's touch(1)): update times only.
        const now = new Date();
        utimesSync(TOUCH, now, now);
      } catch {
        /* ignore */
      }
    }, TOUCH_DELAY_MS);
  }
  if (RENAME) {
    setTimeout(() => {
      try {
        if (existsSync(RENAME)) unlinkSync(RENAME);
        closeSync(openSync(RENAME, 'w')); // recreate: a new inode at the same path
      } catch {
        /* ignore */
      }
    }, TOUCH_DELAY_MS);
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
      startWindow();
      if (LIST_TOOLS) send({ jsonrpc: '2.0', id: 2, method: 'tools/list' });
      if (CALL_TOOL) {
        setTimeout(() => {
          let args = {};
          try {
            args = JSON.parse(CALL_ARGS);
          } catch {
            /* leave empty */
          }
          send({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: CALL_TOOL, arguments: args } });
        }, CALL_DELAY_MS);
      }
    } else if (msg.id === 2) {
      toolsList = msg.result ? msg.result.tools : { error: msg.error };
    } else if (msg.id === 3) {
      callResult = msg.result || { error: msg.error };
    } else if (msg.method === 'notifications/claude/channel') {
      events.push(msg.params);
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

// Kick off.
if (NO_INIT) {
  // No handshake: just watch for the server to exit (tenancy failure) within a
  // short window.
  setTimeout(finish, WINDOW_MS);
} else {
  send({
    jsonrpc: '2.0',
    id: 1,
    method: 'initialize',
    params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'harness', version: '0' } },
  });
  // Safety net: if the server never answers initialize, still finish.
  setTimeout(() => {
    if (!windowTimer) finish();
  }, WINDOW_MS + 500);
}
