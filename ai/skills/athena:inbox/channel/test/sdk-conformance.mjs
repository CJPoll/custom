#!/usr/bin/env node
// sdk-conformance.mjs -- assert server.mjs still speaks the wire protocol the
// pinned @modelcontextprotocol/sdk expects (DND-283 ruling 1b/1c).
//
// TWO MODES, so the harness gate stays hermetic while live registration is
// still checked against the REAL SDK:
//
//   (default)  HERMETIC. No node_modules, no network. Replays the committed
//              golden (test/sdk-golden.json, recorded by gen-sdk-golden.mjs
//              from the pinned SDK) against a fresh server.mjs and asserts the
//              replies still match. Run by test/self-test.sh on EVERY run.
//   --live     Imports the SDK and performs the real handshake. Run by
//              scripts/setup-athena-attend --install BEFORE `claude mcp add`,
//              so a real interop break refuses live registration. WITHOUT
//              node_modules it exits 3 with a LIVE SKIPPED line -- "skipped"
//              and "passed" never read the same.
//
// Exit: 0 pass · 1 conformance failure · 2 usage/setup · 3 --live skipped
//       (node_modules absent).
import { spawnSync, spawn } from 'node:child_process';
import { readFileSync, writeFileSync, mkdtempSync, rmSync, closeSync, openSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { tmpdir } from 'node:os';

const HERE = dirname(fileURLToPath(import.meta.url)); // .../channel/test
const CHANNEL = dirname(HERE); // .../channel
const SERVER = join(CHANNEL, 'server.mjs');
const GOLDEN = join(HERE, 'sdk-golden.json');
const PKG = join(CHANNEL, 'package.json');
const LIVE = process.argv.includes('--live');

function fail(msg, fix) {
  process.stderr.write(`sdk-conformance: FAIL ${msg}\n  Fix: ${fix}\n`);
  process.exit(1);
}

// --- shared: a fake-status env + doorbell so a spawned server.mjs confirms
// tenancy and emits one unread wake, with no real registry/inbox/network. ----
function makeFakeEnv() {
  const tmp = mkdtempSync(join(tmpdir(), 'sdk-conf-'));
  const fakeStatus = join(tmp, 'fake-status.sh');
  const fakeResolve = join(tmp, 'fake-resolve.sh');
  const fakeWait = join(tmp, 'fake-wait.sh');
  writeFileSync(
    fakeStatus,
    '#!/usr/bin/env bash\n' +
      `printf '%s' '{"channels":[{"name":"peer-mail","kind":"maildir","unread":1,"count":1}],"failed_candidates":0,"repo_key":"/tmp/conf/.git"}'\n`,
    { mode: 0o755 },
  );
  writeFileSync(fakeResolve, '#!/usr/bin/env bash\necho conf-project\n', { mode: 0o755 });
  writeFileSync(
    fakeWait,
    '#!/usr/bin/env bash\n' + `[ "\${1:-}" = "--dry-run" ] && { echo "${tmp}/.event"; exit 0; }\nexec sleep 3\n`,
    { mode: 0o755 },
  );
  closeSync(openSync(join(tmp, '.event'), 'a'));
  const env = {
    ...process.env,
    ATHENA_INBOX_STATUS_BIN: fakeStatus,
    ATHENA_INBOX_RESOLVE_PROJECT_BIN: fakeResolve,
    ATHENA_INBOX_WAIT_BIN: fakeWait,
    ATHENA_CHANNEL_WATCH_MODE: 'fs-watch',
  };
  delete env.ATHENA_INBOX_EXPECT_PROJECT;
  return { tmp, env };
}

// Drive a fresh server.mjs with a sequence of frames, collect stdout frames for
// a bounded window. Returns { replies:Map(id->frame), notifications:[] }.
function driveServer(frames, env, windowMs = 1500) {
  return new Promise((resolve) => {
    const child = spawn('node', [SERVER], { stdio: ['pipe', 'pipe', 'inherit'], env });
    const replies = new Map();
    const notifications = [];
    let buf = '';
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
        if (msg.id !== undefined && msg.id !== null && (msg.result !== undefined || msg.error !== undefined)) {
          replies.set(msg.id, msg);
        } else if (msg.method === 'notifications/claude/channel') {
          notifications.push(msg);
        }
      }
    });
    let i = 0;
    const pump = () => {
      if (i < frames.length) {
        try {
          child.stdin.write(JSON.stringify(frames[i]) + '\n');
        } catch {
          /* server gone */
        }
        i += 1;
        setTimeout(pump, 120);
      }
    };
    pump();
    setTimeout(() => {
      try {
        child.kill('SIGTERM');
      } catch {
        /* gone */
      }
      setTimeout(() => resolve({ replies, notifications }), 120);
    }, windowMs);
  });
}

function normalize(obj, dropPaths) {
  const c = JSON.parse(JSON.stringify(obj));
  for (const p of dropPaths) {
    let cur = c;
    const keys = p.split('.');
    for (let k = 0; k < keys.length - 1; k += 1) cur = cur && cur[keys[k]];
    if (cur) delete cur[keys[keys.length - 1]];
  }
  return JSON.stringify(c);
}

function assertNotificationShape(label, n) {
  if (!n || n.jsonrpc !== '2.0') fail(`${label}: not a jsonrpc 2.0 message`, 'the shim must emit jsonrpc "2.0".');
  if (n.method !== 'notifications/claude/channel')
    fail(`${label}: wrong method ${n.method}`, 'the channel notification method must be notifications/claude/channel.');
  if ('id' in n) fail(`${label}: a notification must NOT carry an id`, 'remove id from the emitted notification.');
  const p = n.params || {};
  if (typeof p.content !== 'string') fail(`${label}: params.content must be a string`, 'emit content as a string.');
  if (!p.meta || typeof p.meta !== 'object' || Array.isArray(p.meta))
    fail(`${label}: params.meta must be an object`, 'emit meta as an object of string values.');
  for (const [k, v] of Object.entries(p.meta)) {
    if (k.includes('-')) fail(`${label}: meta key "${k}" contains a hyphen`, 'Claude Code silently drops hyphenated meta keys; use a hyphen-free identifier.');
    if (typeof v !== 'string') fail(`${label}: meta value for "${k}" is not a string`, 'every meta value must be a string.');
  }
}

// ---------------------------------------------------------------------------
// LIVE mode
// ---------------------------------------------------------------------------
async function runLive() {
  if (!existsSync(join(CHANNEL, 'node_modules'))) {
    process.stdout.write(`sdk-conformance: LIVE SKIPPED -- node_modules absent. Fix: npm ci in ${CHANNEL}\n`);
    process.exit(3);
  }
  let Client, StdioClientTransport, NotificationSchema, z;
  try {
    ({ Client } = await import('@modelcontextprotocol/sdk/client/index.js'));
    ({ StdioClientTransport } = await import('@modelcontextprotocol/sdk/client/stdio.js'));
    ({ NotificationSchema } = await import('@modelcontextprotocol/sdk/types.js'));
    ({ z } = await import('zod'));
  } catch (e) {
    process.stdout.write(`sdk-conformance: LIVE SKIPPED -- SDK import failed (${e.message}). Fix: npm ci in ${CHANNEL}\n`);
    process.exit(3);
  }
  const sdkPkg = JSON.parse(readFileSync(join(CHANNEL, 'node_modules', '@modelcontextprotocol', 'sdk', 'package.json'), 'utf8'));
  const { tmp, env } = makeFakeEnv();
  try {
    const transport = new StdioClientTransport({ command: 'node', args: [SERVER], env, stderr: 'inherit' });
    const client = new Client({ name: 'athena-sdk-live', version: '1.0.0' });
    const schema = NotificationSchema.extend({ method: z.literal('notifications/claude/channel') });
    const got = [];
    client.setNotificationHandler(schema, (n) => got.push(n));
    await client.connect(transport); // real initialize/initialized, SDK-parsed
    await client.listTools();
    await client.ping();
    const deadline = Date.now() + 5000;
    while (got.length === 0 && Date.now() < deadline) await new Promise((r) => setTimeout(r, 100));
    await client.close();
    if (got.length === 0) fail('live: no channel notification received through the SDK parser', 'confirm the shim emits an unread wake after initialized.');
    process.stdout.write(`sdk-conformance: LIVE PASS (sdk ${sdkPkg.version})\n`);
    process.exit(0);
  } catch (e) {
    fail(`live: the SDK rejected a frame (${e.message})`, 'the shim diverged from the wire protocol the SDK expects; inspect the first rejected frame above.');
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

// ---------------------------------------------------------------------------
// HERMETIC mode (default)
// ---------------------------------------------------------------------------
async function runHermetic() {
  if (!existsSync(GOLDEN))
    fail('the committed golden test/sdk-golden.json is missing', 'run `npm ci` then `node test/gen-sdk-golden.mjs`, and commit test/sdk-golden.json.');
  const golden = JSON.parse(readFileSync(GOLDEN, 'utf8'));

  // (i) the golden's sdkVersion must equal the package.json pin.
  const pkg = JSON.parse(readFileSync(PKG, 'utf8'));
  const pin = (pkg.dependencies || {})['@modelcontextprotocol/sdk'];
  if (golden.sdkVersion !== pin)
    fail(
      `golden sdkVersion ${golden.sdkVersion} != package.json pin ${pin}`,
      'npm ci && node test/gen-sdk-golden.mjs, then commit the regenerated golden (the pin must not drift from the golden silently).',
    );

  // (ii) server.mjs SUPPORTED_PROTOCOLS subset of golden's; PROTOCOL_FALLBACK in it.
  const pp = spawnSync('node', [SERVER, '--print-protocols'], { encoding: 'utf8' });
  if (pp.status !== 0) fail('server.mjs --print-protocols failed', 'ensure server.mjs answers --print-protocols with its protocol constants.');
  let protos;
  try {
    protos = JSON.parse(pp.stdout.trim());
  } catch {
    fail('server.mjs --print-protocols did not emit JSON', 'it must print {"SUPPORTED_PROTOCOLS":[...],"PROTOCOL_FALLBACK":"..."}.');
  }
  const sdkSupported = new Set(golden.SUPPORTED_PROTOCOL_VERSIONS);
  for (const v of protos.SUPPORTED_PROTOCOLS) {
    if (!sdkSupported.has(v))
      fail(
        `shim protocol ${v} is not in the SDK's SUPPORTED_PROTOCOL_VERSIONS`,
        'the shim advertises a protocol revision the pinned SDK does not speak; drop it from SUPPORTED_PROTOCOLS or bump the SDK pin (and regenerate the golden).',
      );
  }
  if (!sdkSupported.has(protos.PROTOCOL_FALLBACK))
    fail(
      `shim PROTOCOL_FALLBACK ${protos.PROTOCOL_FALLBACK} is not a version the SDK speaks`,
      'set PROTOCOL_FALLBACK to a revision in the SDK SUPPORTED_PROTOCOL_VERSIONS.',
    );

  // (iii)+(iv) replay the recorded frames against a fresh server; deep-equal
  // replies modulo id (+ serverInfo.version for initialize); shape-check the
  // emitted notification.
  const f = golden.frames;
  const { tmp, env } = makeFakeEnv();
  let out;
  try {
    out = await driveServer([f.clientInitialize, f.clientInitialized, f.clientToolsList, f.clientPing], env);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }

  const initReply = out.replies.get(f.clientInitialize.id);
  if (!initReply) fail('no initialize reply from a fresh server', 'server.mjs must answer the recorded initialize frame.');
  if (normalize(initReply, ['id', 'result.serverInfo.version']) !== normalize(f.serverInitializeResult, ['id', 'result.serverInfo.version']))
    fail('initialize reply diverged from the golden (modulo id + serverInfo.version)', 'the shim changed its initialize result; if intended, regenerate the golden and review the diff.');

  const toolsReply = out.replies.get(f.clientToolsList.id);
  if (!toolsReply) fail('no tools/list reply from a fresh server', 'server.mjs must answer tools/list.');
  if (normalize(toolsReply, ['id']) !== normalize(f.serverToolsListResult, ['id']))
    fail('tools/list reply diverged from the golden (modulo id)', 'the shim changed its tools/list result; if intended, regenerate the golden.');

  const pingReply = out.replies.get(f.clientPing.id);
  if (!pingReply) fail('no ping reply from a fresh server', 'server.mjs must answer ping.');
  if (normalize(pingReply, ['id']) !== normalize(f.serverPingResult, ['id']))
    fail('ping reply diverged from the golden (modulo id)', 'the shim changed its ping result; if intended, regenerate the golden.');

  // (iv) the golden's recorded notification AND a freshly emitted one both hold
  // the shape contract.
  assertNotificationShape('golden channelNotification', f.channelNotification);
  if (out.notifications.length === 0) fail('a fresh server emitted no channel notification', 'the shim must emit an unread wake after initialized when count>0.');
  assertNotificationShape('freshly emitted channelNotification', out.notifications[0]);

  process.stdout.write(`sdk-conformance: GOLDEN PASS (recorded from sdk ${golden.sdkVersion})\n`);
  process.exit(0);
}

if (LIVE) runLive();
else runHermetic();
