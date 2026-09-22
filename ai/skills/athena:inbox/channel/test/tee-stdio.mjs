#!/usr/bin/env node
// tee-stdio.mjs -- a byte-capturing pass-through between an MCP stdio CLIENT
// (the pinned SDK, when gen-sdk-golden.mjs drives it) and server.mjs.
//
// It spawns `node <argv...>` (everything after this script -- i.e. server.mjs
// plus any flags), forwards this process's stdin to the child verbatim and the
// child's stdout back out verbatim, and APPENDS every newline-delimited
// JSON-RPC frame it sees -- tagged by direction -- to $ATHENA_TEE_CAPTURE as
// NDJSON ({"dir":"client"|"server","frame":<obj>}).
//
// Used ONLY by test/gen-sdk-golden.mjs, which needs node_modules. It is never
// on the hermetic gate path (test/sdk-conformance.mjs spawns server.mjs
// directly). Pass-through is byte-exact: the recording is a side branch that
// never alters what either side receives.
import { spawn } from 'node:child_process';
import { appendFileSync } from 'node:fs';

const CAPTURE = process.env.ATHENA_TEE_CAPTURE || '';
const args = process.argv.slice(2); // [server.mjs, ...serverArgs]
if (args.length === 0) {
  process.stderr.write('tee-stdio: no command given.\n  Fix: node tee-stdio.mjs <server.mjs> [args...]\n');
  process.exit(2);
}

const child = spawn('node', args, { stdio: ['pipe', 'pipe', 'inherit'] });

function record(dir, line) {
  const t = line.trim();
  if (!t || !CAPTURE) return;
  let frame;
  try {
    frame = JSON.parse(t);
  } catch {
    return; // a non-JSON line is not a frame; forwarding already happened
  }
  try {
    appendFileSync(CAPTURE, JSON.stringify({ dir, frame }) + '\n');
  } catch {
    /* capture is best-effort; forwarding is the contract */
  }
}

// client -> server
let cbuf = '';
process.stdin.on('data', (chunk) => {
  cbuf += chunk;
  let nl;
  while ((nl = cbuf.indexOf('\n')) >= 0) {
    record('client', cbuf.slice(0, nl));
    cbuf = cbuf.slice(nl + 1);
  }
  try {
    child.stdin.write(chunk);
  } catch {
    /* child may have exited */
  }
});
process.stdin.on('end', () => {
  try {
    child.stdin.end();
  } catch {
    /* already closed */
  }
});

// server -> client
let sbuf = '';
child.stdout.setEncoding('utf8');
child.stdout.on('data', (chunk) => {
  sbuf += chunk;
  let nl;
  while ((nl = sbuf.indexOf('\n')) >= 0) {
    record('server', sbuf.slice(0, nl));
    sbuf = sbuf.slice(nl + 1);
  }
  process.stdout.write(chunk);
});

child.on('close', (code) => process.exit(code == null ? 0 : code));
process.on('SIGTERM', () => {
  try {
    child.kill('SIGTERM');
  } catch {
    /* gone */
  }
});
process.on('SIGINT', () => {
  try {
    child.kill('SIGINT');
  } catch {
    /* gone */
  }
});
